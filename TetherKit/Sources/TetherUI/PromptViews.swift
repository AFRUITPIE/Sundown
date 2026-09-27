import SwiftUI
import TetherKit
import TetherProtocol

/// Inline card for a pending server request (permission, question, plan, elicitation, dialog).
struct PendingRequestView: View {
    let pending: PendingRequest
    let thread: ThreadModel

    var body: some View {
        Group {
            switch pending.request {
            case .permissionRequest(let p): PermissionPrompt(params: p) { thread.answer(pending, with: $0) }
            case .questionRequest(let q): QuestionPrompt(params: q) { thread.answer(pending, with: $0) }
            case .planApprove(let p): PlanPrompt(params: p) { thread.answer(pending, with: $0) }
            case .elicitationRequest(let e): ElicitationPrompt(params: e) { thread.answer(pending, with: $0) }
            case .dialogRequest(let d):
                PromptCard(title: "Claude needs a decision", symbol: "questionmark.circle") {
                    Text(d.dialogKind).scaledFont(.callout, design: .monospaced)
                    Text(d.payload.pretty).scaledFont(.caption, design: .monospaced).lineLimit(10)
                    HStack {
                        Spacer()
                        Button("Dismiss") { thread.answer(pending, with: ["behavior": "cancelled"]) }
                    }
                }
            case .unknown(let method, _):
                PromptCard(title: "Unsupported request", symbol: "questionmark.circle") {
                    Text(method).scaledFont(.callout, design: .monospaced)
                }
            }
        }
    }
}

struct PromptCard<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .orange
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).scaledFont(.headline).foregroundStyle(tint)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(tint.opacity(0.12)), in: .rect(cornerRadius: 24))
    }
}

struct PermissionPrompt: View {
    let params: PermissionRequestParams
    let respond: (JSONValue) -> Void
    @State private var denyMessage = ""
    @State private var showingDeny = false

    private var headline: String {
        params.title ?? "Allow \(params.displayName ?? params.toolName)?"
    }

    var body: some View {
        PromptCard(title: headline, symbol: "hand.raised") {
            if let d = params.description { Text(d).scaledFont(.callout).foregroundStyle(.secondary) }
            detail
            if let r = params.decisionReason { Text(r).scaledFont(.caption).foregroundStyle(.secondary) }
            if showingDeny {
                TextField("Tell Claude what to do instead (optional)", text: $denyMessage, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(deny)
            }
            HStack {
                // Exactly one default button, so Return always does something.
                if !showingDeny {
                    Button("Deny…") { showingDeny = true }
                        .keyboardShortcut(denyIsDefault ? .defaultAction : nil)
                } else {
                    Button("Deny", action: deny).keyboardShortcut(.defaultAction)
                }
                Spacer()
                if params.suppressAlwaysAllowRule != true {
                    Menu("Always allow") {
                        Button("For this session") { respond(["decision": "allow", "scope": "session"]) }
                        Button("For this project (shared)") { respond(["decision": "allow", "scope": "project"]) }
                        Button("For this project (just me)") { respond(["decision": "allow", "scope": "local"]) }
                        Button("Everywhere (user settings)") { respond(["decision": "allow", "scope": "user"]) }
                    }
                    .fixedSize()
                }
                // Prominence follows the default key (two branches: the styles are different types).
                if allowIsDefault {
                    Button("Allow") { respond(["decision": "allow", "scope": "once"]) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Allow") { respond(["decision": "allow", "scope": "once"]) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    /// The server can make the safe answer the default; with the deny field open, Return commits it.
    private var denyIsDefault: Bool { params.defaultToNo == true || showingDeny }
    private var allowIsDefault: Bool { !denyIsDefault }

    @ViewBuilder private var detail: some View {
        let input = params.input
        if let cmd = input.string("command") {
            CodeBlock(code: "$ " + cmd, language: "bash")
        } else if let old = input.string("old_string"), let new = input.string("new_string") {
            Text((input.string("file_path") ?? "").abbreviatingHome).scaledFont(.caption, design: .monospaced)
            DiffView(old: old, new: new, lineLimit: 10)
        } else if let content = input.string("content"), let path = input.string("file_path") {
            Text(path.abbreviatingHome).scaledFont(.caption, design: .monospaced)
            CodeBlock(code: content, language: path.lastPathComponent, lineLimit: 10)
        } else if input.objectValue?.isEmpty == false {
            CodeBlock(code: input.pretty, language: params.toolName, lineLimit: 10)
        }
    }

    private func deny() {
        respond(["decision": "deny", "message": .string(denyMessage.isEmpty ? "The user denied this action." : denyMessage)])
    }
}

struct QuestionPrompt: View {
    let params: QuestionRequestParams
    let respond: (JSONValue) -> Void
    @State private var selections: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        PromptCard(title: "Claude has a question", symbol: "questionmark.bubble", tint: .blue) {
            ForEach(params.questions, id: \.question) { q in
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.question).scaledFont(.body, weight: .medium)
                    if q.multiSelect {
                        ForEach(q.options, id: \.label) { o in
                            Toggle(isOn: Binding(
                                get: { selections[q.question, default: []].contains(o.label) },
                                set: { on in
                                    var s = selections[q.question, default: []]
                                    if on { s.insert(o.label) } else { s.remove(o.label) }
                                    selections[q.question] = s
                                })) {
                                Text(o.label)
                                Text(o.description)
                            }
                            .toggleStyle(.checkbox)
                        }
                    } else {
                        // For a single choice, picking an option clears a typed answer.
                        Picker(q.header, selection: Binding(
                            get: { selections[q.question, default: []].first ?? "" },
                            set: {
                                selections[q.question] = [$0]
                                other[q.question] = ""
                            })) {
                            ForEach(q.options, id: \.label) { o in
                                Text(o.label).tag(o.label)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden() // the question is already the heading above
                        let chosen = q.options.first { selections[q.question, default: []].contains($0.label) }
                        if let chosen { Text(chosen.description).scaledFont(.caption).foregroundStyle(.secondary) }
                    }
                    TextField(q.multiSelect ? "Something else (adds to the choices above)" : "Something else",
                              text: Binding(get: { other[q.question, default: ""] },
                                            set: { text in
                                                other[q.question] = text
                                                if !q.multiSelect, !text.isEmpty { selections[q.question] = [] }
                                            }))
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.bottom, 4)
            }
            HStack {
                Button("Skip") { respond(["decision": "decline"]) }
                Spacer()
                Button("Submit", action: submit).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!complete)
            }
        }
    }

    private var complete: Bool {
        params.questions.allSatisfy {
            !selections[$0.question, default: []].isEmpty
                || !other[$0.question, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submit() {
        var answers: [String: JSONValue] = [:]
        for q in params.questions {
            let custom = other[q.question, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = q.options.map(\.label).filter { selections[q.question, default: []].contains($0) }
            // A typed answer replaces a single choice and joins a multi-select, matching the UI above.
            let parts = custom.isEmpty ? chosen : (q.multiSelect ? chosen + [custom] : [custom])
            answers[q.question] = .string(parts.joined(separator: ", "))
        }
        respond(["decision": "answer", "answers": .object(answers)])
    }
}

struct PlanPrompt: View {
    let params: PlanApproveParams
    let respond: (JSONValue) -> Void
    @State private var feedback = ""

    var body: some View {
        PromptCard(title: "Ready to proceed with this plan?", symbol: "list.bullet.clipboard", tint: .purple) {
            ScrollView {
                MarkdownView(text: params.plan).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            TextField("Feedback to keep planning (optional)", text: $feedback, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Keep planning") { respond(["decision": "reject", "feedback": .string(feedback)]) }
                Spacer()
                Button("Approve, ask before edits") { respond(["decision": "approve", "permissionMode": "default"]) }
                Button("Approve, auto-accept edits") { respond(["decision": "approve", "permissionMode": "acceptEdits"]) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct ElicitationPrompt: View {
    let params: ElicitationRequestParams
    let respond: (JSONValue) -> Void
    @State private var values: [String: String] = [:]

    private var fields: [(key: String, schema: JSONValue)] {
        (params.requestedSchema?["properties"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        PromptCard(title: "\(params.serverName) needs input", symbol: "puzzlepiece.extension", tint: .teal) {
            Text(params.message).scaledFont(.callout)
            if let urlString = params.url, let url = URL(string: urlString) {
                Link(urlString, destination: url).scaledFont(.callout)
            }
            ForEach(fields, id: \.key) { f in
                field(f)
                if let d = f.schema.string("description") {
                    Text(d).scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Decline") { respond(["action": "decline"]) }
                Spacer()
                Button("Continue") {
                    var content: [String: JSONValue] = [:]
                    for f in fields {
                        let v = values[f.key, default: ""]
                        switch f.schema.string("type") {
                        case "number", "integer": content[f.key] = Double(v).map { .number($0) } ?? .string(v)
                        case "boolean": content[f.key] = .bool(["true", "yes", "1"].contains(v.lowercased()))
                        default: content[f.key] = .string(v)
                        }
                    }
                    respond(["action": "accept", "content": .object(content)])
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!complete)
            }
        }
        // Seeded so `complete` can tell an untouched required field from one left off.
        .onAppear {
            for f in fields where values[f.key] == nil {
                values[f.key] = f.schema.string("type") == "boolean" ? "false" : (f.schema["default"]?.stringValue ?? "")
            }
        }
    }

    /// Fields the schema marks required.
    private var required: Set<String> {
        Set((params.requestedSchema?["required"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    private var complete: Bool {
        required.allSatisfy { !values[$0, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The control that matches the declared type.
    @ViewBuilder private func field(_ f: (key: String, schema: JSONValue)) -> some View {
        let title = f.schema.string("title") ?? f.key
        let text = Binding(get: { values[f.key, default: ""] }, set: { values[f.key] = $0 })
        switch f.schema.string("type") {
        case "boolean":
            Toggle(title, isOn: Binding(get: { values[f.key] == "true" },
                                        set: { values[f.key] = $0 ? "true" : "false" }))
        case "number", "integer":
            TextField(title, text: text, prompt: Text("Number"))
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
        default:
            if let options = f.schema["enum"]?.arrayValue, !options.isEmpty {
                Picker(title, selection: text) {
                    ForEach(options.compactMap(\.stringValue), id: \.self) { Text($0).tag($0) }
                }
            } else {
                TextField(title, text: text).textFieldStyle(.roundedBorder)
            }
        }
    }
}

#if DEBUG
// Pulls typed params out of the `PendingRequest` samples for the previews.
private func params(_ request: ServerRequest) -> PermissionRequestParams {
    guard case .permissionRequest(let p) = request else { fatalError("not a permission request") }
    return p
}
private func params(_ request: ServerRequest) -> QuestionRequestParams {
    guard case .questionRequest(let p) = request else { fatalError("not a question request") }
    return p
}
private func params(_ request: ServerRequest) -> PlanApproveParams {
    guard case .planApprove(let p) = request else { fatalError("not a plan request") }
    return p
}
private func params(_ request: ServerRequest) -> ElicitationRequestParams {
    guard case .elicitationRequest(let p) = request else { fatalError("not an elicitation request") }
    return p
}

#Preview("Permission request") {
    PermissionPrompt(params: params(PendingRequest.samplePermission().request), respond: { _ in })
        .padding(20)
        .frame(width: 560)
}

#Preview("Permission request (edit)") {
    PermissionPrompt(params: params(PendingRequest.samplePermission(
        toolName: "Edit", displayName: "Edit",
        description: "Edit TetherKit/Sources/TetherKit/ThreadModel.swift",
        input: ["file_path": "/Users/hayden/Code/tether-app/TetherKit/Sources/TetherKit/ThreadModel.swift",
                "old_string": "    public private(set) var lastSeq = 0",
                "new_string": "    public private(set) var lastSeq = 0\n    public private(set) var isPreview = false"],
        decisionReason: nil
    ).request), respond: { _ in })
        .padding(20)
        .frame(width: 560)
}

#Preview("Question") {
    QuestionPrompt(params: params(PendingRequest.sampleQuestion().request), respond: { _ in })
        .padding(20)
        .frame(width: 560)
}

#Preview("Plan approval") {
    PlanPrompt(params: params(PendingRequest.samplePlan().request), respond: { _ in })
        .padding(20)
        .frame(width: 560)
}

#Preview("Elicitation") {
    ElicitationPrompt(params: params(PendingRequest.sampleElicitation().request), respond: { _ in })
        .padding(20)
        .frame(width: 560)
}

#Preview("Dialog / unknown (PendingRequestView)") {
    VStack(spacing: 16) {
        PendingRequestView(pending: .sampleDialog(), thread: .sampleIdleChat())
        PendingRequestView(pending: .sampleUnknown(), thread: .sampleIdleChat())
    }
    .padding(20)
    .frame(width: 560)
}

#endif
