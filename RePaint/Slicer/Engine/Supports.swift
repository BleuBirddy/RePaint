import Foundation

/// Works out where scaffolding is needed under overhangs.
///
/// The method is the simplest one that works: wherever a layer sticks out
/// further over the layer below than the printer can manage, a column is
/// built straight down from there until it meets the bed or the model.
/// There is no bridge detection, no tree supports and no dense "interface"
/// layer on top, so supports use more plastic and leave a rougher underside
/// than a desktop slicer's would.
nonisolated enum Supports {
    /// One area per layer (empty where no support is needed).
    /// `areas` are the model's outlines, `heights` the layer heights.
    static func regions(areas: [[Polyline]], heights: [Double], settings s: SliceSettings) -> [[Polyline]] {
        let n = areas.count
        var regions = [[Polyline]](repeating: [], count: n)
        guard s.supportMode != .off, n > 1 else { return regions }

        let angle = min(max(s.supportThresholdAngle, 1), 89) * .pi / 180
        var column = [Polyline]()

        // Top to bottom, carrying the column down one layer at a time.
        for j in stride(from: n - 2, through: 0, by: -1) {
            // Layer k is the one whose overhang this layer starts holding
            // up; the layers in between are the air gap.
            let k = j + 1 + s.supportGapLayers
            if k < n {
                // A wall leaning at the threshold angle moves sideways by
                // this much per layer. Anything sticking out further than
                // that over the layer below is an overhang.
                let allowed = heights[k] / tan(angle)
                var overhang = Clip.difference(areas[k], Clip.offset(areas[k - 1], mm: allowed))
                // Shrink-then-grow drops strips too thin to matter.
                overhang = Clip.offset(Clip.offset(overhang, mm: -s.lineWidth / 2), mm: s.lineWidth / 2)
                column = Clip.union(column, overhang)
            }
            // Supports never pass through the model, and keep a little
            // distance from its walls.
            column = Clip.difference(column, Clip.offset(areas[j], mm: s.supportSideGap))
            regions[j] = column
        }

        if s.supportMode == .bedOnly {
            // Bottom to top: a spot keeps its support only if every layer
            // beneath it has support too, all the way down to the bed.
            for j in 1..<n {
                regions[j] = Clip.intersection(regions[j], regions[j - 1])
            }
        }
        return regions
    }

    /// The lines that print one layer of support: an outline, so even a
    /// narrow column gets printed and stands up, plus widely spaced straight
    /// lines inside. The lines run the same way on every layer, forming thin
    /// walls that break away cleanly.
    static func paths(for region: [Polyline], settings s: SliceSettings) -> [Extrusion] {
        let inner = Clip.offset(region, mm: -s.lineWidth / 2)
        guard !inner.isEmpty else { return [] }
        return inner.map { Extrusion(kind: .support, points: $0, closed: true) }
            + Fill.lines(in: inner, spacing: s.supportSpacing, angle: 0)
                .map { Extrusion(kind: .support, points: $0, closed: false) }
    }
}
