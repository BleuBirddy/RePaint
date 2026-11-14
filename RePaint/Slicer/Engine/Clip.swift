import Foundation

/// A 2D point in whole micrometres (1/1000 mm).
///
/// Whole numbers, not decimals, because outline maths with floating point
/// goes wrong in tiny ways (two points that should be equal aren't), and
/// those tiny errors become gaps in walls. Every real slicer does this.
nonisolated struct IntPoint: Hashable, Sendable {
    var x: Int64
    var y: Int64

    init(x: Int64, y: Int64) {
        self.x = x
        self.y = y
    }

    init(mmX: Double, mmY: Double) {
        x = Int64((mmX * Units.perMM).rounded())
        y = Int64((mmY * Units.perMM).rounded())
    }

    var mmX: Double { Double(x) / Units.perMM }
    var mmY: Double { Double(y) / Units.perMM }

    func distance(to other: IntPoint) -> Double {
        hypot(Double(other.x - x), Double(other.y - y))
    }
}

nonisolated enum Units {
    static let perMM: Double = 1000
}

/// A list of points. Whether it is a closed loop or an open line depends on
/// where it is used.
typealias Polyline = [IntPoint]

/// Outline maths, done by the Clipper2 library (see ClipperBridge.h).
///
/// "Area" below means a set of closed loops in Clipper's tidy form: outer
/// edges run anticlockwise, holes clockwise, nothing overlaps. `tidy` turns
/// raw loops into that form; every other function expects and returns it.
nonisolated enum Clip {
    /// Turns raw loops from the mesh into a tidy area. A loop inside another
    /// loop becomes a hole, whichever way round either was drawn.
    static func tidy(_ loops: [Polyline]) -> [Polyline] {
        boolean(0, evenOdd: true, loops, [])
    }

    /// Grows the area by `mm` (or shrinks it, if negative). Parts thinner
    /// than twice the shrink distance vanish, which is exactly what we want:
    /// a wall that can't fit isn't drawn.
    static func offset(_ area: [Polyline], mm: Double, round: Bool = false) -> [Polyline] {
        guard !area.isEmpty, mm != 0 else { return area }
        return withPacked(area) { coords, counts, n in
            take(clip_offset(coords, counts, n, mm * Units.perMM, round ? 1 : 0))
        }
    }

    static func union(_ a: [Polyline], _ b: [Polyline]) -> [Polyline] { boolean(0, evenOdd: false, a, b) }
    static func difference(_ a: [Polyline], _ b: [Polyline]) -> [Polyline] {
        a.isEmpty ? [] : boolean(1, evenOdd: false, a, b)
    }
    static func intersection(_ a: [Polyline], _ b: [Polyline]) -> [Polyline] {
        a.isEmpty || b.isEmpty ? [] : boolean(2, evenOdd: false, a, b)
    }

    /// The pieces of the open `lines` that fall inside `area`.
    static func clipLines(_ lines: [Polyline], to area: [Polyline]) -> [Polyline] {
        guard !lines.isEmpty, !area.isEmpty else { return [] }
        return withPacked(lines) { lc, ln, lCount in
            withPacked(area) { ac, an, aCount in
                take(clip_clip_lines(lc, ln, lCount, ac, an, aCount))
            }
        }
    }

    /// Total area in mm², holes subtracted.
    static func areaMM2(_ area: [Polyline]) -> Double {
        var sum = 0.0
        for path in area where path.count >= 3 {
            var twice = 0.0
            var previous = path[path.count - 1]
            for p in path {
                twice += Double(previous.x) * Double(p.y) - Double(p.x) * Double(previous.y)
                previous = p
            }
            sum += twice / 2
        }
        return sum / (Units.perMM * Units.perMM)
    }

    // MARK: - Plumbing

    private static func boolean(_ op: Int32, evenOdd: Bool, _ a: [Polyline], _ b: [Polyline]) -> [Polyline] {
        withPacked(a) { ac, an, aCount in
            withPacked(b) { bc, bn, bCount in
                take(clip_boolean(op, evenOdd ? 1 : 0, ac, an, aCount, bc, bn, bCount))
            }
        }
    }

    /// Flattens paths into the two plain arrays the C functions read.
    private static func withPacked<R>(
        _ paths: [Polyline],
        _ body: (UnsafePointer<Int64>, UnsafePointer<Int32>, Int32) -> R
    ) -> R {
        var coords = [Int64]()
        coords.reserveCapacity(paths.reduce(0) { $0 + $1.count } * 2 + 1)
        var counts = [Int32]()
        counts.reserveCapacity(paths.count + 1)
        for path in paths {
            counts.append(Int32(path.count))
            for p in path {
                coords.append(p.x)
                coords.append(p.y)
            }
        }
        // An empty Swift array may hand C a null pointer; one spare element
        // guarantees a real address even when there are no paths.
        coords.append(0)
        counts.append(0)
        return coords.withUnsafeBufferPointer { c in
            counts.withUnsafeBufferPointer { n in
                body(c.baseAddress!, n.baseAddress!, Int32(paths.count))
            }
        }
    }

    /// Copies a C result into Swift arrays and frees the C memory, so no
    /// caller can forget to.
    private static func take(_ packed: ClipPaths) -> [Polyline] {
        defer { clip_free(packed) }
        var paths = [Polyline]()
        paths.reserveCapacity(Int(packed.pathCount))
        var at = 0
        for p in 0..<Int(packed.pathCount) {
            let count = Int(packed.counts[p])
            var path = Polyline()
            path.reserveCapacity(count)
            for _ in 0..<count {
                path.append(IntPoint(x: packed.coords[at], y: packed.coords[at + 1]))
                at += 2
            }
            paths.append(path)
        }
        return paths
    }
}
