import SwiftUI
import SundownKit

/// Adds a host Sundown reaches over `ssh`. Aliases from ~/.ssh/config come first because that is
/// where a destination that already works is written down.
struct AddSSHHostSheet: View {
    let add: (HostConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var name = ""
    @State private var aliases: [String] = []

    var body: some View {
        Form {
            Section {
                TextField("Destination", text: $destination, prompt: Text("Alias or user@host"))
                    .autocorrectionDisabled()
                    // The ~/.ssh/config aliases that match what's typed, as the field's suggestions.
                    .textInputSuggestions(suggestions, id: \.self) { alias in
                        Text(alias).textInputCompletion(alias)
                    }
                    .accessibilityIdentifier("host.destination")
                TextField("Name", text: $name, prompt: Text(destination.isEmpty ? "Optional" : destination))
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let trimmed = destination.trimmingCharacters(in: .whitespaces)
                    let title = name.trimmingCharacters(in: .whitespaces)
                    add(HostConfig(name: title.isEmpty ? trimmed : title, kind: .ssh(destination: trimmed)))
                    dismiss()
                }
                .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        // As tall as its two rows, at a form sheet's width.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .task {
            aliases = await Task.detached(priority: .userInitiated) {
                SSHConfig.hostAliases()
            }.value
        }
    }

    /// Every alias while the field is empty; then those containing what's typed.
    private var suggestions: [String] {
        let typed = destination.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? aliases : aliases.filter { $0.localizedCaseInsensitiveContains(typed) && $0 != typed }
    }
}

#if DEBUG
#Preview("Add SSH Host") {
    AddSSHHostSheet { _ in }
}
#endif
