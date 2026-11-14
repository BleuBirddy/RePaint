import XCTest
import simd
@testable import RePaint

final class STLParserTests: XCTestCase {
    /// Two triangles: a 10 × 20 mm rectangle lying 5 mm above Z = 0.
    private let corners: [SIMD3<Float>] = [
        [0, 0, 5], [10, 0, 5], [10, 20, 5],
        [0, 0, 5], [10, 20, 5], [0, 20, 5],
    ]

    private func binarySTL(header: String = "RePaint test", _ vertices: [SIMD3<Float>]) -> Data {
        var data = Data(header.utf8)
        data.append(Data(count: 80 - data.count))
        withUnsafeBytes(of: UInt32(vertices.count / 3).littleEndian) { data.append(contentsOf: $0) }
        for t in stride(from: 0, to: vertices.count, by: 3) {
            data.append(Data(count: 12)) // normal, left as zeros like many exporters do
            for v in vertices[t..<t + 3] {
                for axis in 0..<3 {
                    withUnsafeBytes(of: v[axis].bitPattern.littleEndian) { data.append(contentsOf: $0) }
                }
            }
            data.append(Data(count: 2))
        }
        return data
    }

    private func asciiSTL(_ vertices: [SIMD3<Float>]) -> Data {
        var text = "solid test\n"
        for t in stride(from: 0, to: vertices.count, by: 3) {
            text += " facet normal 0 0 1\n  outer loop\n"
            for v in vertices[t..<t + 3] { text += "   vertex \(v.x) \(v.y) \(v.z)\n" }
            text += "  endloop\n endfacet\n"
        }
        text += "endsolid test\n"
        return Data(text.utf8)
    }

    func testBinary() throws {
        let mesh = try STLParser.parse(binarySTL(corners))
        XCTAssertEqual(mesh.vertices, corners)
        XCTAssertEqual(mesh.triangleCount, 2)
        XCTAssertEqual(mesh.size, [10, 20, 0])
    }

    func testASCII() throws {
        XCTAssertEqual(try STLParser.parse(asciiSTL(corners)).vertices, corners)
    }

    /// Some exporters start a binary file's header with "solid", which a
    /// naive reader takes for a text file.
    func testBinaryWhoseHeaderSaysSolid() throws {
        let data = binarySTL(header: "solid facet exported by SomeCAD", corners)
        XCTAssertEqual(try STLParser.parse(data).vertices, corners)
    }

    func testTruncatedBinaryIsRefused() {
        let data = binarySTL(corners).dropLast(20)
        XCTAssertThrowsError(try STLParser.parse(Data(data))) {
            XCTAssertEqual($0 as? STLError, .truncated)
        }
    }

    func testTruncatedASCIIIsRefused() {
        let text = String(decoding: asciiSTL(corners), as: UTF8.self)
        let cut = text.components(separatedBy: "vertex").dropLast().joined(separator: "vertex")
        XCTAssertThrowsError(try STLParser.parse(Data(cut.utf8))) {
            XCTAssertEqual($0 as? STLError, .truncated)
        }
    }

    func testNaNIsRefused() {
        var bad = corners
        bad[2].z = .nan
        XCTAssertThrowsError(try STLParser.parse(binarySTL(bad))) {
            XCTAssertEqual($0 as? STLError, .badNumber)
        }
    }

    func testNotAnSTL() {
        XCTAssertThrowsError(try STLParser.parse(Data("hello".utf8)))
        XCTAssertThrowsError(try STLParser.parse(Data())) {
            XCTAssertEqual($0 as? STLError, .empty)
        }
    }

    func testPlacedOnBed() throws {
        let placed = try STLParser.parse(binarySTL(corners)).placedOnBed(centreX: 128, centreY: 128)
        let b = try XCTUnwrap(placed.bounds)
        XCTAssertEqual(b.min, [123, 118, 0])
        XCTAssertEqual(b.max, [133, 138, 0])
    }

    func testBedFit() throws {
        let mesh = try STLParser.parse(binarySTL(corners))
        XCTAssertTrue(Bed.bambu256.fits(mesh))
        XCTAssertFalse(Bed(width: 5, depth: 256, height: 256).fits(mesh))
    }
}
