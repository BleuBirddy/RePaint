import Foundation
import simd

/// A triangle mesh in printer coordinates: millimetres, Z pointing up.
///
/// The vertices are stored three per triangle with no sharing. STL files are
/// written that way, and slicing reads triangles one at a time, so an index
/// buffer would only add work.
nonisolated struct Mesh: Sendable, Equatable {
    var vertices: [SIMD3<Float>]

    var triangleCount: Int { vertices.count / 3 }

    /// The smallest and largest corner of the box around the model.
    /// nil for an empty mesh.
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var lo = vertices.first else { return nil }
        var hi = lo
        for v in vertices {
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return (lo, hi)
    }

    /// Width, depth and height in millimetres.
    var size: SIMD3<Float> {
        guard let b = bounds else { return .zero }
        return b.max - b.min
    }

    /// The same model moved so it sits on the bed (lowest point at Z = 0)
    /// with its middle over the given bed point.
    ///
    /// STL files carry whatever position the CAD program left the part in,
    /// often far from the origin or below it.
    func placedOnBed(centreX: Float, centreY: Float) -> Mesh {
        guard let b = bounds else { return self }
        let middle = (b.min + b.max) / 2
        let shift = SIMD3<Float>(centreX - middle.x, centreY - middle.y, -b.min.z)
        return Mesh(vertices: vertices.map { $0 + shift })
    }
}

/// The printable area. RePaint starts with one printer.
nonisolated struct Bed: Sendable, Equatable {
    var width: Float
    var depth: Float
    var height: Float

    /// 256 mm cube: the build volume Bambu states for the P1P (the first
    /// printer RePaint targets), shared with the X1, P1S and A1.
    static let bambu256 = Bed(width: 256, depth: 256, height: 256)

    func fits(_ mesh: Mesh) -> Bool {
        let s = mesh.size
        return s.x <= width && s.y <= depth && s.z <= height
    }
}
