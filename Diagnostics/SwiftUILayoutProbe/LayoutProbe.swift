import SwiftUI

@main
struct LayoutProbe: App {
    var body: some Scene {
        WindowGroup("Layout Probe") {
            ProbeView(mode: ProcessInfo.processInfo.environment["SUNDOWN_PROBE_MODE"] ?? "plain")
        }
        .defaultSize(width: 1000, height: 740)
        .windowResizability(.contentMinSize)
    }
}

struct ProbeView: View {
    let mode: String
    @State private var showInspector = false
    @State private var input = ""
    var body: some View {
        Group {
            if mode == "plain" {
                content
            } else {
                NavigationSplitView {
                    List { Text("Fixture Chat") }
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
                } detail: {
                    content
                        .navigationTitle("Fixture Chat")
                        .toolbar {
                            if mode != "split" {
                                ToolbarItem(placement: .navigation) { Button("New Chat", systemImage: "square.and.pencil") {} }
                                ToolbarItem(placement: .primaryAction) {
                                    ControlGroup {
                                        Menu("Model", systemImage: "sparkle") { Button("Default") {} }
                                        Menu("Effort", systemImage: "a.circle") { Button("Automatic") {} }
                                        Menu("Permissions", systemImage: "hand.raised") { Button("Ask") {} }
                                    }.controlGroupStyle(.navigation)
                                }
                            }
                        }
                }
                .inspector(isPresented: $showInspector) { Text("Inspector").inspectorColumnWidth(min: 260, ideal: 300, max: 420) }
            }
        }
        .frame(minWidth: 800, minHeight: 400)
    }
    var content: some View {
        VStack {
            Text("Section 29: tightening the renderer")
            Spacer()
            if mode == "composer" {
                TextField("Ask Claude…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding()
                    .glassEffect(in: .rect(cornerRadius: 20))
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
