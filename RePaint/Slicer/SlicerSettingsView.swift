import SwiftUI

/// The choices the user can make before slicing: supports and filament swaps.
/// (Layer height, walls, infill and temperatures are still fixed defaults.)
struct SlicerSettingsView: View {
    @Bindable var model: SlicerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                supports
                filaments
            }
            .formStyle(.grouped)
            .navigationTitle("Slice settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // A Mac sheet is only as big as its content asks for.
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private var supports: some View {
        Section {
            Picker("Supports", selection: $model.settings.supportMode) {
                ForEach(SupportMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if model.settings.supportMode != .off {
                Stepper(value: $model.settings.supportThresholdAngle, in: 10...80, step: 5) {
                    LabeledContent("Support below", value: "\(Int(model.settings.supportThresholdAngle))°")
                }
            }
        } header: {
            Text("Supports")
        } footer: {
            WrappingText(supportHelp)
        }
    }

    private var supportHelp: String {
        let angleHelp = " A surface gets support when it leans closer to flat than the angle above (measured up from the bed). Raise the angle for more support."
        switch model.settings.supportMode {
        case .off:
            return "Nothing is printed under overhangs. Parts of the model that hang in the air will droop or fail."
        case .bedOnly:
            return "Scaffolding is built only where it can stand on the bed. Overhangs above another part of the model get none, and the model's surfaces stay unmarked." + angleHelp
        case .everywhere:
            return "Scaffolding is built under every overhang, standing on the model where it has to. That can leave marks where it stood." + angleHelp
        }
    }

    private var filaments: some View {
        Section {
            Picker(startLabel, selection: $model.settings.firstSlot) {
                ForEach(1...Self.slotCount, id: \.self) { Text("Slot \($0)").tag($0) }
            }
            ForEach($model.settings.filamentSwaps) { $swap in
                VStack(alignment: .leading, spacing: 6) {
                    if !swap.name.isEmpty {
                        Text(swap.name).font(.subheadline.weight(.medium))
                    }
                    Stepper(value: $swap.layer, in: 2...9999) {
                        LabeledContent("From layer", value: "\(swap.layer) (\(height(of: swap.layer)) mm)")
                    }
                    Picker("AMS slot", selection: $swap.slot) {
                        ForEach(1...max(Self.slotCount, swap.slot), id: \.self) { Text("Slot \($0)").tag($0) }
                    }
                }
            }
            .onDelete { model.settings.filamentSwaps.remove(atOffsets: $0) }

            Button("Add a filament swap", systemImage: "plus") { addSwap() }
        } header: {
            Text("Filament")
        } footer: {
            WrappingText("At each swap the printer changes to the filament in that AMS slot before the layer starts. The swap commands are untested on a real printer, and they don't flush the old colour out, so the first lines after a swap will be mixed."
                         + deleteHint)
        }
    }

    private var startLabel: String {
        let name = model.settings.firstFilamentName
        return name.isEmpty ? "Start with" : "Start with \(name) in"
    }

    private var deleteHint: String {
        #if os(iOS)
        model.settings.filamentSwaps.isEmpty ? "" : " Swipe a swap left to remove it."
        #else
        ""
        #endif
    }

    /// One AMS holds four spools.
    private static let slotCount = 4

    /// The Z height where a layer starts printing (the top of the one below).
    private func height(of layer: Int) -> String {
        let s = model.settings
        let z = s.firstLayerHeight + Double(layer - 2) * s.layerHeight
        return z.formatted(.number.precision(.fractionLength(2)))
    }

    /// A new swap goes a few layers above the last one, in the next slot, so
    /// tapping Add twice doesn't make two swaps on the same layer.
    private func addSwap() {
        let last = model.settings.sortedSwaps.last
        let layer = (last?.layer ?? 1) + 5
        let slot = min((last?.slot ?? model.settings.firstSlot) + 1, Self.slotCount)
        model.settings.filamentSwaps.append(FilamentSwap(layer: layer, slot: slot))
    }
}

/// Footer text that wraps instead of pushing the form wider than its window
/// (the Mac needs this; see the same fix in PainterView).
private struct WrappingText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
