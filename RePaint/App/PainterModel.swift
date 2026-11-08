import SwiftUI
import Observation

/// Changes to anything in here trigger a rebuild of the preview.
struct RebuildKey: Hashable {
    var settings: PaintSettings
    var filaments: [Filament]
    var autoFit: Bool
    var sourceVersion: Int
}

private struct GridKey: Hashable {
    var settings: PaintSettings
    var sourceVersion: Int
}

@MainActor
@Observable
final class PainterModel {
    var source: CGImage? = SampleImage.make()
    var sourceName = "Sample moon"
    var sourceVersion = 0

    var settings: PaintSettings { didSet { persist() } }
    var filaments: [Filament] { didSet { persist() } }
    var autoFit = true

    private(set) var preview: CGImage?
    private(set) var croppedSource: CGImage?
    private(set) var grid: Grid?
    var isWorking = false
    var message: String?

    @ObservationIgnored private var gridKey: GridKey?
    @ObservationIgnored private var loaded = false
    /// Where filaments and settings are saved. Tests pass their own store so
    /// they never overwrite the spools saved in the real app.
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: "filaments"),
           let f = try? JSONDecoder().decode([Filament].self, from: d), f.count >= 2 {
            filaments = f
        } else {
            filaments = Filament.defaults
        }
        if let d = defaults.data(forKey: "settings"),
           var s = try? JSONDecoder().decode(PaintSettings.self, from: d) {
            s.cropLeft = 0; s.cropRight = 0; s.cropTop = 0; s.cropBottom = 0
            settings = s
        } else {
            settings = PaintSettings()
        }
        loaded = true
    }

    private func persist() {
        guard loaded else { return }
        if let d = try? JSONEncoder().encode(filaments) { defaults.set(d, forKey: "filaments") }
        if let d = try? JSONEncoder().encode(settings) { defaults.set(d, forKey: "settings") }
    }

    var rebuildKey: RebuildKey {
        // When auto-fit is on, the start layers are an output, so they don't trigger rebuilds.
        let f = autoFit ? filaments.map { var x = $0; x.startLayer = 0; return x } : filaments
        return RebuildKey(settings: settings, filaments: f, autoFit: autoFit, sourceVersion: sourceVersion)
    }

    // MARK: Actions

    func loadImageData(_ data: Data, name: String) async {
        let box = await Task.detached(priority: .userInitiated) {
            Box(value: Engine.loadImage(data: data))
        }.value
        guard let image = box.value else {
            message = "That file isn't an image the app can read. Try a JPEG, PNG, or HEIC."
            return
        }
        source = image
        sourceName = name
        settings.cropLeft = 0; settings.cropRight = 0; settings.cropTop = 0; settings.cropBottom = 0
        sourceVersion += 1
    }

    func addFilament() {
        guard filaments.count < 6 else { return }
        let last = filaments.last?.startLayer ?? 0
        filaments.append(Filament(name: "New filament", r: 0.6, g: 0.6, b: 0.6, td: 2.0,
                                  startLayer: min(settings.colorLayers, last + 2)))
        settings.colorLayers = max(settings.colorLayers, filaments.count + 4)
    }

    func removeFilaments(at offsets: IndexSet) {
        guard filaments.count - offsets.count >= 2 else {
            message = "A painting needs at least two filaments."
            return
        }
        filaments.remove(atOffsets: offsets)
    }

    func moveFilaments(from source: IndexSet, to destination: Int) {
        filaments.move(fromOffsets: source, toOffset: destination)
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = filaments.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard filaments.indices.contains(j) else { return }
        filaments.swapAt(i, j)
    }

    func rebuild() async {
        guard let src = source else { preview = nil; grid = nil; return }
        isWorking = true
        defer { isWorking = false }

        let s = settings
        let f = filaments
        let fit = autoFit
        let key = GridKey(settings: s, sourceVersion: sourceVersion)
        let reuse = (gridKey == key) ? grid : nil
        let image = Box(value: src)

        let result = await Task.detached(priority: .userInitiated) {
            let g = reuse ?? Engine.makeGrid(image.value, s)
            let starts = fit ? Engine.optimize(g, f, s)
                             : Engine.normalized(f.map(\.startLayer), layers: s.colorLayers)
            let colors = Engine.levelColors(f, starts: starts, s)
            let preview = Engine.previewImage(g, colors)
            let cropped = Engine.crop(image.value, s)
            return Box(value: (g, starts, preview, cropped))
        }.value

        guard !Task.isCancelled else { return }
        let (g, starts, prev, cropped) = result.value
        grid = g
        gridKey = key
        preview = prev
        croppedSource = cropped

        // Only write the start layers back if the filament list hasn't changed underneath us.
        if filaments.map(\.id) == f.map(\.id) {
            for i in filaments.indices where filaments[i].startLayer != starts[i] {
                filaments[i].startLayer = starts[i]
            }
        }
    }

    func makeSTL() async -> Data? {
        guard let g = grid else { return nil }
        isWorking = true
        defer { isWorking = false }
        let s = settings
        return await Task.detached(priority: .userInitiated) { Engine.stl(g, s) }.value
    }

    // MARK: Print plan

    func layerNumber(for index: Int) -> Int {
        settings.baseLayers + filaments[index].startLayer
    }

    func z(forLayer layer: Int) -> String {
        String(format: "%.2f", Double(layer) * settings.layerHeight)
    }

    var topLayer: Int { settings.baseLayers + settings.colorLayers }

    var sizeSummary: String {
        guard let g = grid else { return "" }
        let thick = Double(topLayer) * settings.layerHeight
        let mb = Double(84 + 50 * Engine.triangleCount(g)) / 1_000_000
        return String(format: "%.0f × %.0f mm · %.2f mm thick · %.0f MB STL", g.widthMM, g.heightMM, thick, mb)
    }

    var planText: String {
        var lines = [
            "Filament painting: \(sourceName)",
            "Layer height \(String(format: "%.2f", settings.layerHeight)) mm (first layer too), 100% infill.",
            "",
        ]
        for (i, f) in filaments.enumerated() {
            if i == 0 {
                let end = filaments.count > 1 ? layerNumber(for: 1) - 1 : topLayer
                lines.append("\(f.name): layers 1–\(end)")
            } else {
                let layer = layerNumber(for: i)
                lines.append("\(f.name): from layer \(layer) (Z \(z(forLayer: layer)) mm)")
            }
        }
        lines.append("Top: layer \(topLayer) (Z \(z(forLayer: topLayer)) mm)")
        return lines.joined(separator: "\n")
    }
}
