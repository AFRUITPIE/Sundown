import SwiftUI
import TetherKit

/// Adds a host Tether reaches over `ssh`. Aliases from ~/.ssh/config come first because that is
/// where a destination that already works is written down.
struct AddSSHHostSheet: View {
    let add: (HostConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var name = ""
    @State private var aliases: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if !aliases.isEmpty {
                        Picker("SSH Config", selection: $destination) {
                            Text("Choose…").tag("")
                            ForEach(aliases, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("Destination", text: $destination, prompt: Text("Alias or user@host"))
                        .accessibilityIdentifier("host.destination")
                    TextField("Name", text: $name, prompt: Text(destination.isEmpty ? "Optional" : destination))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    let trimmed = destination.trimmingCharacters(in: .whitespaces)
                    let title = name.trimmingCharacters(in: .whitespaces)
                    add(HostConfig(name: title.isEmpty ? trimmed : title, kind: .ssh(destination: trimmed)))
                    dismiss()
                }
                .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        // Three rows at most; a grouped Form on its own would take the whole screen.
        .frame(width: 440, height: 230)
        .task {
            aliases = await Task.detached(priority: .userInitiated) {
                SSHConfig.hostAliases()
            }.value
        }
    }
}

#if DEBUG
#Preview("Add SSH Host") {
    AddSSHHostSheet { _ in }
}
#endif
