import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = PainterModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var importing = false
    @State private var exportDoc: STLDocument?
    @State private var exporting = false
    @State private var showOriginal = false

    var body: some View {
        layout
            .task(id: model.rebuildKey) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.rebuild()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await model.loadImageData(data, name: "Photo")
                    } else {
                        model.message = "Couldn't load that photo. If it's in iCloud, wait for it to download and try again."
                    }
                    photoItem = nil
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                let data = try? Data(contentsOf: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
                guard let data else {
                    model.message = "Couldn't open that file."
                    return
                }
                Task { await model.loadImageData(data, name: url.deletingPathExtension().lastPathComponent) }
            }
            .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .stlModel,
                          defaultFilename: "\(model.sourceName) painting") { result in
                if case .failure(let error) = result {
                    model.message = "The STL wasn't saved: \(error.localizedDescription)"
                }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { model.message != nil },
                set: { if !$0 { model.message = nil } })) {
                Button("OK") {}
            } message: {
                Text(model.message ?? "")
            }
    }

    // MARK: Layout

    @ViewBuilder private var layout: some View {
        #if os(macOS)
        // A sidebar with the settings and the preview filling the rest. The
        // split view gives the sidebar a definite width, so every row lays
        // out inside it instead of spilling past both edges.
        NavigationSplitView {
            Form { controls }
                .formStyle(.grouped)
                .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 520)
        } detail: {
            previewPane
                .padding()
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 620)
        #else
        NavigationStack {
            Form {
                Section { previewPane.frame(height: 380) }
                controls
            }
            .navigationTitle("RePaint")
        }
        #endif
    }

    private var previewPane: some View {
        VStack(spacing: 12) {
            Picker("View", selection: $showOriginal) {
                Text("Print preview").tag(false)
                Text("Original").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack {
                Color.black
                if let img = showOriginal ? (model.croppedSource ?? model.source) : model.preview {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text("Pick an image to start").foregroundStyle(.white.opacity(0.7))
                }
                if model.isWorking {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(model.sizeSummary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        imageSection
        sizeSection
        filamentSection
        planSection
        exportSection
    }

    private var imageSection: some View {
        Section("Image") {
            HStack(spacing: 20) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                Button { importing = true } label: {
                    Label("Files", systemImage: "folder")
                }
            }
            .buttonStyle(.borderless)
            LabeledContent("Current", value: model.sourceName)
            DisclosureGroup("Crop") {
                cropSlider("Left", \.cropLeft)
                cropSlider("Right", \.cropRight)
                cropSlider("Top", \.cropTop)
                cropSlider("Bottom", \.cropBottom)
            }
        }
    }

    private func cropSlider(_ label: String, _ path: WritableKeyPath<PaintSettings, Double>) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { model.settings[keyPath: path] },
                                  set: { model.settings[keyPath: path] = $0 }),
                   in: 0...0.45)
            Text("\(Int(model.settings[keyPath: path] * 100))%")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var sizeSection: some View {
        Section("Size and layers") {
            Stepper(value: $model.settings.widthMM, in: 30...250, step: 5) {
                LabeledContent("Width", value: "\(Int(model.settings.widthMM)) mm")
            }
            Picker("Layer height", selection: $model.settings.layerHeight) {
                ForEach([0.04, 0.06, 0.08, 0.10, 0.12], id: \.self) { h in
                    Text(String(format: "%.2f mm", h)).tag(h)
                }
            }
            Stepper(value: $model.settings.baseLayers, in: 3...20) {
                LabeledContent("Base", value: "\(model.settings.baseLayers) layers")
            }
            Stepper(value: $model.settings.colorLayers, in: max(8, model.filaments.count + 2)...40) {
                LabeledContent("Color layers", value: "\(model.settings.colorLayers)")
            }
            VStack(alignment: .leading) {
                LabeledContent("Contrast curve", value: String(format: "%.2f", model.settings.curve))
                Slider(value: $model.settings.curve, in: 0.5...1.6)
            }
            Picker("Detail", selection: $model.settings.pixelMM) {
                Text("Fine (0.2 mm)").tag(0.2)
                Text("Standard (0.25 mm)").tag(0.25)
                Text("Fast (0.3 mm)").tag(0.3)
                Text("Draft (0.4 mm)").tag(0.4)
            }
            Toggle("Invert (light areas stay thin)", isOn: $model.settings.invert)
        }
    }

    private var filamentSection: some View {
        Section {
            ForEach($model.filaments) { $f in
                filamentRow($f)
            }
            .onMove { model.moveFilaments(from: $0, to: $1) }
            .onDelete { model.removeFilaments(at: $0) }

            Button { model.addFilament() } label: {
                Label("Add filament", systemImage: "plus")
            }
            .disabled(model.filaments.count >= 6)
            Toggle("Pick swap layers automatically", isOn: $model.autoFit)
        } header: {
            Text("Filaments, bottom to top")
        } footer: {
            FooterText("TD is transmission distance in mm. Brand libraries list it, or print a step wedge to measure your own spool. Changing a start layer turns automatic picking off.")
        }
    }

    private func filamentRow(_ f: Binding<Filament>) -> some View {
        let index = model.filaments.firstIndex { $0.id == f.wrappedValue.id } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ColorPicker("Color", selection: colorBinding(f), supportsOpacity: false)
                    .labelsHidden()
                // The Mac's grouped Form shows a field's title as a row label.
                // These rows have their own layout, so the titles are hidden
                // ("Name" stays as the placeholder).
                TextField("Name", text: f.name)
                    .labelsHidden()
            }
            HStack {
                Text("TD")
                TextField("TD", value: f.td, format: .number.precision(.fractionLength(1...2)))
                    .labelsHidden()
                    .frame(width: 60)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Spacer()
                if index == 0 {
                    Text("Base, layer 1").foregroundStyle(.secondary)
                } else {
                    Stepper(value: Binding(
                        get: { f.wrappedValue.startLayer },
                        set: { model.autoFit = false; f.wrappedValue.startLayer = $0 }),
                            in: 1...model.settings.colorLayers) {
                        Text("Layer \(model.layerNumber(for: index))").monospacedDigit()
                    }
                    .fixedSize()
                }
            }
        }
        .contextMenu {
            Button("Move down (print earlier)") { model.move(f.wrappedValue.id, by: -1) }
            Button("Move up (print later)") { model.move(f.wrappedValue.id, by: 1) }
            Button("Delete", role: .destructive) {
                model.removeFilaments(at: IndexSet(integer: index))
            }
        }
    }

    private func colorBinding(_ f: Binding<Filament>) -> Binding<CGColor> {
        Binding(
            get: { CGColor(srgbRed: f.wrappedValue.r, green: f.wrappedValue.g, blue: f.wrappedValue.b, alpha: 1) },
            set: { color in
                let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           intent: .defaultIntent, options: nil) ?? color
                let c = srgb.components ?? [0, 0, 0]
                if c.count >= 3 {
                    f.wrappedValue.r = c[0]; f.wrappedValue.g = c[1]; f.wrappedValue.b = c[2]
                } else if let gray = c.first {
                    f.wrappedValue.r = gray; f.wrappedValue.g = gray; f.wrappedValue.b = gray
                }
            })
    }

    private var planSection: some View {
        Section {
            ForEach(Array(model.filaments.enumerated()), id: \.element.id) { i, f in
                HStack {
                    Circle()
                        .fill(Color(cgColor: CGColor(srgbRed: f.r, green: f.g, blue: f.b, alpha: 1)))
                        .overlay(Circle().stroke(.secondary.opacity(0.4)))
                        .frame(width: 16, height: 16)
                    Text(f.name)
                    Spacer()
                    if i == 0 {
                        Text("Layer 1").foregroundStyle(.secondary)
                    } else {
                        let layer = model.layerNumber(for: i)
                        Text("Layer \(layer) · Z \(model.z(forLayer: layer))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Top", value: "Layer \(model.topLayer) · Z \(model.z(forLayer: model.topLayer))")
                .monospacedDigit()
            ShareLink(item: model.planText) {
                Label("Share print plan", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Print plan")
        } footer: {
            FooterText("In Bambu Studio, set layer height and first layer height to the same value. Slice, drag the layer slider to each layer above, right-click the handle, choose Change filament, and pick that AMS slot.")
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                Task {
                    if let data = await model.makeSTL() {
                        exportDoc = STLDocument(data: data)
                        exporting = true
                    }
                }
            } label: {
                Label("Export STL", systemImage: "cube")
            }
            .disabled(model.grid == nil || model.isWorking)
        } footer: {
            FooterText("Print it flat with the base on the plate. The picture is viewed from the top, where thin areas let the darker layers show through.")
        }
    }
}

#Preview {
    ContentView()
}

/// Section footer text that wraps. On the Mac a long single-line Text keeps
/// its full one-line width, which made the whole settings column wider than
/// the window and cut off both edges.
private struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
