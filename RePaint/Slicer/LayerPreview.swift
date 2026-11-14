import SwiftUI

/// One layer seen from above: every line the nozzle will draw, coloured by
/// what it is, with a slider to move up and down through the print.
struct LayerPreview: View {
    let result: SliceResult
    let mesh: Mesh
    @State private var layer = 0.0

    private var index: Int { min(Int(layer), result.layers.count - 1) }

    var body: some View {
        VStack(spacing: 0) {
            Canvas { context, size in
                draw(result.layers[index], in: &context, size: size)
            }
            .background(Color(white: 0.12))

            VStack(spacing: 6) {
                HStack {
                    Text("Layer \(index + 1) of \(result.layers.count)")
                    if showsFilament {
                        Text(filamentLabel).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(result.layers[index].z.formatted(.number.precision(.fractionLength(2)))) mm")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.monospacedDigit())
                if result.layers.count > 1 {
                    Slider(value: $layer, in: 0...Double(result.layers.count - 1), step: 1)
                }
                // Two rows of three: six names in one row don't fit an iPhone
                // without shrinking to different sizes.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                          spacing: 4) {
                    ForEach(PathKind.allCases, id: \.self) { kind in
                        HStack(spacing: 4) {
                            Circle().fill(Self.color(kind)).frame(width: 8, height: 8)
                            Text(kind.gcodeName)
                        }
                    }
                }
                .font(.caption2)
                .lineLimit(1)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        // Start in the middle: the first layer is all solid fill and says
        // little about the inside.
        .onAppear { layer = Double(result.layers.count / 2) }
    }

    /// Only worth showing when there is more than one filament in the print.
    private var showsFilament: Bool { !result.settings.sortedSwaps.isEmpty }

    private var filamentLabel: String {
        let f = result.settings.filament(forLayer: index + 1)
        return "· slot \(f.slot)" + (f.name.isEmpty ? "" : " \(f.name)")
    }

    private func draw(_ layer: SlicedLayer, in context: inout GraphicsContext, size: CGSize) {
        guard let bounds = mesh.bounds else { return }
        // Fit the model, plus room for the skirt, into the view.
        let margin = result.settings.skirtDistance + 3
        let minX = Double(bounds.min.x) - margin, maxX = Double(bounds.max.x) + margin
        let minY = Double(bounds.min.y) - margin, maxY = Double(bounds.max.y) + margin
        let scale = min(size.width / (maxX - minX), size.height / (maxY - minY))
        let left = (size.width - (maxX - minX) * scale) / 2
        let top = (size.height - (maxY - minY) * scale) / 2

        func place(_ p: IntPoint) -> CGPoint {
            // Screen Y grows downwards, the bed's Y grows away from you.
            CGPoint(x: left + (p.mmX - minX) * scale, y: top + (maxY - p.mmY) * scale)
        }

        // Draw lines at their real width, so gaps and overlaps show as they
        // would print (but never thinner than a hairline).
        let width = max(result.settings.lineWidth * scale * 0.85, 0.75)
        for kind in PathKind.allCases {
            var shape = Path()
            for path in layer.paths where path.kind == kind {
                shape.addLines(path.points.map(place))
                if path.closed { shape.closeSubpath() }
            }
            context.stroke(shape, with: .color(Self.color(kind)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    static func color(_ kind: PathKind) -> Color {
        switch kind {
        case .skirt: .gray
        case .support: .green
        case .outerWall: .orange
        case .innerWall: .yellow
        case .solidFill: .purple
        case .sparseFill: .teal
        }
    }
}
