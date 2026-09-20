// Sample data for `#Preview`s across TetherKit and TetherUI. None of this runs in a release
// build — the whole file compiles out. Everything below builds instances through the same
// reducer methods live data goes through (`loadHistory`, `setInfo`, `addPending`, `apply`, …)
// so previews stay honest about what the app can actually produce; `HostConnection.previewSeed`
// in HostConnection.swift is the one exception, needed only because its stored properties are
// `private(set)` to that file.
#if DEBUG
import Foundation
import TetherProtocol

/// A millisecond timestamp `seconds` in the past, so relative-time labels read naturally.
private func preview(secondsAgo seconds: Double) -> Double {
    (Date().timeIntervalSince1970 - seconds) * 1000
}

/// A `Transport` that never connects to anything: it never yields a line and never sends one.
/// Gives a sample `HostConnection` a real, non-nil `RPCClient` — so code that only checks
/// "is there a client" behaves like a live connection — without ever touching a process or socket.
private struct PreviewTransport: Transport {
    func lines() -> AsyncThrowingStream<Data, any Error> { AsyncThrowingStream { _ in } }
    func send(_ line: Data) async throws {}
    func close() async {}
}

// MARK: - Item builders

extension Item.UserMessage {
    public static func sample(_ text: String, secondsAgo: Double, synthetic: Bool = false, origin: String? = nil) -> Item.UserMessage {
        .init(id: "user-\(UUID().uuidString)", createdAt: preview(secondsAgo: secondsAgo),
              content: [.text(.init(text: text))], synthetic: synthetic ? true : nil, origin: origin)
    }
}

extension Item.AgentMessage {
    public static func sample(_ text: String, secondsAgo: Double, parentToolUseId: String? = nil) -> Item.AgentMessage {
        .init(id: "asst-\(UUID().uuidString)", parentToolUseId: parentToolUseId, createdAt: preview(secondsAgo: secondsAgo), text: text)
    }
}

extension Item.Reasoning {
    public static func sample(_ text: String, secondsAgo: Double) -> Item.Reasoning {
        .init(id: "reason-\(UUID().uuidString)", createdAt: preview(secondsAgo: secondsAgo), text: text)
    }
}

extension Item.ToolCall {
    public static func sample(
        id: String = "tool-\(UUID().uuidString)",
        name: String,
        kind: ToolKind,
        input: JSONValue,
        status: ToolStatus = .completed,
        outputText: String? = nil,
        isError: Bool? = nil,
        elapsedSeconds: Double? = nil,
        parentToolUseId: String? = nil,
        secondsAgo: Double
    ) -> Item.ToolCall {
        .init(id: id, parentToolUseId: parentToolUseId, createdAt: preview(secondsAgo: secondsAgo),
              name: name, kind: kind, input: input, status: status, outputText: outputText,
              isError: isError, elapsedSeconds: elapsedSeconds)
    }
}

extension Item.Notice {
    public static func sample(_ text: String, kind: String = "informational", level: Item.Notice.Level? = nil, secondsAgo: Double) -> Item.Notice {
        .init(id: "notice-\(UUID().uuidString)", createdAt: preview(secondsAgo: secondsAgo), kind: kind, text: text, level: level)
    }
}

extension Item {
    public static func sampleUserMessage(_ text: String, secondsAgo: Double, synthetic: Bool = false, origin: String? = nil) -> Item {
        .userMessage(.sample(text, secondsAgo: secondsAgo, synthetic: synthetic, origin: origin))
    }

    public static func sampleAgentMessage(_ text: String, secondsAgo: Double, parentToolUseId: String? = nil) -> Item {
        .agentMessage(.sample(text, secondsAgo: secondsAgo, parentToolUseId: parentToolUseId))
    }

    public static func sampleReasoning(_ text: String, secondsAgo: Double) -> Item {
        .reasoning(.sample(text, secondsAgo: secondsAgo))
    }

    public static func sampleToolCall(
        id: String = "tool-\(UUID().uuidString)",
        name: String,
        kind: ToolKind,
        input: JSONValue,
        status: ToolStatus = .completed,
        outputText: String? = nil,
        isError: Bool? = nil,
        elapsedSeconds: Double? = nil,
        parentToolUseId: String? = nil,
        secondsAgo: Double
    ) -> Item {
        .toolCall(.sample(id: id, name: name, kind: kind, input: input, status: status, outputText: outputText,
                          isError: isError, elapsedSeconds: elapsedSeconds, parentToolUseId: parentToolUseId, secondsAgo: secondsAgo))
    }

    public static func sampleNotice(_ text: String, kind: String = "informational", level: Item.Notice.Level? = nil, secondsAgo: Double) -> Item {
        .notice(.sample(text, kind: kind, level: level, secondsAgo: secondsAgo))
    }
}

// MARK: - Turn builders

extension TurnResult {
    /// A turn's cost/usage summary. Defaults describe an unremarkable, successful turn.
    public static func sample(
        subtype: String = "success",
        isError: Bool = false,
        resultText: String? = nil,
        errors: [String]? = nil,
        durationSeconds: Double = 9,
        totalCostUsd: Double = 0.18,
        inputTokens: Double = 14_200,
        outputTokens: Double = 680,
        model: String = "claude-opus-4-5-20251101"
    ) -> TurnResult {
        let usage = Usage(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadInputTokens: 9_800, cacheCreationInputTokens: 320)
        let modelUsage = ModelUsage(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadInputTokens: 9_800,
                                     cacheCreationInputTokens: 320, costUsd: totalCostUsd, contextWindow: 200_000, maxOutputTokens: 32_000)
        return .init(subtype: subtype, isError: isError, resultText: resultText, errors: errors,
                     durationMs: durationSeconds * 1000, durationApiMs: durationSeconds * 850, numTurns: 1,
                     totalCostUsd: totalCostUsd, usage: usage, modelUsage: [model: modelUsage])
    }
}

extension Turn {
    public static func sample(status: TurnStatus = .completed, secondsAgo: Double = 4, result: TurnResult? = .sample()) -> Turn {
        .init(id: "turn-\(UUID().uuidString)", status: status,
              startedAt: preview(secondsAgo: secondsAgo + 9),
              completedAt: status == .inProgress ? nil : preview(secondsAgo: secondsAgo),
              result: status == .inProgress ? nil : result)
    }
}

// MARK: - Pending request builders (one per PromptViews case)

extension PendingRequest {
    public static func samplePermission(
        toolName: String = "Bash",
        displayName: String? = "Bash",
        description: String? = "Clean the package's build directory",
        input: JSONValue = ["command": "rm -rf TetherKit/.build", "description": "Clean the package's build directory"],
        decisionReason: String? = "This command matches a rule that asks for confirmation.",
        defaultToNo: Bool? = nil
    ) -> PendingRequest {
        let params = PermissionRequestParams(threadId: "preview-thread", requestId: "req-permission", toolUseId: "tool-permission",
                                              toolName: toolName, input: input, displayName: displayName, description: description,
                                              decisionReason: decisionReason, defaultToNo: defaultToNo)
        return PendingRequest(id: params.requestId, request: .permissionRequest(params), respond: { _ in })
    }

    public static func sampleQuestion() -> PendingRequest {
        let params = QuestionRequestParams(threadId: "preview-thread", requestId: "req-question", toolUseId: "tool-question", questions: [
            .init(question: "Which build system should the new Xcode target use?", header: "Build system", multiSelect: false, options: [
                .init(label: "Swift Package Manager", description: "Keep everything in TetherKit's Package.swift."),
                .init(label: "Xcode project", description: "Add a target to Tether.xcodeproj directly."),
            ]),
        ])
        return PendingRequest(id: params.requestId, request: .questionRequest(params), respond: { _ in })
    }

    public static func samplePlan() -> PendingRequest {
        let plan = """
        ## Add previews to TetherUI

        1. Add `PreviewSupport.swift` with sample `ThreadModel` / `HostConnection` factories.
        2. Add `#Preview` blocks to every view in `TetherUI`.
        3. Render each one in Xcode and fix anything that clips or looks wrong.
        """
        let params = PlanApproveParams(threadId: "preview-thread", requestId: "req-plan", toolUseId: "tool-plan", plan: plan)
        return PendingRequest(id: params.requestId, request: .planApprove(params), respond: { _ in })
    }

    public static func sampleElicitation() -> PendingRequest {
        let schema: JSONValue = ["properties": ["environment": ["type": "string", "title": "Environment"]]]
        let params = ElicitationRequestParams(threadId: "preview-thread", requestId: "req-elicitation", serverName: "deploy-tools",
                                               message: "Which environment should I deploy to?", requestedSchema: schema)
        return PendingRequest(id: params.requestId, request: .elicitationRequest(params), respond: { _ in })
    }

    public static func sampleDialog() -> PendingRequest {
        let params = DialogRequestParams(threadId: "preview-thread", requestId: "req-dialog", dialogKind: "trustFolder",
                                          payload: ["path": "/Users/hayden/Code/tether-app"])
        return PendingRequest(id: params.requestId, request: .dialogRequest(params), respond: { _ in })
    }

    /// A server request from a newer daemon this client doesn't know how to render yet.
    public static func sampleUnknown() -> PendingRequest {
        PendingRequest(id: "req-unknown", request: .unknown(method: "future/request", params: ["hello": "world"]), respond: { _ in })
    }
}

// MARK: - Model catalog

extension ModelInfo {
    /// A small, realistic model list — enough to exercise ModelPicker/EffortPicker.
    public static let sampleCatalog: [ModelInfo] = [
        .init(value: "claude-opus-4-5-20251101", resolvedModel: "claude-opus-4-5-20251101", displayName: "Claude Opus 4.5",
              description: "Most capable model, for complex tasks", supportsEffort: true,
              supportedEffortLevels: [.low, .medium, .high, .max], supportsAdaptiveThinking: true, supportsFastMode: false, supportsAutoMode: true),
        .init(value: "claude-sonnet-5-20250929", resolvedModel: "claude-sonnet-5-20250929", displayName: "Claude Sonnet 5",
              description: "Balanced for everyday coding", supportsEffort: true,
              supportedEffortLevels: [.low, .medium, .high], supportsAdaptiveThinking: true, supportsFastMode: true, supportsAutoMode: true),
        .init(value: "claude-haiku-4-5-20251001", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5",
              description: "Fastest, for lightweight tasks", supportsEffort: false, supportsAdaptiveThinking: false,
              supportsFastMode: true, supportsAutoMode: false),
    ]
}

// MARK: - ThreadModel scenarios

extension ThreadModel {
    /// Builds a thread the way `thread/read` would (seeded history + live info), with no network.
    public static func sample(
        id: String = "preview-\(UUID().uuidString)",
        cwd: String = "/Users/hayden/Code/tether-app",
        title: String? = nil,
        status: ThreadStatus = .idle,
        model: String? = "claude-opus-4-5-20251101",
        effort: EffortLevel? = .high,
        permissionMode: PermissionMode = .default,
        items: [Item] = [],
        turns: [Turn] = [],
        pending: [PendingRequest] = [],
        tasks: [TaskEventNotification] = [],
        mcpServers: [McpServerStatus]? = nil,
        lastError: String? = nil
    ) -> ThreadModel {
        let thread = ThreadModel(id: id)
        thread.loadHistory(items: items, turns: turns, seq: nil)
        thread.setInfo(.init(threadId: id, status: status, cwd: cwd, title: title, model: model, effort: effort,
                              permissionMode: permissionMode, mcpServers: mcpServers, lastSeq: 0))
        for p in pending { thread.addPending(p) }
        for t in tasks { thread.apply(.taskEvent(t)) }
        if let lastError { thread.setError(lastError) }
        return thread
    }

    /// A chat with subagents running and MCP servers configured, for the inspector's panes.
    public static func sampleWithTasks() -> ThreadModel {
        sample(
            title: "Audit the SwiftUI views",
            status: .running,
            tasks: [
                .init(threadId: "preview-thread", seq: 1, event: "task_started", taskId: "task-1",
                      description: "Explore the inspector column", status: "running", data: [:]),
                .init(threadId: "preview-thread", seq: 2, event: "task_started", taskId: "task-2",
                      description: "Check every pane for empty states", status: "running", data: [:]),
                .init(threadId: "preview-thread", seq: 3, event: "task_completed", taskId: "task-3",
                      description: "Read the HIG pages on pop-up buttons", status: "completed", data: [:]),
            ],
            mcpServers: [
                .init(name: "xcode", status: "connected"),
                .init(name: "computer-use", status: "connected"),
                .init(name: "reminders", status: "failed"),
            ])
    }

    /// A finished conversation: a question, some visible thinking, and a Markdown reply that
    /// exercises headings, a bullet list, inline code and a fenced code block.
    public static func sampleIdleChat() -> ThreadModel {
        sample(
            title: "Explain ThreadModel's turn tracking",
            items: [
                .sampleUserMessage("Can you explain how ThreadModel tracks turns and items, then add #Preview support for the TetherUI views?", secondsAgo: 130),
                .sampleReasoning("Let me check ThreadModel.swift and the TetherUI view files before answering, so this matches what's actually there.", secondsAgo: 122),
                .sampleAgentMessage(sampleIdleChatReply, secondsAgo: 108),
            ],
            turns: [.sample(secondsAgo: 108, result: .sample(durationSeconds: 22, totalCostUsd: 0.21, inputTokens: 18_400, outputTokens: 910))]
        )
    }

    /// A turn in progress: the composer shows Stop, and a bash call is still running.
    public static func sampleRunningTurn() -> ThreadModel {
        sample(
            title: "Add previews for TetherUI",
            status: .running,
            items: [
                .sampleUserMessage("Add #Preview blocks to ToolCallView and wire up sample data for a running bash call.", secondsAgo: 40),
                .sampleAgentMessage("Sure — I'll add a bash call that's still running so the composer switches to Stop.", secondsAgo: 30),
                .sampleToolCall(name: "Bash", kind: .bash, input: ["command": "swift build --target TetherKit", "description": "Build TetherKit"],
                                status: .running, elapsedSeconds: 6, secondsAgo: 8),
            ],
            turns: [.sample(status: .inProgress, secondsAgo: 30)]
        )
    }

    /// One of every tool-call kind, including a subagent with nested children.
    public static func sampleToolCalls() -> ThreadModel {
        let subagentId = "tool-subagent-explore"
        return sample(
            title: "Tool call gallery",
            items: [
                .sampleUserMessage("Run the tests, fix the failing diff, and look up how the subagent and MCP calls render.", secondsAgo: 240),
                .sampleToolCall(name: "Bash", kind: .bash,
                                input: ["command": "swift test --filter ThreadModelTests", "description": "Run ThreadModel tests"],
                                status: .completed, outputText: "Test Suite 'ThreadModelTests' passed.\nExecuted 6 tests, with 0 failures.", secondsAgo: 220),
                .sampleToolCall(name: "Read", kind: .fileRead,
                                input: ["file_path": "/Users/hayden/Code/tether-app/TetherKit/Sources/TetherKit/ThreadModel.swift"],
                                status: .completed, secondsAgo: 210),
                .sampleToolCall(name: "Grep", kind: .grep, input: ["pattern": "upsertTurn", "path": "TetherKit/Sources/TetherKit"],
                                status: .completed, outputText: "ThreadModel.swift:145:    private func upsertTurn(_ t: Turn) {", secondsAgo: 200),
                .sampleToolCall(name: "Edit", kind: .fileEdit, input: [
                    "file_path": "/Users/hayden/Code/tether-app/TetherKit/Sources/TetherKit/ThreadModel.swift",
                    "old_string": "    public private(set) var lastSeq = 0",
                    "new_string": "    public private(set) var lastSeq = 0\n    public private(set) var isPreview = false",
                ], status: .completed, secondsAgo: 190),
                .sampleToolCall(name: "TodoWrite", kind: .todoWrite, input: ["todos": [
                    ["content": "Add PreviewSupport.swift", "activeForm": "Adding PreviewSupport.swift", "status": "completed"],
                    ["content": "Add #Preview blocks to every TetherUI view", "activeForm": "Adding #Preview blocks", "status": "in_progress"],
                    ["content": "Render every preview in Xcode and fix issues", "activeForm": "Rendering previews", "status": "pending"],
                ]], status: .completed, secondsAgo: 180),
                .sampleToolCall(id: subagentId, name: "Task", kind: .subagent, input: [
                    "subagent_type": "Explore", "description": "Find every SwiftUI view in TetherUI",
                    "prompt": "Search TetherKit/Sources/TetherUI for every top-level View and report its file.",
                ], status: .running, elapsedSeconds: 9, secondsAgo: 170),
                .sampleToolCall(name: "Grep", kind: .grep, input: ["pattern": "struct .*View"], status: .completed,
                                outputText: "12 matches across 8 files", parentToolUseId: subagentId, secondsAgo: 168),
                .sampleAgentMessage("Found 12 views across 8 files: RootView, ThreadView, Composer, ItemViews, ToolCallView, PromptViews, Markdown, SettingsView.",
                                    secondsAgo: 166, parentToolUseId: subagentId),
                .sampleToolCall(name: "mcp__xcode__RenderPreview", kind: .mcp, input: ["file": "ItemViews.swift", "preview": "Bash tool call"],
                                status: .completed, outputText: "Rendered 1 preview.", secondsAgo: 60),
                .sampleToolCall(name: "NotebookRead", kind: .other, input: ["notebook_path": "/Users/hayden/Code/tether-app/notes.ipynb"],
                                status: .denied, secondsAgo: 50),
            ],
            turns: [.sample(secondsAgo: 40)]
        )
    }

    /// A thread waiting on a permission decision — `pending.first` replaces the composer.
    public static func samplePendingPermission() -> ThreadModel {
        sample(title: "Clean the build directory", status: .requiresAction, items: [
            .sampleUserMessage("Can you clean the build directory before we test the release build?", secondsAgo: 20),
        ], pending: [.samplePermission()])
    }

    /// A thread waiting on an AskUserQuestion answer.
    public static func samplePendingQuestion() -> ThreadModel {
        sample(title: "New Xcode target", status: .requiresAction, items: [
            .sampleUserMessage("Add a new target for the CLI.", secondsAgo: 20),
        ], pending: [.sampleQuestion()])
    }

    /// A thread waiting on plan approval (plan mode).
    public static func samplePendingPlan() -> ThreadModel {
        sample(title: "Previews for TetherUI", status: .requiresAction, permissionMode: .plan, items: [
            .sampleUserMessage("Plan out how to add previews before touching any code.", secondsAgo: 60),
        ], pending: [.samplePlan()])
    }

    /// A thread waiting on an MCP elicitation.
    public static func samplePendingElicitation() -> ThreadModel {
        sample(title: "Deploy", status: .requiresAction, items: [
            .sampleUserMessage("Deploy the latest build.", secondsAgo: 20),
        ], pending: [.sampleElicitation()])
    }

    /// A turn that failed, with `thread.lastError` also set — exercises TurnFooter and StatusStrip.
    public static func sampleErrorTurn() -> ThreadModel {
        sample(title: "Deploy to production", status: .error, items: [
            .sampleUserMessage("Deploy the server changes to production.", secondsAgo: 90),
            .sampleToolCall(name: "Bash", kind: .bash, input: ["command": "./scripts/deploy.sh production"], status: .failed,
                            outputText: "Error: SSH connection to deploy-01 timed out", isError: true, secondsAgo: 70),
        ], turns: [
            .sample(status: .failed, secondsAgo: 65,
                    result: .sample(subtype: "error_during_execution", isError: true,
                                    errors: ["SSH connection to deploy-01 timed out"], durationSeconds: 25, totalCostUsd: 0.09)),
        ], lastError: "Not connected")
    }

    /// A turn the user interrupted mid-stream.
    public static func sampleInterruptedTurn() -> ThreadModel {
        sample(title: "Refactor HostConnection", status: .interrupted, items: [
            .sampleUserMessage("Refactor HostConnection to split the reconnect logic out.", secondsAgo: 50),
            .sampleAgentMessage("Starting by pulling scheduleReconnect into its own type…", secondsAgo: 40),
        ], turns: [
            .sample(status: .interrupted, secondsAgo: 38, result: .sample(durationSeconds: 12, totalCostUsd: 0.03)),
        ])
    }

    /// A running turn stuck retrying the API — exercises StatusStrip's retry banner.
    public static func sampleApiRetry() -> ThreadModel {
        let thread = sample(title: "Long-running migration", status: .running, items: [
            .sampleUserMessage("Keep going with the migration script.", secondsAgo: 20),
        ], turns: [.sample(status: .inProgress, secondsAgo: 15)])
        thread.apply(.threadApiRetry(.init(threadId: thread.id, seq: 1, attempt: 2, maxRetries: 5, retryDelayMs: 4000, errorStatus: 529, error: "Overloaded")))
        return thread
    }
}

private let sampleIdleChatReply = """
## How `ThreadModel` tracks a conversation

`ThreadModel` keeps two parallel timelines:

- **`items`** — every `UserMessage`, `AgentMessage`, `Reasoning` and `ToolCall`, in server order, indexed by `id` for O(1) updates.
- **`turns`** — one `Turn` per assistant turn, with a `TurnStatus` and, once finished, a `TurnResult` carrying cost and token usage.

Notifications like `itemAgentMessageDelta` mutate an item in place:

```swift
case .itemAgentMessageDelta(let e):
    mutate(e.itemId) { if case .agentMessage(var m) = $0 { m.text += e.delta } }
```

I've added `PreviewSupport.swift` so every `TetherUI` view can now preview against sample data without a live server.
"""

// MARK: - HostConnection scenarios

extension HostConnection {
    /// A connected "This Mac" host with a model catalog, a couple of projects, and a spread of
    /// chats for the sidebar. Never touches the network or spawns a process.
    public static func sample() -> HostConnection {
        let chats = [
            ThreadModel.sampleRunningTurn(),
            ThreadModel.samplePendingPermission(),
            ThreadModel.sampleIdleChat(),
            ThreadModel.sampleErrorTurn(),
        ]
        let connection = HostConnection(host: .local)
        connection.previewSeed(
            state: .connected,
            // Non-nil but never started: `ThreadModel`s below already have their history loaded,
            // so views only need `client != nil` to see the connection as usable — nothing ever
            // sends a real request over it.
            client: RPCClient(transport: PreviewTransport()),
            serverInfo: .init(
                serverInfo: .init(name: "tether-server", version: "0.4.0"),
                protocolVersion: tetherProtocolVersion,
                host: .init(hostname: "haydens-mac.local", platform: "darwin", arch: "arm64", home: NSHomeDirectory(), pid: 4242, mode: .daemon),
                claude: .init(path: "/opt/homebrew/bin/claude", version: "2.1.4")),
            account: .init(email: "hello@haydenhong.com", organization: "Personal", subscriptionType: "max", tokenSource: "keychain", apiProvider: "firstParty"),
            models: ModelInfo.sampleCatalog,
            projects: [
                .init(cwd: "/Users/hayden/Code/tether-app", lastActivity: preview(secondsAgo: 40), threadCount: 4),
                .init(cwd: "/Users/hayden/Code/tether-server", lastActivity: preview(secondsAgo: 3_600), threadCount: 2),
            ],
            chats: chats)
        return connection
    }

    /// A second host (an SSH box) mid-connection, to show the sidebar's other connection states.
    public static func sampleConnecting() -> HostConnection {
        let connection = HostConnection(host: .init(name: "build-box", kind: .ssh(destination: "build-box")))
        connection.previewSeed(state: .connecting("Handshaking…"))
        return connection
    }

    /// A host whose last connection attempt failed.
    public static func sampleFailed() -> HostConnection {
        let connection = HostConnection(host: .init(name: "staging", kind: .ssh(destination: "staging")))
        connection.previewSeed(state: .failed("Connection refused"))
        return connection
    }
}
#endif
