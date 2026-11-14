import SceneKit
import SwiftUI
import UniformTypeIdentifiers

struct SlicerView: View {
    /// Owned by RootView, so the Painter tab can hand a painting over.
    let model: SlicerModel
    @State private var isPickingFile = false
    @State private var showingLayers = false
    @State private var documentToSave: GCodeDocument?
    @State private var isSaving = false
    @State private var showingSettings = false

    /// iOS knows ".stl" as a type; `.data` is only a fallback so the picker
    /// still opens if a future system forgets it.
    private let stlType = UTType(filenameExtension: "stl") ?? .data

    var body: some View {
        NavigationStack {
            Group {
                if let scene = model.scene, let mesh = model.mesh {
                    VStack(spacing: 0) {
                        if let result = model.result {
                            Picker("View", selection: $showingLayers) {
                                Text("Model").tag(false)
                                Text("Layers").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)
                            .padding(.vertical, 8)

                            if showingLayers {
                                LayerPreview(result: result, mesh: mesh)
                            } else {
                                modelView(scene)
                            }
                        } else {
                            modelView(scene)
                        }
                        bottomBar(mesh)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No model", systemImage: "cube.transparent")
                    } description: {
                        Text("Open an STL file to see it on the print bed.")
                    } actions: {
                        Button("Open STL") { isPickingFile = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .overlay {
                if model.isLoading {
                    ProgressView("Reading model…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Slicer")
            // A large title takes a fifth of an iPhone screen away from the
            // model. (The Mac has no such setting.)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open STL", systemImage: "folder") { isPickingFile = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Slice settings", systemImage: "slider.horizontal.3") { showingSettings = true }
                }
            }
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [stlType]) { result in
            switch result {
            case .success(let url):
                Task { await model.open(url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingSettings) { SlicerSettingsView(model: model) }
        // Layers vanish when a setting changes; don't sit on an empty tab.
        .onChange(of: model.result == nil) { _, gone in if gone { showingLayers = false } }
        // A new model has no layers yet, so go back to the 3D view.
        .onChange(of: model.loadCount) { showingLayers = false }
        .fileExporter(isPresented: $isSaving, document: documentToSave,
                      contentType: GCodeDocument.gcodeType,
                      defaultFilename: model.gcodeFileName) { result in
            documentToSave = nil
            if case .failure(let error) = result {
                model.errorMessage = error.localizedDescription
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func modelView(_ scene: SCNScene) -> some View {
        SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
    }

    /// One line saying what the next slice will do, so the choices made in
    /// the settings sheet are visible without opening it.
    private var settingsSummary: String {
        let s = model.settings
        let swaps = s.sortedSwaps.count
        return "Supports: \(s.supportMode.title.lowercased())"
            + (swaps == 0 ? "" : " · \(swaps) filament swap\(swaps == 1 ? "" : "s")")
    }

    @ViewBuilder
    private func bottomBar(_ mesh: Mesh) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ModelInfo(name: model.fileName ?? "", mesh: mesh, bed: model.bed)

            if model.isSlicing {
                ProgressView(value: model.sliceProgress) { Text("Slicing…") }
            } else if let result = model.result {
                SliceSummary(result: result)
                HStack {
                    Button("Save G-code", systemImage: "square.and.arrow.down") {
                        Task {
                            documentToSave = await model.gcodeDocument()
                            isSaving = documentToSave != nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Slice again") { Task { await model.slice() } }
                        .buttonStyle(.bordered)
                }
            } else {
                Text(settingsSummary).font(.subheadline).foregroundStyle(.secondary)
                Button("Slice", systemImage: "square.3.layers.3d") {
                    Task {
                        await model.slice()
                        showingLayers = model.result != nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.bed.fits(mesh))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.bar)
    }
}

/// File name, triangle count and size, plus a warning when the model is
/// bigger than the printer.
private struct ModelInfo: View {
    let name: String
    let mesh: Mesh
    let bed: Bed

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline).lineLimit(1)
            Text("\(mesh.triangleCount.formatted()) triangles · \(sizeText) mm")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !bed.fits(mesh) {
                Label("Too big for the \(Int(bed.width)) × \(Int(bed.depth)) × \(Int(bed.height)) mm build volume",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var sizeText: String {
        let s = mesh.size
        return [s.x, s.y, s.z]
            .map { $0.formatted(.number.precision(.fractionLength(1))) }
            .joined(separator: " × ")
    }
}

/// What the print will cost, and the things the user must know before
/// trusting the file.
private struct SliceSummary: View {
    let result: SliceResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(result.layers.count) layers · \(grams) g · \(metres) m · at least \(time)")
                .font(.subheadline)
            if result.layersWithGaps > 0 {
                warning("\(result.layersWithGaps) of the layers have a broken outline (the model has holes in its surface). Parts may be missing.")
            }
            if !result.settings.sortedSwaps.isEmpty {
                warning("The filament swap commands are untested and don't flush the old colour out.")
            }
            warning("The printer start-up G-code is untested. Don't print this file unattended.")
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            // Let long warnings wrap instead of being cut off.
            .fixedSize(horizontal: false, vertical: true)
    }

    private var grams: String { result.filamentGrams.formatted(.number.precision(.fractionLength(1))) }
    private var metres: String { (result.filamentMM / 1000).formatted(.number.precision(.fractionLength(2))) }
    private var time: String {
        Duration.seconds(result.roughSeconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}
