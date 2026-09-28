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
                PromptCard(title: "Claude Needs a Decision", symbol: "questionmark.circle") {
                    Text(d.dialogKind).scaledFont(.callout, design: .monospaced)
                    Text(d.payload.pretty).scaledFont(.caption, design: .monospaced).lineLimit(10)
                    HStack {
                        Spacer()
                        Button("Dismiss") { thread.answer(pending, with: ["behavior": "cancelled"]) }
                    }
                }
            case .unknown(let method, _):
                PromptCard(title: "Unsupported Request", symbol: "questionmark.circle") {
                    Text(method).scaledFont(.callout, design: .monospaced)
                }
            }
        }
    }
}

/// A request that waits on an answer: a heading, what's asked, and the answers. VoiceOver goes to
/// its heading when it arrives, since nothing else can happen in the chat until it's answered.
struct PromptCard<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .orange
    @ViewBuilder var content: Content
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).scaledFont(.headline).foregroundStyle(tint)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onAppear { headingFocused = true }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(tint.opacity(0.12)), in: .rect(cornerRadius: Layout.cardCornerRadius))
        // Comes out of the glass around it, and goes back into it, as it's asked and answered.
        .glassEffectTransition(.materialize)
    }
}

struct PermissionPrompt: View {
    @Environment(\.composerHasFocus) private var composerHasFocus
    /// Return answers the card, except while the message field has focus: a default button is the
    /// whole window's, and Return in a draft would otherwise press it.
    private var defaultKey: KeyboardShortcut? { composerHasFocus ? nil : .defaultAction }
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
                TextField("What to Do Instead (Optional)", text: $denyMessage, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(deny)
            }
            HStack {
                // Exactly one default button, so Return always does something.
                if !showingDeny {
                    Button("Deny…") { showingDeny = true }
                        .keyboardShortcut(denyIsDefault ? defaultKey : nil)
                } else {
                    Button("Deny", action: deny).keyboardShortcut(defaultKey)
                }
                Spacer()
                if params.suppressAlwaysAllowRule != true {
                    // Where each rule is written, as the item's subtitle.
                    Menu("Always Allow") {
                        Button("For This Session") { respond(["decision": "allow", "scope": "session"]) }
                        Button { respond(["decision": "allow", "scope": "project"]) } label: {
                            Text("For This Project")
                            Text("Shared, in .claude/settings.json")
                        }
                        Button { respond(["decision": "allow", "scope": "local"]) } label: {
                            Text("For This Project, Just Me")
                            Text("In .claude/settings.local.json")
                        }
                        Button { respond(["decision": "allow", "scope": "user"]) } label: {
                            Text("Everywhere")
                            Text("In your user settings")
                        }
                    }
                    // Its title whole; the row gives way around it.
                    .fixedSize(horizontal: true, vertical: false)
                }
                // Prominence follows the default key (two branches: the styles are different types).
                if allowIsDefault {
                    Button("Allow") { respond(["decision": "allow", "scope": "once"]) }
                        .keyboardShortcut(defaultKey)
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
    @Environment(\.composerHasFocus) private var composerHasFocus
    /// Return answers the card, except while the message field has focus: a default button is the
    /// whole window's, and Return in a draft would otherwise press it.
    private var defaultKey: KeyboardShortcut? { composerHasFocus ? nil : .defaultAction }
    let params: QuestionRequestParams
    let respond: (JSONValue) -> Void
    @State private var selections: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        PromptCard(title: "Claude Has a Question", symbol: "questionmark.bubble", tint: .blue) {
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
                Button("Submit", action: submit).buttonStyle(.borderedProminent).keyboardShortcut(defaultKey).disabled(!complete)
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
    @Environment(\.composerHasFocus) private var composerHasFocus
    /// Return answers the card, except while the message field has focus: a default button is the
    /// whole window's, and Return in a draft would otherwise press it.
    private var defaultKey: KeyboardShortcut? { composerHasFocus ? nil : .defaultAction }
    let params: PlanApproveParams
    let respond: (JSONValue) -> Void
    @State private var feedback = ""

    var body: some View {
        PromptCard(title: "Ready to Proceed with This Plan?", symbol: "list.bullet.clipboard", tint: .purple) {
            ScrollView { plan }
                .frame(maxHeight: 280)
            TextField("Feedback (Optional)", text: $feedback, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            // In a row while they fit; stacked at the trailing edge in a narrow window or at a
            // bigger text size, rather than truncated.
            ViewThatFits(in: .horizontal) {
                HStack {
                    keepPlanning
                    Spacer()
                    approve
                }
                VStack(alignment: .trailing) {
                    approve
                    keepPlanning
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var plan: some View {
        MarkdownView(text: params.plan).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keepPlanning: some View {
        Button("Keep Planning") { respond(["decision": "reject", "feedback": .string(feedback)]) }
    }

    @ViewBuilder private var approve: some View {
        Button("Approve, Ask Before Edits") { respond(["decision": "approve", "permissionMode": "default"]) }
        Button("Approve, Accept Edits") { respond(["decision": "approve", "permissionMode": "acceptEdits"]) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(defaultKey)
    }
}

struct ElicitationPrompt: View {
    @Environment(\.composerHasFocus) private var composerHasFocus
    /// Return answers the card, except while the message field has focus: a default button is the
    /// whole window's, and Return in a draft would otherwise press it.
    private var defaultKey: KeyboardShortcut? { composerHasFocus ? nil : .defaultAction }
    let params: ElicitationRequestParams
    let respond: (JSONValue) -> Void
    @State private var values: [String: String] = [:]
    /// Number and integer fields, as numbers: typed in the reader's locale, sent as JSON numbers.
    @State private var numbers: [String: Double] = [:]

    private var fields: [(key: String, schema: JSONValue)] {
        (params.requestedSchema?["properties"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        PromptCard(title: "\(params.serverName) Needs Input", symbol: "puzzlepiece.extension", tint: .teal) {
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
                        case "number": content[f.key] = numbers[f.key].map { .number($0) }
                        case "integer": content[f.key] = numbers[f.key].map { .number($0.rounded()) }
                        case "boolean": content[f.key] = .bool(["true", "yes", "1"].contains(v.lowercased()))
                        default: content[f.key] = .string(v)
                        }
                    }
                    respond(["action": "accept", "content": .object(content)])
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(defaultKey)
                .disabled(!complete)
            }
        }
        // Seeded so `complete` can tell an untouched required field from one left off.
        .onAppear {
            for f in fields where values[f.key] == nil {
                values[f.key] = f.schema.string("type") == "boolean" ? "false" : (f.schema["default"]?.stringValue ?? "")
                if numbers[f.key] == nil { numbers[f.key] = f.schema["default"]?.doubleValue }
            }
        }
    }

    /// Fields the schema marks required.
    private var required: Set<String> {
        Set((params.requestedSchema?["required"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    private var complete: Bool {
        required.allSatisfy { key in
            let type = fields.first { $0.key == key }?.schema.string("type")
            if type == "number" || type == "integer" { return numbers[key] != nil }
            return !values[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
            TextField(title, value: Binding(get: { numbers[f.key] }, set: { numbers[f.key] = $0 }),
                      format: .number, prompt: Text("Number"))
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

extension EnvironmentValues {
    /// Whether the chat's message field has focus, for the prompt cards over it.
    @Entry var composerHasFocus = false
}
