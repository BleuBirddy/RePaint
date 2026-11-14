import SwiftUI

/// The two halves of RePaint side by side: the Slicer turns any STL into
/// G-code, the Painter turns a picture into an STL. The Painter can pass its
/// result straight to the Slicer, so a painting never has to leave the app.
struct RootView: View {
    private enum Tab { case slicer, painter }

    @State private var tab = Tab.slicer
    /// Lives here, above both tabs, so the Painter can load a model into it.
    @State private var slicer = SlicerModel()

    var body: some View {
        TabView(selection: $tab) {
            SlicerView(model: slicer)
                .tabItem { Label("Slicer", systemImage: "square.3.layers.3d") }
                .tag(Tab.slicer)

            PainterView { painting in
                tab = .slicer
                Task { await slicer.openPainting(painting) }
            }
            .tabItem { Label("Painter", systemImage: "paintbrush") }
            .tag(Tab.painter)
        }
    }
}
