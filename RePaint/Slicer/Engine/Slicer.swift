import Foundation

/// Turns a mesh into the lines the printer will draw, layer by layer.
///
/// What it does: walls, solid top and bottom, sparse infill, a skirt, and
/// simple supports (see `Supports`).
/// What it doesn't: bridges, brims, seam placement, anything clever about
/// thin walls.
nonisolated enum Slicer {
    /// `progress` is called with 0…1 from background threads.
    static func slice(mesh: Mesh,
                      settings s: SliceSettings,
                      progress: @Sendable (Double) -> Void = { _ in }) -> SliceResult {
        // Each layer is cut through its middle, which represents the layer
        // better than its top or bottom edge would.
        let top = Double(mesh.bounds?.max.z ?? 0)
        var planes = [Float]()
        var heights = [Double]()
        var bottom = 0.0
        while true {
            let h = planes.isEmpty ? s.firstLayerHeight : s.layerHeight
            guard bottom + h / 2 < top else { break }
            planes.append(Float(bottom + h / 2))
            heights.append(h)
            bottom += h
        }

        let cut = LayerSlicer.outlines(mesh: mesh, planes: planes)
        let areas = cut.areas
        progress(0.15)
        let supports = Supports.regions(areas: areas, heights: heights, settings: s)
        progress(0.2)

        // Layers don't depend on each other's results, only on the outlines
        // above, so they can be planned on all CPU cores at once.
        var layers = [SlicedLayer](repeating: SlicedLayer(z: 0, height: 0, paths: []), count: areas.count)
        let done = Counter()
        layers.withUnsafeMutableBufferPointer { buffer in
            // Each iteration writes only its own slot, so sharing the buffer
            // between threads is safe; `nonisolated(unsafe)` tells Swift so.
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: areas.count) { i in
                let z = heights[0...i].reduce(0, +)
                slots[i] = SlicedLayer(z: z, height: heights[i],
                                       paths: plan(layer: i, height: heights[i], areas: areas,
                                                   support: supports[i], settings: s))
                progress(0.2 + 0.8 * Double(done.increment()) / Double(areas.count))
            }
        }

        var filament = 0.0
        var seconds = 0.0
        for (i, layer) in layers.enumerated() {
            let perMM = s.filamentPerMM(layerHeight: layer.height)
            for path in layer.paths {
                let mm = length(of: path)
                filament += mm * perMM
                seconds += mm / s.speed(for: path.kind, firstLayer: i == 0)
            }
        }
        let radiusCM = s.filamentDiameter / 20
        let grams = .pi * radiusCM * radiusCM * (filament / 10) * s.filamentDensity

        return SliceResult(layers: layers, settings: s, layersWithGaps: cut.layersWithGaps,
                           filamentMM: filament, filamentGrams: grams, roughSeconds: seconds)
    }

    static func length(of path: Extrusion) -> Double {
        guard path.points.count > 1 else { return 0 }
        var units = 0.0
        for i in 1..<path.points.count {
            units += path.points[i - 1].distance(to: path.points[i])
        }
        if path.closed { units += path.points[path.points.count - 1].distance(to: path.points[0]) }
        return units / Units.perMM
    }

    // MARK: - One layer

    private static func plan(layer i: Int, height: Double, areas: [[Polyline]],
                             support: [Polyline], settings s: SliceSettings) -> [Extrusion] {
        let area = areas[i]
        let w = s.lineWidth
        // Neighbouring lines sit a little closer than one line width, so
        // their rounded sides overlap and leave no gaps (see `lineSpacing`).
        let gap = s.lineSpacing(layerHeight: height)
        var paths = [Extrusion]()

        // Skirt: a couple of loops around the first layer, away from the
        // part. It gets the plastic flowing before anything that matters.
        if i == 0 {
            // It goes around the supports too, or it would run through them.
            let footprint = support.isEmpty ? area : Clip.union(area, support)
            for loop in 0..<s.skirtLoops {
                let ring = Clip.offset(footprint, mm: s.skirtDistance + Double(loop) * w, round: true)
                // Only the outside edge: no skirts inside the part's holes.
                // (Holes run clockwise, which gives them a negative area.)
                paths += ring.filter { Clip.areaMM2([$0]) > 0 }
                    .map { Extrusion(kind: .skirt, points: $0, closed: true) }
            }
        }

        // Supports go down before the model, so each overhang's scaffolding
        // is finished before anything rests on it.
        paths += Supports.paths(for: support, settings: s)
        guard !area.isEmpty else { return paths }

        // Walls: the centre of the outer wall runs half a line width inside
        // the outline, so its outside edge lands on the model's surface.
        // Each further wall is one line spacing further in. Inner walls first, outer last: the outer wall then has
        // something to lean on and looks cleaner.
        for n in stride(from: s.wallCount - 1, through: 0, by: -1) {
            let kind: PathKind = n == 0 ? .outerWall : .innerWall
            paths += Clip.offset(area, mm: -(w / 2 + Double(n) * gap))
                .map { Extrusion(kind: kind, points: $0, closed: true) }
        }

        // Everything inside the walls gets filled, solid or sparse.
        let inside = Clip.offset(area, mm: -(w / 2 + (Double(s.wallCount) - 0.5) * gap))
        guard !inside.isEmpty else { return paths }

        // A spot needs solid fill when, within the next few layers up, there
        // is no model above it (it's part of a top surface), and the same
        // looking down (a bottom surface). `covered` is what remains when the
        // neighbouring layers are overlaid: only spots present in all of them.
        func covered(_ range: some Sequence<Int>) -> [Polyline] {
            var common: [Polyline]?
            for j in range {
                guard areas.indices.contains(j) else { return [] }
                common = common.map { Clip.intersection($0, areas[j]) } ?? areas[j]
                if common?.isEmpty == true { return [] }
            }
            return common ?? []
        }
        let above = s.topLayers > 0 ? covered(i + 1...i + s.topLayers) : inside
        let below = s.bottomLayers > 0 ? covered(i - s.bottomLayers...i - 1) : inside
        let needsSolid = Clip.union(Clip.difference(inside, above), Clip.difference(inside, below))
        // Shrink-then-grow wipes out sparse slivers too thin for a line to
        // fit; solid fill takes those over. (Done to the sparse part, not the
        // solid part: a thin solid strip along a sloping wall is needed, a
        // thin sparse strip is just a stray dot of plastic.)
        // At 100% infill there is no "sparse" part: fill everything solid.
        var sparse = s.infillDensity >= 1 ? [] : Clip.difference(inside, needsSolid)
        sparse = Clip.intersection(Clip.offset(Clip.offset(sparse, mm: -w / 2), mm: w / 2), inside)
        let solid = Clip.difference(inside, sparse)

        // Lines turn 90° every layer so each layer crosses the one below.
        let angle: Double = i % 2 == 0 ? .pi / 4 : 3 * .pi / 4
        paths += Fill.lines(in: solid, spacing: gap, angle: angle)
            .map { Extrusion(kind: .solidFill, points: $0, closed: false) }
        if s.infillDensity > 0 {
            paths += Fill.lines(in: sparse, spacing: gap / s.infillDensity, angle: angle)
                .map { Extrusion(kind: .sparseFill, points: $0, closed: false) }
        }
        return paths
    }
}

/// Parallel straight lines covering an area.
nonisolated enum Fill {
    static func lines(in area: [Polyline], spacing mm: Double, angle: Double) -> [Polyline] {
        let all = area.flatMap { $0 }
        guard !all.isEmpty, mm > 0 else { return [] }
        let spacing = mm * Units.perMM

        // `along` is the direction the lines run, `across` the direction
        // from one line to the next.
        let along = (x: cos(angle), y: sin(angle))
        let across = (x: -sin(angle), y: cos(angle))
        func a(_ p: IntPoint) -> Double { Double(p.x) * along.x + Double(p.y) * along.y }
        func c(_ p: IntPoint) -> Double { Double(p.x) * across.x + Double(p.y) * across.y }

        let alongRange = (all.map(a).min()! - 1000, all.map(a).max()! + 1000)
        // Line numbers count from the bed's origin, not from this area's
        // edge, so sparse infill lines sit on top of the ones two layers down.
        let first = Int((all.map(c).min()! / spacing).rounded(.up))
        let last = Int((all.map(c).max()! / spacing).rounded(.down))
        guard first <= last else { return [] }

        let candidates: [Polyline] = (first...last).map { k in
            let offset = Double(k) * spacing
            return [alongRange.0, alongRange.1].map { t in
                IntPoint(x: Int64((across.x * offset + along.x * t).rounded()),
                         y: Int64((across.y * offset + along.y * t).rounded()))
            }
        }

        // Clipper returns the kept pieces in no useful order. Sort them into
        // a back-and-forth sweep (odd lines reversed) so the nozzle doesn't
        // fly to the far end before each one.
        let pieces = Clip.clipLines(candidates, to: area).filter { $0.count >= 2 }
        let keyed = pieces.map { piece -> (line: Int, start: Double, points: Polyline) in
            let line = Int((c(piece[0]) / spacing).rounded())
            let forward = a(piece[0]) <= a(piece[piece.count - 1])
            let odd = line & 1 == 1
            let points = forward != odd ? piece : Array(piece.reversed())
            return (line, a(points[0]), points)
        }
        return keyed.sorted { l, r in
            if l.line != r.line { return l.line < r.line }
            return l.line & 1 == 1 ? l.start > r.start : l.start < r.start
        }.map(\.points)
    }
}

/// A thread-safe tally, for progress reporting from many threads.
nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
