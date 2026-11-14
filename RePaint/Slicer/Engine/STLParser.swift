import Foundation
import simd

nonisolated enum STLError: Error, LocalizedError, Equatable {
    case empty
    case truncated
    case badNumber
    case noTriangles

    var errorDescription: String? {
        switch self {
        case .empty: "The file is empty."
        case .truncated: "The STL file is cut short, so part of the model is missing."
        case .badNumber: "The STL file has a coordinate that isn't a real number."
        case .noTriangles: "No triangles were found. Is this an STL file?"
        }
    }
}

/// Reads both kinds of STL file: binary (almost all of them) and ASCII text.
nonisolated enum STLParser {
    /// Binary layout: 80 bytes of header, a 4-byte triangle count, then
    /// 50 bytes per triangle (normal, three corners, 2 spare bytes).
    private static let headerSize = 84
    private static let triangleSize = 50

    static func parse(_ data: Data) throws -> Mesh {
        guard !data.isEmpty else { throw STLError.empty }

        // Don't trust a leading "solid" to mean ASCII: plenty of binary files
        // start with that word in their header. The file size is the reliable
        // test, because a binary file's length follows exactly from its
        // triangle count.
        if let count = binaryTriangleCount(data),
           data.count == headerSize + count * triangleSize {
            return try parseBinary(data, count: count)
        }
        if looksLikeASCII(data) {
            return try parseASCII(data)
        }
        // Not text, and the size doesn't match: a binary file that lost its
        // tail (or gained junk). Refuse it rather than print half a model.
        throw binaryTriangleCount(data) == nil ? STLError.noTriangles : STLError.truncated
    }

    private static func binaryTriangleCount(_ data: Data) -> Int? {
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { raw in
            Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self)))
        }
    }

    private static func looksLikeASCII(_ data: Data) -> Bool {
        let start = String(decoding: data.prefix(512), as: UTF8.self)
        return start.drop(while: \.isWhitespace).hasPrefix("solid") && start.contains("facet")
    }

    private static func parseBinary(_ data: Data, count: Int) throws -> Mesh {
        guard count > 0 else { throw STLError.noTriangles }
        var vertices = [SIMD3<Float>]()
        vertices.reserveCapacity(count * 3)
        try data.withUnsafeBytes { raw in
            for t in 0..<count {
                // Skip the 12-byte normal: many exporters write zeros or
                // garbage there, so normals are recomputed from the corners.
                let base = headerSize + t * triangleSize + 12
                for corner in 0..<3 {
                    var v = SIMD3<Float>()
                    for axis in 0..<3 {
                        let bits = raw.loadUnaligned(fromByteOffset: base + corner * 12 + axis * 4,
                                                     as: UInt32.self)
                        v[axis] = Float(bitPattern: UInt32(littleEndian: bits))
                    }
                    // NaN or infinity would poison every later calculation.
                    guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { throw STLError.badNumber }
                    vertices.append(v)
                }
            }
        }
        return Mesh(vertices: vertices)
    }

    private static func parseASCII(_ data: Data) throws -> Mesh {
        let text = String(decoding: data, as: UTF8.self)
        var vertices = [SIMD3<Float>]()
        // Only "vertex x y z" lines matter; everything else is decoration.
        var words = text.split(whereSeparator: \.isWhitespace).makeIterator()
        while let word = words.next() {
            guard word == "vertex" else { continue }
            var v = SIMD3<Float>()
            for axis in 0..<3 {
                guard let token = words.next() else { throw STLError.truncated }
                guard let number = Float(token), number.isFinite else { throw STLError.badNumber }
                v[axis] = number
            }
            vertices.append(v)
        }
        guard !vertices.isEmpty else { throw STLError.noTriangles }
        guard vertices.count % 3 == 0 else { throw STLError.truncated }
        return Mesh(vertices: vertices)
    }
}
