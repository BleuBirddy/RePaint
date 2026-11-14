import Foundation
import Observation
import SceneKit

/// What the screen shows: the loaded model, its sliced layers, and any
/// loading or slicing in progress.
@Observable
final class SlicerModel {
    private(set) var mesh: Mesh?
    private(set) var scene: SCNScene?
    private(set) var fileName: String?
    private(set) var isLoading = false

    private(set) var result: SliceResult?
    private(set) var isSlicing = false
    private(set) var sliceProgress = 0.0

    var errorMessage: String?

    /// Changing any setting throws the sliced layers away: they were made
    /// with the old settings and would no longer match what is shown.
    var settings = SliceSettings() {
        didSet { if settings != oldValue { result = nil } }
    }
    /// True when the model came from the Painter tab instead of a file.
    private(set) var isPainting = false
    /// Goes up each time a model is loaded, so the screen can reset itself.
    private(set) var loadCount = 0
    let printer = PrinterProfile.bambuUntested
    var bed: Bed { printer.bed }

    /// Opens an STL file the user picked.
    func open(_ url: URL) async {
        var next = settings
        if isPainting {
            // Coming from a painting: put back the ordinary layer height and
            // infill, and drop the painting's filament swaps. Other choices
            // (supports and so on) stay as the user set them.
            let normal = SliceSettings()
            next.layerHeight = normal.layerHeight
            next.firstLayerHeight = normal.firstLayerHeight
            next.infillDensity = normal.infillDensity
            next.filamentSwaps = []
            next.firstSlot = normal.firstSlot
            next.firstFilamentName = ""
        }
        await load(name: url.lastPathComponent, settings: next, isPainting: false) {
            // Files picked in the Files app are outside the app's sandbox
            // until we ask for access; forgetting this gives a
            // "permission denied" that only shows on a real device.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    /// Takes a filament painting straight from the Painter tab, with the
    /// settings a painting needs: its own thin layers (first layer too, or
    /// the filament swaps would land at the wrong heights) and no hollow
    /// inside, because light has to pass through solid plastic.
    func openPainting(_ p: Painting) async {
        var painting = settings
        painting.layerHeight = p.layerHeight
        painting.firstLayerHeight = p.layerHeight
        painting.infillDensity = 1
        // A painting is a flat slab; supports would only get in the way.
        painting.supportMode = .off
        painting.firstSlot = 1
        painting.firstFilamentName = p.firstFilamentName
        painting.filamentSwaps = p.swaps
        let stl = p.stl
        await load(name: p.name + " painting.stl", settings: painting, isPainting: true) { stl }
    }

    private func load(name: String, settings newSettings: SliceSettings, isPainting painting: Bool,
                      read: @escaping @Sendable () throws -> Data) async {
        isLoading = true
        defer { isLoading = false }

        let bed = bed
        do {
            // Reading and parsing a big STL takes a moment, so it happens off
            // the main thread to keep the screen responsive.
            let placed = try await Task.detached {
                try STLParser.parse(read())
                    .placedOnBed(centreX: bed.width / 2, centreY: bed.depth / 2)
            }.value
            mesh = placed
            scene = MeshScene.make(mesh: placed, bed: bed)
            fileName = name
            settings = newSettings
            isPainting = painting
            // The old layers belong to the previous model.
            result = nil
            loadCount += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func slice() async {
        guard let mesh, !isSlicing else { return }
        isSlicing = true
        sliceProgress = 0
        defer { isSlicing = false }

        let settings = settings
        result = await Task.detached {
            Slicer.slice(mesh: mesh, settings: settings) { fraction in
                // The slicer reports from its worker threads; the screen may
                // only be touched from the main one.
                Task { @MainActor in
                    // Reports can arrive out of order; never move the bar back.
                    self.sliceProgress = max(self.sliceProgress, fraction)
                }
            }
        }.value
    }

    /// The finished G-code as a file ready to save, or nil before slicing.
    func gcodeDocument() async -> GCodeDocument? {
        guard let result else { return nil }
        let printer = printer
        let name = fileName ?? "model"
        let text = await Task.detached {
            GCodeWriter.write(result, printer: printer, modelName: name)
        }.value
        return GCodeDocument(text: text)
    }

    /// "benchy.stl" → "benchy.gcode"
    var gcodeFileName: String {
        ((fileName ?? "model") as NSString).deletingPathExtension + ".gcode"
    }
}

/// What the Painter tab hands to the Slicer.
nonisolated struct Painting: Sendable {
    var stl: Data
    var name: String
    var layerHeight: Double
    /// The bottom filament, which the print starts with (AMS slot 1).
    var firstFilamentName: String
    /// One per further filament, in slots 2, 3, … in the Painter's order.
    var swaps: [FilamentSwap]
}
