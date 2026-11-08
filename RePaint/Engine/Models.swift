import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import SwiftUI

/// One spool. Filaments are listed bottom (printed first) to top.
nonisolated struct Filament: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var r: Double
    var g: Double
    var b: Double
    /// Transmission distance in mm (how thick a stack has to be before it looks fully opaque).
    var td: Double
    /// Number of layers above the base where this filament starts. Ignored for the first filament.
    var startLayer: Int

    var rgb: SIMD3<Double> { SIMD3(r, g, b) }

    static let defaults: [Filament] = [
        Filament(name: "Black", r: 0.08, g: 0.08, b: 0.08, td: 0.6, startLayer: 0),
        Filament(name: "Brass Silk", r: 0.72, g: 0.58, b: 0.30, td: 3.0, startLayer: 3),
        Filament(name: "White Rock Marble", r: 0.93, g: 0.93, b: 0.90, td: 2.0, startLayer: 10),
    ]
}

nonisolated struct PaintSettings: Codable, Hashable, Sendable {
    var widthMM: Double = 85
    var layerHeight: Double = 0.08
    var baseLayers: Int = 8
    var colorLayers: Int = 22
    var pixelMM: Double = 0.25
    var curve: Double = 0.85
    var invert: Bool = false
    // Crop, as a fraction of the image cut from each side.
    var cropLeft: Double = 0
    var cropRight: Double = 0
    var cropTop: Double = 0
    var cropBottom: Double = 0
}

/// Lets non-Sendable Core Graphics values cross into background work.
nonisolated struct Box<T>: @unchecked Sendable {
    let value: T
}

extension UTType {
    nonisolated static let stlModel: UTType = UTType(filenameExtension: "stl", conformingTo: .data) ?? .data
}

nonisolated struct STLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.stlModel] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A placeholder image so the app opens showing a working preview.
nonisolated enum SampleImage {
    static func make() -> CGImage? {
        let size = 900
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let center = CGPoint(x: 450, y: 450)
        let moon = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 1, green: 1, blue: 0.97, alpha: 1),
            CGColor(srgbRed: 0.55, green: 0.55, blue: 0.52, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 110, y: 110, width: 680, height: 680))
        ctx.clip()
        ctx.drawRadialGradient(moon, startCenter: CGPoint(x: 380, y: 540), startRadius: 0,
                               endCenter: center, endRadius: 360, options: [])
        let crater = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 0.25, green: 0.25, blue: 0.24, alpha: 0.85),
            CGColor(srgbRed: 0.25, green: 0.25, blue: 0.24, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        let craters: [(CGFloat, CGFloat, CGFloat)] = [
            (330, 600, 70), (560, 520, 95), (470, 300, 60), (260, 380, 45), (620, 330, 40), (420, 450, 30),
        ]
        for (x, y, r) in craters {
            ctx.drawRadialGradient(crater, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                   endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
