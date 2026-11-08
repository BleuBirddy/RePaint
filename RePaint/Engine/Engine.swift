import Foundation
import CoreGraphics
import ImageIO
import simd

/// The image resampled to print resolution, with a color-layer count per pixel.
nonisolated struct Grid: Sendable {
    let width: Int
    let height: Int
    let widthMM: Double
    let heightMM: Double
    let rgb: [SIMD3<Double>]
    let levels: [Int]
}

nonisolated enum Engine {

    // MARK: Image loading

    /// Decodes any image file and applies its orientation (iPhone photos are often rotated).
    static func loadImage(data: Data, maxPixel: Int = 2400) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func crop(_ image: CGImage, _ s: PaintSettings) -> CGImage {
        let w = Double(image.width), h = Double(image.height)
        let x0 = (w * s.cropLeft).rounded(), x1 = (w * (1 - s.cropRight)).rounded()
        let y0 = (h * s.cropTop).rounded(), y1 = (h * (1 - s.cropBottom)).rounded()
        guard x1 - x0 >= 8, y1 - y0 >= 8 else { return image }
        return image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) ?? image
    }

    // MARK: Height map

    static func makeGrid(_ image: CGImage, _ s: PaintSettings) -> Grid {
        let img = crop(image, s)
        let aspect = Double(img.height) / Double(img.width)
        let wMM = s.widthMM
        let hMM = s.widthMM * aspect
        let w = max(2, Int((wMM / s.pixelMM).rounded()))
        let h = max(2, Int((hMM / s.pixelMM).rounded()))

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Transparent areas count as black (the backer color).
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        let n = w * h
        var rgb = [SIMD3<Double>](repeating: .zero, count: n)
        var lum = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let c = SIMD3(Double(bytes[i * 4]), Double(bytes[i * 4 + 1]), Double(bytes[i * 4 + 2])) / 255
            rgb[i] = c
            lum[i] = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        }

        // Stretch contrast so the darkest 1% sits on the base and the brightest reaches the top.
        let sorted = lum.sorted()
        let lo = sorted[Int(Double(n - 1) * 0.01)]
        var hi = sorted[Int(Double(n - 1) * 0.997)]
        if hi - lo < 1e-6 { hi = lo + 1e-6 }

        let top = Double(s.colorLayers)
        let levels = lum.map { v -> Int in
            var t = min(1, max(0, (v - lo) / (hi - lo)))
            if s.invert { t = 1 - t }
            return Int((pow(t, s.curve) * top).rounded())
        }
        return Grid(width: w, height: h, widthMM: wMM, heightMM: hMM, rgb: rgb, levels: levels)
    }

    // MARK: Color simulation

    /// How much of a filament shows through after one layer, based on its TD.
    static func opacity(td: Double, layerHeight: Double) -> Double {
        1 - exp(-3 * layerHeight / max(0.05, td))
    }

    /// The color a viewer sees for each color-layer count (index 0 = bare base).
    static func levelColors(_ f: [Filament], starts: [Int], _ s: PaintSettings) -> [SIMD3<Double>] {
        var out = [SIMD3<Double>]()
        out.reserveCapacity(s.colorLayers + 1)
        var c = f[0].rgb
        out.append(c)
        var fi = 0
        guard s.colorLayers >= 1 else { return out }
        for layer in 1...s.colorLayers {
            while fi + 1 < f.count && starts[fi + 1] <= layer { fi += 1 }
            let a = opacity(td: f[fi].td, layerHeight: s.layerHeight)
            c = c * (1 - a) + f[fi].rgb * a
            out.append(c)
        }
        return out
    }

    /// Forces start layers to increase and to fit within the color layers.
    static func normalized(_ starts: [Int], layers: Int) -> [Int] {
        var s = starts
        let k = s.count
        guard k > 0 else { return s }
        s[0] = 0
        for i in 1..<k {
            let lo = s[i - 1] + 1
            let hi = max(lo, layers - (k - 1 - i))
            s[i] = min(max(s[i], lo), hi)
        }
        return s
    }

    /// Tries every set of swap layers and keeps the one whose simulated colors best match the image.
    static func optimize(_ g: Grid, _ f: [Filament], _ s: PaintSettings) -> [Int] {
        let k = f.count
        let top = s.colorLayers
        guard k > 1, top >= k - 1 else { return normalized(f.map(\.startLayer), layers: top) }

        // Per-level sums let each candidate be scored in O(layers) instead of O(pixels).
        var count = [Double](repeating: 0, count: top + 1)
        var sum = [SIMD3<Double>](repeating: .zero, count: top + 1)
        var sumSq = [Double](repeating: 0, count: top + 1)
        for i in 0..<g.levels.count {
            let l = min(g.levels[i], top)
            let c = g.rgb[i]
            count[l] += 1
            sum[l] += c
            sumSq[l] += (c * c).sum()
        }

        let alphas = f.map { opacity(td: $0.td, layerHeight: s.layerHeight) }
        var starts = [Int](repeating: 0, count: k)
        var best = normalized(f.map(\.startLayer), layers: top)
        var bestErr = Double.infinity

        func score() -> Double {
            var c = f[0].rgb
            var err = sumSq[0] - 2 * simd_dot(c, sum[0]) + count[0] * simd_dot(c, c)
            var fi = 0
            for layer in 1...top {
                while fi + 1 < k && starts[fi + 1] <= layer { fi += 1 }
                c = c * (1 - alphas[fi]) + f[fi].rgb * alphas[fi]
                err += sumSq[layer] - 2 * simd_dot(c, sum[layer]) + count[layer] * simd_dot(c, c)
            }
            return err
        }

        func search(_ idx: Int, _ minStart: Int) {
            if idx == k {
                let e = score()
                if e < bestErr { bestErr = e; best = starts }
                return
            }
            let maxStart = top - (k - 1 - idx)
            guard minStart <= maxStart else { return }
            for v in minStart...maxStart {
                starts[idx] = v
                search(idx + 1, v + 1)
            }
        }
        search(1, 1)
        return best
    }

    static func previewImage(_ g: Grid, _ colors: [SIMD3<Double>]) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: g.width * g.height * 4)
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        for i in 0..<g.levels.count {
            let c = colors[min(g.levels[i], colors.count - 1)]
            bytes[i * 4] = byte(c.x)
            bytes[i * 4 + 1] = byte(c.y)
            bytes[i * 4 + 2] = byte(c.z)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: g.width, height: g.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: g.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: STL export

    static func triangleCount(_ g: Grid) -> Int {
        4 * g.width * g.height + 4 * (g.width + g.height)
    }

    /// A closed, watertight binary STL: textured top, flat bottom, four walls.
    static func stl(_ g: Grid, _ s: PaintSettings) -> Data {
        let w = g.width, h = g.height
        let px = Float(s.pixelMM), lh = Float(s.layerHeight)

        func pixelZ(_ i: Int, _ j: Int) -> Float {
            Float(s.baseLayers + g.levels[j * w + i]) * lh
        }
        // Corner heights average the pixels that touch them, which smooths stair-steps.
        var corner = [Float](repeating: 0, count: (w + 1) * (h + 1))
        for j in 0...h {
            for i in 0...w {
                var total: Float = 0, n: Float = 0
                if i > 0 && j > 0 { total += pixelZ(i - 1, j - 1); n += 1 }
                if i < w && j > 0 { total += pixelZ(i, j - 1); n += 1 }
                if i > 0 && j < h { total += pixelZ(i - 1, j); n += 1 }
                if i < w && j < h { total += pixelZ(i, j); n += 1 }
                corner[j * (w + 1) + i] = total / n
            }
        }
        // Row 0 of the image is the top edge, so it gets the largest y.
        func v(_ i: Int, _ j: Int, _ topSurface: Bool) -> SIMD3<Float> {
            SIMD3(Float(i) * px, Float(h - j) * px, topSurface ? corner[j * (w + 1) + i] : 0)
        }

        let count = triangleCount(g)
        var data = Data(count: 84 + 50 * count)
        data.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress else { return }
            for (k, b) in Array("RePaint".utf8).enumerated() {
                p.storeBytes(of: b, toByteOffset: k, as: UInt8.self)
            }
            p.storeBytes(of: UInt32(count).littleEndian, toByteOffset: 80, as: UInt32.self)
            var off = 84

            func put(_ x: Float) {
                p.storeBytes(of: x.bitPattern.littleEndian, toByteOffset: off, as: UInt32.self)
                off += 4
            }
            func put(_ v: SIMD3<Float>) { put(v.x); put(v.y); put(v.z) }
            func tri(_ a: SIMD3<Float>, _ b0: SIMD3<Float>, _ c0: SIMD3<Float>, _ outward: SIMD3<Float>) {
                var b = b0, c = c0
                var n = simd_cross(b - a, c - a)
                if simd_dot(n, outward) < 0 { swap(&b, &c); n = -n }
                let len = simd_length(n)
                if len > 0 { n /= len }
                put(n); put(a); put(b); put(c)
                off += 2 // attribute byte count, left as zero
            }

            let up = SIMD3<Float>(0, 0, 1), down = SIMD3<Float>(0, 0, -1)
            for j in 0..<h {
                for i in 0..<w {
                    tri(v(i, j, true), v(i + 1, j, true), v(i + 1, j + 1, true), up)
                    tri(v(i, j, true), v(i + 1, j + 1, true), v(i, j + 1, true), up)
                    tri(v(i, j, false), v(i + 1, j, false), v(i + 1, j + 1, false), down)
                    tri(v(i, j, false), v(i + 1, j + 1, false), v(i, j + 1, false), down)
                }
            }
            for i in 0..<w {
                for (j, out) in [(0, SIMD3<Float>(0, 1, 0)), (h, SIMD3<Float>(0, -1, 0))] {
                    tri(v(i, j, true), v(i + 1, j, true), v(i + 1, j, false), out)
                    tri(v(i, j, true), v(i + 1, j, false), v(i, j, false), out)
                }
            }
            for j in 0..<h {
                for (i, out) in [(0, SIMD3<Float>(-1, 0, 0)), (w, SIMD3<Float>(1, 0, 0))] {
                    tri(v(i, j, true), v(i, j + 1, true), v(i, j + 1, false), out)
                    tri(v(i, j, true), v(i, j + 1, false), v(i, j, false), out)
                }
            }
        }
        return data
    }
}
