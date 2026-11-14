import Foundation
import simd

/// Cuts the mesh with horizontal planes and returns the outline of the model
/// at each one.
nonisolated enum LayerSlicer {
    struct Output {
        /// One tidy area (see `Clip`) per plane.
        var areas: [[Polyline]]
        /// How many layers had an outline that didn't close. That means the
        /// mesh has a hole or a stray triangle there; the broken outline is
        /// left out, so the print may be missing something.
        var layersWithGaps: Int
    }

    /// `planes` are the cutting heights in mm, lowest first.
    static func outlines(mesh: Mesh, planes: [Float]) -> Output {
        var segments = [[(IntPoint, IntPoint)]](repeating: [], count: planes.count)

        for t in stride(from: 0, to: mesh.vertices.count, by: 3) {
            let tri = [mesh.vertices[t], mesh.vertices[t + 1], mesh.vertices[t + 2]]
            let low = min(tri[0].z, tri[1].z, tri[2].z)
            let high = max(tri[0].z, tri[1].z, tri[2].z)

            // A corner exactly on a plane counts as above it, never "on" it.
            // With that one rule every triangle a plane passes through gives
            // exactly one segment, and flat triangles lying in the plane give
            // none, so there are no special cases to get wrong.
            // So a plane cuts this triangle when low < plane <= high.
            var i = firstIndex(in: planes, above: low)
            while i < planes.count, planes[i] <= high {
                if let segment = cut(tri, at: planes[i]) {
                    segments[i].append(segment)
                }
                i += 1
            }
        }

        var areas = [[Polyline]](repeating: [], count: planes.count)
        var gaps = 0
        for i in planes.indices {
            let (loops, hadOpenChain) = chain(segments[i])
            if hadOpenChain { gaps += 1 }
            areas[i] = Clip.tidy(loops)
        }
        return Output(areas: areas, layersWithGaps: gaps)
    }

    /// Index of the first plane strictly above `z` (binary search).
    private static func firstIndex(in planes: [Float], above z: Float) -> Int {
        var lo = 0, hi = planes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if planes[mid] > z { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// The line where a plane crosses one triangle.
    private static func cut(_ tri: [SIMD3<Float>], at plane: Float) -> (IntPoint, IntPoint)? {
        var ends = [IntPoint]()
        for e in 0..<3 {
            let a = tri[e], b = tri[(e + 1) % 3]
            guard (a.z >= plane) != (b.z >= plane) else { continue }
            // Always measure from the lower corner to the upper one. The
            // neighbouring triangle shares this edge but lists its corners in
            // the opposite order; measuring the same way round makes both
            // arrive at the identical point, so the outline joins up.
            let (lower, upper) = a.z < b.z ? (a, b) : (b, a)
            let t = Double(plane - lower.z) / Double(upper.z - lower.z)
            ends.append(IntPoint(mmX: Double(lower.x) + Double(upper.x - lower.x) * t,
                                 mmY: Double(lower.y) + Double(upper.y - lower.y) * t))
        }
        guard ends.count == 2, ends[0] != ends[1] else { return nil }
        return (ends[0], ends[1])
    }

    /// Joins loose segments end to end into closed loops.
    private static func chain(_ segments: [(IntPoint, IntPoint)]) -> (loops: [Polyline], hadOpenChain: Bool) {
        var touching = [IntPoint: [Int]]()
        for (index, s) in segments.enumerated() {
            touching[s.0, default: []].append(index)
            touching[s.1, default: []].append(index)
        }

        var used = [Bool](repeating: false, count: segments.count)
        var loops = [Polyline]()
        var hadOpenChain = false

        for start in segments.indices where !used[start] {
            used[start] = true
            var loop = [segments[start].0]
            var current = segments[start].1
            var closed = false
            while true {
                if current == loop[0] {
                    closed = true
                    break
                }
                loop.append(current)
                guard let next = touching[current]?.first(where: { !used[$0] }) else { break }
                used[next] = true
                current = segments[next].0 == current ? segments[next].1 : segments[next].0
            }
            if !closed {
                hadOpenChain = true
            } else if loop.count >= 3 {
                loops.append(loop)
            }
            // A closed "loop" of two points is a sliver with no area (two
            // triangles meeting the plane along the same hair-thin line).
            // It's harmless, so it is dropped without counting as a gap.
        }
        return (loops, hadOpenChain)
    }
}
