import Testing
import Foundation
@testable import RePaint

/// Checks the engine and print plan against a print Jey already made by hand:
/// the squid panel. Settings: 83 × 160 mm, 2.4 mm thick, 0.08 mm layers (first
/// layer too), 100% infill. Swaps: Black for layers 1–10, Brass Silk from layer
/// 11 (Z 0.88), White Rock Marble from layer 18 (Z 1.44).
@MainActor
struct SquidPlanTests {

    /// A throwaway defaults store, so the test never touches the app's saved spools.
    private func freshModel() -> PainterModel {
        let suite = "RePaintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PainterModel(defaults: defaults)
    }

    @Test func squidPlanMatchesTheHandRunPrint() {
        let model = freshModel()
        // Hand-picked swaps, as in the real print, so auto-fit must be off.
        model.autoFit = false
        model.settings.widthMM = 83
        model.settings.layerHeight = 0.08
        // 2.4 mm ÷ 0.08 mm = 30 layers. The reference doesn't say how many of
        // Black's 10 layers were base. 8 base + 22 color is the app's default.
        model.settings.baseLayers = 8
        model.settings.colorLayers = 22
        model.filaments = Filament.defaults
        model.filaments[1].startLayer = 3   // 8 + 3 = layer 11
        model.filaments[2].startLayer = 10  // 8 + 10 = layer 18

        let lines = model.planText.split(separator: "\n").map(String.init)
        #expect(lines.contains("Black: layers 1–10"))
        #expect(lines.contains("Brass Silk: from layer 11 (Z 0.88 mm)"))
        #expect(lines.contains("White Rock Marble: from layer 18 (Z 1.44 mm)"))
        #expect(lines.contains("Top: layer 30 (Z 2.40 mm)"))
    }

    @Test func defaultsAreTheSquidSettings() {
        // A first launch should open with the settings the squid was printed with.
        let s = PaintSettings()
        #expect(s.layerHeight == 0.08)
        #expect(Double(s.baseLayers + s.colorLayers) * s.layerHeight == 2.4)
        #expect(Filament.defaults.map(\.startLayer) == [0, 3, 10])
        #expect(Filament.defaults.map(\.td) == [0.6, 3.0, 2.0])
    }
}

struct EngineTests {

    @Test func aStackOneTDThickIsAbout95PercentOpaque() {
        // The light model: each layer lets through exp(-3 · height / TD), so a
        // stack as thick as the TD blocks about 95% of the light underneath.
        let td = 2.0, lh = 0.08
        let layers = Int((td / lh).rounded())
        let a = Engine.opacity(td: td, layerHeight: lh)
        let throughput = pow(1 - a, Double(layers))
        #expect(abs(throughput - exp(-3)) < 1e-9)
    }

    @Test func normalizedStartsAlwaysIncreaseAndFit() {
        // The base always starts at 0. A start that's already valid stays put (2).
        // A repeat gets pushed up (2 → 3). One past the top gets clamped (40 → 22).
        let s = Engine.normalized([5, 2, 2, 40], layers: 22)
        #expect(s == [0, 2, 3, 22])
    }

    @Test func autoFitOnTheSampleGivesValidSwaps() throws {
        let image = try #require(SampleImage.make())
        let settings = PaintSettings()
        let grid = Engine.makeGrid(image, settings)
        let starts = Engine.optimize(grid, Filament.defaults, settings)
        #expect(starts.count == 3)
        #expect(starts[0] == 0)
        #expect(starts[1] >= 1 && starts[1] < starts[2] && starts[2] <= settings.colorLayers)
    }

    @Test func stlHeaderMatchesItsSize() throws {
        let image = try #require(SampleImage.make())
        var settings = PaintSettings()
        settings.widthMM = 20 // small grid keeps the test fast
        let grid = Engine.makeGrid(image, settings)
        let data = Engine.stl(grid, settings)
        let count = data.subdata(in: 80..<84).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(Int(UInt32(littleEndian: count)) == Engine.triangleCount(grid))
        #expect(data.count == 84 + 50 * Engine.triangleCount(grid))
    }
}
