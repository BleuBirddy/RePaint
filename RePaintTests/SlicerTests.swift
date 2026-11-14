import XCTest
import simd
@testable import RePaint

/// A box-shaped mesh, for tests.
func boxMesh(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Mesh {
    let c: [SIMD3<Float>] = [
        [a.x, a.y, a.z], [b.x, a.y, a.z], [b.x, b.y, a.z], [a.x, b.y, a.z],
        [a.x, a.y, b.z], [b.x, a.y, b.z], [b.x, b.y, b.z], [a.x, b.y, b.z],
    ]
    let faces = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4],
                 [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
    return Mesh(vertices: faces.flatMap { $0.map { c[$0] } })
}

final class SlicerTests: XCTestCase {
    /// A 20 mm cube in the middle of the bed.
    private let cube = boxMesh(from: [118, 118, 0], to: [138, 138, 20])

    func testCubeOutlines() {
        let planes = stride(from: Float(0.1), to: 20, by: 0.2).map { $0 }
        let out = LayerSlicer.outlines(mesh: cube, planes: planes)
        XCTAssertEqual(out.layersWithGaps, 0)
        for area in out.areas {
            XCTAssertEqual(area.count, 1)
            XCTAssertEqual(Clip.areaMM2(area), 400, accuracy: 0.01)
        }
    }

    /// A small box standing on a big one, with the join exactly at a cutting
    /// height. Corners lying on the plane are where naive slicers break.
    func testCornersExactlyOnACuttingPlane() {
        let big = boxMesh(from: [0, 0, 0], to: [20, 20, 0.5])
        let small = boxMesh(from: [5, 5, 0.5], to: [15, 15, 1])
        let both = Mesh(vertices: big.vertices + small.vertices)
        let out = LayerSlicer.outlines(mesh: both, planes: [0.1, 0.3, 0.5, 0.7, 0.9])
        XCTAssertEqual(out.layersWithGaps, 0)
        XCTAssertEqual(out.areas.map { Clip.areaMM2($0).rounded() }, [400, 400, 400, 100, 100])
    }

    func testMeshWithAHoleIsReported() {
        var open = cube
        open.vertices.removeLast(6) // drop one side
        let out = LayerSlicer.outlines(mesh: open, planes: [5, 10])
        XCTAssertEqual(out.layersWithGaps, 2)
    }

    func testCubeLayers() {
        let s = SliceSettings()
        let result = Slicer.slice(mesh: cube, settings: s)
        XCTAssertEqual(result.layers.count, 100)
        XCTAssertEqual(result.layers.last!.z, 20, accuracy: 1e-6)

        func kinds(_ i: Int) -> Set<PathKind> { Set(result.layers[i].paths.map(\.kind)) }
        XCTAssertEqual(kinds(0), [.skirt, .innerWall, .outerWall, .solidFill])
        // Bottom 3 and top 5 layers are solid, the rest sparse.
        XCTAssertEqual(kinds(2), [.innerWall, .outerWall, .solidFill])
        XCTAssertEqual(kinds(3), [.innerWall, .outerWall, .sparseFill])
        XCTAssertEqual(kinds(94), [.innerWall, .outerWall, .sparseFill])
        XCTAssertEqual(kinds(95), [.innerWall, .outerWall, .solidFill])
        XCTAssertEqual(kinds(99), [.innerWall, .outerWall, .solidFill])

        // The outer wall's centre line sits half a line width inside the
        // surface, so the plastic's outside edge is the model's size.
        let outer = result.layers[50].paths.first { $0.kind == .outerWall }!
        XCTAssertEqual(outer.points.map(\.mmX).min()!, 118 + s.lineWidth / 2, accuracy: 0.002)
        XCTAssertEqual(outer.points.map(\.mmX).max()!, 138 - s.lineWidth / 2, accuracy: 0.002)
    }

    /// A small box on a big one. Just under the step, the big box's exposed
    /// top needs solid fill, but the part hidden under the small box doesn't.
    func testSolidFillOnlyUnderExposedSurfaces() {
        let big = boxMesh(from: [100, 100, 0], to: [140, 140, 6])
        let small = boxMesh(from: [110, 110, 6], to: [130, 130, 12])
        let result = Slicer.slice(mesh: Mesh(vertices: big.vertices + small.vertices),
                                  settings: SliceSettings())
        XCTAssertEqual(result.layersWithGaps, 0)

        func middles(_ layer: Int, _ kind: PathKind) -> [(x: Double, y: Double)] {
            result.layers[layer].paths.filter { $0.kind == kind }.map {
                (($0.points[0].mmX + $0.points[1].mmX) / 2, ($0.points[0].mmY + $0.points[1].mmY) / 2)
            }
        }
        func underSmallBox(_ p: (x: Double, y: Double), grow: Double) -> Bool {
            (110 - grow...130 + grow).contains(p.x) && (110 - grow...130 + grow).contains(p.y)
        }

        // Layer 28 (5.4–5.6 mm) is within 5 layers of the step at 6 mm.
        let solid = middles(27, .solidFill), sparse = middles(27, .sparseFill)
        XCTAssertFalse(solid.isEmpty)
        XCTAssertFalse(sparse.isEmpty)
        XCTAssertTrue(solid.allSatisfy { !underSmallBox($0, grow: -1) })
        XCTAssertTrue(sparse.allSatisfy { underSmallBox($0, grow: 1) })

        // Layer 21 (4.0–4.2 mm) is too far below the step to need any.
        XCTAssertTrue(middles(20, .solidFill).isEmpty)
        XCTAssertFalse(middles(20, .sparseFill).isEmpty)
    }

    /// Two triangles standing back to back (a wall with no thickness) cut to
    /// a "loop" of two points. That isn't a hole in the model.
    func testZeroThicknessFinIsNotAGap() {
        let fin: [SIMD3<Float>] = [[0, 0, 0], [10, 0, 0], [5, 0, 10], [0, 0, 0], [5, 0, 10], [10, 0, 0]]
        let out = LayerSlicer.outlines(mesh: Mesh(vertices: fin), planes: [5])
        XCTAssertEqual(out.layersWithGaps, 0)
        XCTAssertTrue(out.areas[0].isEmpty)
    }

    /// At 100% infill the plastic pushed out should match the cube's volume.
    /// This catches mistakes in line spacing and in the extrusion maths.
    func testSolidCubeUsesACubeOfPlastic() {
        var s = SliceSettings()
        s.infillDensity = 1
        s.skirtLoops = 0
        let result = Slicer.slice(mesh: cube, settings: s)
        let filamentArea = Double.pi * pow(s.filamentDiameter / 2, 2)
        XCTAssertEqual(result.filamentMM * filamentArea, 8000, accuracy: 8000 * 0.08)
    }

    func testGCode() throws {
        let result = Slicer.slice(mesh: cube, settings: SliceSettings())
        let gcode = GCodeWriter.write(result, printer: .bambuUntested, modelName: "cube.stl")
        XCTAssertTrue(gcode.contains("M109 S220"))
        XCTAssertFalse(gcode.contains("{"))
        XCTAssertFalse(gcode.lowercased().contains("nan"))
        XCTAssertEqual(gcode.components(separatedBy: "\n; LAYER ").count - 1, 100)

        // Every move stays on the bed, and filament pushed minus filament
        // pulled back adds up to what the slicer reported.
        var pushed = 0.0
        for line in gcode.split(separator: "\n") where line.hasPrefix("G1 ") {
            for word in line.split(separator: " ").dropFirst() {
                guard let value = Double(word.dropFirst()) else { break }
                switch word.first {
                case "X", "Y": XCTAssertTrue((0...256).contains(value), String(line))
                case "Z": XCTAssertTrue((0...256).contains(value), String(line))
                case "E": pushed += value
                default: break
                }
            }
        }
        XCTAssertEqual(pushed, result.filamentMM - SliceSettings().retractLength,
                       accuracy: result.filamentMM * 0.001)
    }

    func testFixed() {
        XCTAssertEqual(GCodeWriter.fixed(128.0424, 3), "128.042")
        XCTAssertEqual(GCodeWriter.fixed(0.00123, 5), "0.00123")
        XCTAssertEqual(GCodeWriter.fixed(-0.8, 2), "-0.80")
        XCTAssertEqual(GCodeWriter.fixed(2.9996, 3), "3.000")
        XCTAssertEqual(GCodeWriter.fixed(-0.0001, 2), "0.00")
    }

    // MARK: - Supports

    /// A "T": a 10 mm post with a 30 mm bar across the top, so 10 mm of bar
    /// hangs in the air on each side. With `base`, a plate lies under the
    /// whole thing, so nothing hanging is above the bed itself.
    private func tee(base: Bool) -> Mesh {
        let lift: Float = base ? 2 : 0
        var v = boxMesh(from: [123, 123, lift], to: [133, 133, 10 + lift]).vertices
        v += boxMesh(from: [113, 123, 10 + lift], to: [143, 133, 12 + lift]).vertices
        if base { v += boxMesh(from: [113, 123, 0], to: [143, 133, 2]).vertices }
        return Mesh(vertices: v)
    }

    private func supportLayers(_ mesh: Mesh, _ mode: SupportMode) -> [Int] {
        var s = SliceSettings()
        s.supportMode = mode
        let result = Slicer.slice(mesh: mesh, settings: s)
        return result.layers.indices.filter { i in result.layers[i].paths.contains { $0.kind == .support } }
    }

    func testNoSupportsWhenOff() {
        XCTAssertEqual(supportLayers(tee(base: false), .off), [])
    }

    func testSupportsUnderAnOverhang() {
        var s = SliceSettings()
        s.supportMode = .everywhere
        let result = Slicer.slice(mesh: tee(base: false), settings: s)
        let withSupport = result.layers.indices.filter { i in
            result.layers[i].paths.contains { $0.kind == .support }
        }
        // The bar's underside is at 10 mm = the top of layer 50. Layer 50
        // (index 49) is the air gap, so supports fill layers 1–49.
        XCTAssertEqual(withSupport, Array(0...48))

        // Supports stay under the bar's arms and clear of the post.
        for layer in result.layers[0...48] {
            for path in layer.paths where path.kind == .support {
                for p in path.points {
                    XCTAssertTrue((113...143).contains(p.mmX) && (123...133).contains(p.mmY))
                    XCTAssertFalse((122.6...133.4).contains(p.mmX), "support inside the post's clearance")
                }
            }
        }
        // And both arms get some.
        let xs = result.layers[20].paths.filter { $0.kind == .support }.flatMap { $0.points.map(\.mmX) }
        XCTAssertTrue(xs.contains { $0 < 123 } && xs.contains { $0 > 133 })
    }

    func testBedOnlySkipsOverhangsAboveTheModel() {
        // With a plate underneath, every support would have to stand on the
        // model: "everywhere" builds them from the plate up, "bed only" none.
        XCTAssertEqual(supportLayers(tee(base: true), .everywhere), Array(10...58))
        XCTAssertEqual(supportLayers(tee(base: true), .bedOnly), [])
        // Without the plate the supports stand on the bed in both modes.
        XCTAssertEqual(supportLayers(tee(base: false), .bedOnly), Array(0...48))
    }

    func testASteepSlopeNeedsNoSupport() {
        // A box leaning over at 45°: each layer sticks out one layer height,
        // well within what the default 30° threshold lets through.
        var v = [SIMD3<Float>]()
        let lean: Float = 10
        let b: [SIMD3<Float>] = [[120, 120, 0], [130, 120, 0], [130, 130, 0], [120, 130, 0]]
        let t = b.map { SIMD3<Float>($0.x + lean, $0.y, 10) }
        for (a, c) in [(0, 1), (1, 2), (2, 3), (3, 0)] { v += [b[a], b[c], t[c], b[a], t[c], t[a]] }
        v += [b[0], b[2], b[1], b[0], b[3], b[2], t[0], t[1], t[2], t[0], t[2], t[3]]
        XCTAssertEqual(supportLayers(Mesh(vertices: v), .everywhere), [])
    }

    // MARK: - Filament swaps

    func testFilamentSwapsLandAtTheirLayers() {
        var s = SliceSettings()
        s.firstSlot = 2
        s.filamentSwaps = [FilamentSwap(layer: 18, slot: 3, name: "White"),
                           FilamentSwap(layer: 11, slot: 1, name: "Brass"),
                           FilamentSwap(layer: 1, slot: 4), // ignored: layer 1 is the start
                           FilamentSwap(layer: 500, slot: 4)] // ignored: above the print
        XCTAssertEqual(s.filament(forLayer: 10).slot, 2)
        XCTAssertEqual(s.filament(forLayer: 11).name, "Brass")
        XCTAssertEqual(s.filament(forLayer: 99).slot, 3)

        let gcode = GCodeWriter.write(Slicer.slice(mesh: cube, settings: s),
                                      printer: .bambuUntested, modelName: "cube.stl")
        let layers = gcode.components(separatedBy: "\n; LAYER ")
        // Bambu counts slots from 0: slot 2 is T1, slot 1 is T0, slot 3 is T2.
        XCTAssertTrue(layers[0].contains("\nT1 "))
        XCTAssertTrue(layers[11].contains("; FILAMENT CHANGE to slot 1 (Brass)\nM620 S0A"))
        XCTAssertTrue(layers[11].contains("\nT0 "))
        XCTAssertTrue(layers[18].contains("\nT2 "))
        XCTAssertEqual(gcode.components(separatedBy: "; FILAMENT CHANGE").count - 1, 2)
        XCTAssertFalse(gcode.contains("{"))
        // The swap comes before any printing on its layer.
        let swapAt = layers[11].range(of: "FILAMENT CHANGE")!.lowerBound
        let firstPrint = layers[11].range(of: "; TYPE:")!.lowerBound
        XCTAssertTrue(swapAt < firstPrint)
    }

    /// The Painter's print plan and the swaps it hands to the Slicer must
    /// agree: each further filament starts at its plan layer, in the next slot.
    @MainActor func testPainterHandsOverItsPrintPlan() throws {
        let store = try XCTUnwrap(UserDefaults(suiteName: "RePaintTests.handoff"))
        store.removePersistentDomain(forName: "RePaintTests.handoff")
        let painter = PainterModel(defaults: store)
        let painting = painter.painting(stl: Data())

        XCTAssertEqual(painting.firstFilamentName, painter.filaments[0].name)
        XCTAssertEqual(painting.layerHeight, painter.settings.layerHeight)
        XCTAssertEqual(painting.swaps.map(\.slot), [2, 3])
        XCTAssertEqual(painting.swaps.map(\.layer), [painter.layerNumber(for: 1), painter.layerNumber(for: 2)])
        XCTAssertEqual(painting.swaps.map(\.name), painter.filaments.dropFirst().map(\.name))
    }
}
