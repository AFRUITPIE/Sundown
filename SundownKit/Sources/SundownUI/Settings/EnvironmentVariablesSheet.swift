import SwiftUI
import SundownKit

/// One environment override, while it is being edited. Identity is the row's, not the name's, so
/// a half-typed name doesn't reorder the table under the cursor.
struct EnvVariable: Identifiable, Hashable {
    let id = UUID()
    var name: String = ""
    var value: String = ""

    /// The stored environment as rows, in the order the table shows them.
    static func rows(_ environment: [String: String]) -> [EnvVariable] {
        environment.sorted { $0.key < $1.key }.map { EnvVariable(name: $0.key, value: $0.value) }
    }

    /// Rows back to what gets sent on connect: trimmed, unnamed rows dropped, last name wins.
    static func environment(_ rows: [EnvVariable]) -> [String: String] {
        let pairs = rows
            .map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) }
            .filter { !$0.0.isEmpty }
        return Dictionary(pairs, uniquingKeysWith: { $1 })
    }
}

/// The host's environment overrides, edited as a table. A sheet rather than rows in the form:
/// most hosts have none, and the ones that do have a handful of long values.
struct EnvironmentVariablesSheet: View {
    @State private var rows: [EnvVariable]
    @State private var selection: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss
    private let apply: ([String: String]) -> Void

    init(environment: [String: String], apply: @escaping ([String: String]) -> Void) {
        _rows = State(initialValue: EnvVariable.rows(environment))
        self.apply = apply
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Name") { row in
                    TextField("", text: binding(row.id, \.name))
                        .font(.body.monospaced())
                        .accessibilityLabel("Name")
                }
                TableColumn("Value") { row in
                    TextField("", text: binding(row.id, \.value))
                        .font(.body.monospaced())
                        .accessibilityLabel("Value")
                }
            }
            .tableStyle(.inset)
            // Names and values are code, not prose.
            .autocorrectionDisabled()
            .alternatingRowBackgrounds()
            Divider()
            HStack(spacing: 0) {
                Button("Add Variable", systemImage: "plus") { addRow() }
                Button("Remove Variable", systemImage: "minus") { removeSelected() }
                    .disabled(selection.isEmpty)
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    apply(EnvVariable.environment(rows))
                    dismiss()
                }
            }
        }
        // A form sheet's size; the table takes what the buttons leave.
        .presentationSizing(.form)
    }

    private func addRow() {
        let row = EnvVariable()
        rows.append(row)
        selection = [row.id]
    }

    private func removeSelected() {
        rows.removeAll { selection.contains($0.id) }
        selection = []
    }

    private func binding(_ id: UUID, _ field: WritableKeyPath<EnvVariable, String>) -> Binding<String> {
        Binding(
            get: { rows.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { new in
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
                rows[index][keyPath: field] = new
            }
        )
    }
}

#if DEBUG
#Preview("Environment Variables") {
    EnvironmentVariablesSheet(environment: ["AWS_PROFILE": "sundown", "AWS_REGION": "us-west-2"]) { _ in }
}

#Preview("Environment Variables (empty)") {
    EnvironmentVariablesSheet(environment: [:]) { _ in }
}
#endif
