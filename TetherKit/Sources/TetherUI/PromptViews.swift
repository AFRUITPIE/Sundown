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
                    Text(d.dialogKind).font(.callout.monospaced())
                    Text(d.payload.pretty).font(.caption.monospaced()).lineLimit(10)
                    HStack {
                        Spacer()
                        Button("Dismiss") { thread.answer(pending, with: ["behavior": "cancelled"]) }
                    }
                }
            case .unknown(let method, _):
                PromptCard(title: "Unsupported request", symbol: "questionmark.circle") {
                    Text(method).font(.callout.monospaced())
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
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint)
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
            if let d = params.description { Text(d).font(.callout).foregroundStyle(.secondary) }
            detail
            if let r = params.decisionReason { Text(r).font(.caption).foregroundStyle(.secondary) }
            if showingDeny {
                TextField("Tell Claude what to do instead (optional)", text: $denyMessage, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(deny)
            }
            HStack {
                if !showingDeny {
                    Button("Deny…") { showingDeny = true }
                } else {
                    Button("Deny", role: .destructive, action: deny).keyboardShortcut(.return, modifiers: [.command, .shift])
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
                Button("Allow") { respond(["decision": "allow", "scope": "once"]) }
                    .keyboardShortcut(params.defaultToNo == true ? nil : .defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        let input = params.input
        if let cmd = input.string("command") {
            CodeBlock(code: "$ " + cmd, language: "bash")
        } else if let old = input.string("old_string"), let new = input.string("new_string") {
            Text((input.string("file_path") ?? "").abbreviatingHome).font(.caption.monospaced())
            DiffView(old: old, new: new, lineLimit: 10)
        } else if let content = input.string("content"), let path = input.string("file_path") {
            Text(path.abbreviatingHome).font(.caption.monospaced())
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
                    Text(q.question).font(.body.weight(.medium))
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
                        Picker(q.header, selection: Binding(
                            get: { selections[q.question, default: []].first ?? "" },
                            set: { selections[q.question] = [$0] })) {
                            ForEach(q.options, id: \.label) { o in
                                Text(o.label).tag(o.label)
                                    .help(o.description)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        let chosen = q.options.first { selections[q.question, default: []].contains($0.label) }
                        if let chosen { Text(chosen.description).font(.caption).foregroundStyle(.secondary) }
                    }
                    TextField("Other", text: Binding(get: { other[q.question, default: ""] }, set: { other[q.question] = $0 }))
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
        params.questions.allSatisfy { !selections[$0.question, default: []].isEmpty || !other[$0.question, default: ""].isEmpty }
    }

    private func submit() {
        var answers: [String: JSONValue] = [:]
        for q in params.questions {
            let custom = other[q.question, default: ""]
            let chosen = q.options.map(\.label).filter { selections[q.question, default: []].contains($0) }
            answers[q.question] = .string(custom.isEmpty ? chosen.joined(separator: ", ") : (chosen + [custom]).joined(separator: ", "))
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
            Text(params.message).font(.callout)
            if let urlString = params.url, let url = URL(string: urlString) {
                Link(urlString, destination: url).font(.callout)
            }
            ForEach(fields, id: \.key) { f in
                TextField(f.schema.string("title") ?? f.key, text: Binding(get: { values[f.key, default: ""] }, set: { values[f.key] = $0 }))
                    .textFieldStyle(.roundedBorder)
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
            }
        }
    }
}
