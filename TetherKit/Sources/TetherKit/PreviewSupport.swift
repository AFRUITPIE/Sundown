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
        model: String = "opus"
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
    /// A small, realistic model list — enough to exercise the session menus.
    /// Shaped like what `model/list` actually returns: short family display names, the version
    /// only in `resolvedModel`, and a leading "default" alias that resolves to one of the others.
    public static let sampleCatalog: [ModelInfo] = [
        .init(value: "default", resolvedModel: "claude-sonnet-5", displayName: "Default (recommended)",
              description: "Whatever Claude Code would choose", supportsEffort: true,
              supportedEffortLevels: [.low, .medium, .high], supportsAdaptiveThinking: true, supportsFastMode: true, supportsAutoMode: true),
        .init(value: "sonnet", resolvedModel: "claude-sonnet-5", displayName: "Sonnet",
              description: "Balanced for everyday coding", supportsEffort: true,
              supportedEffortLevels: [.low, .medium, .high], supportsAdaptiveThinking: true, supportsFastMode: true, supportsAutoMode: true),
        .init(value: "claude-fable-5-1[1m]", resolvedModel: "claude-fable-5-1", displayName: "Fable",
              description: "Long context", supportsEffort: true,
              supportedEffortLevels: [.low, .medium, .high, .max], supportsAdaptiveThinking: true, supportsFastMode: false, supportsAutoMode: true),
        .init(value: "opus", resolvedModel: "claude-opus-5", displayName: "Opus",
              description: "Most capable model, for complex tasks", supportsEffort: true,
              supportedEffortLevels: [.low, .medium, .high, .max], supportsAdaptiveThinking: true, supportsFastMode: false, supportsAutoMode: true),
        .init(value: "haiku", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku",
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
        model: String? = "opus",
        effort: EffortLevel? = .high,
        permissionMode: PermissionMode = .default,
        fastModeState: ThreadInfo.FastModeState? = nil,
        fastModeDisabledReason: String? = nil,
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
                              permissionMode: permissionMode, fastModeState: fastModeState,
                              fastModeDisabledReason: fastModeDisabledReason, mcpServers: mcpServers, lastSeq: 0))
        for p in pending { thread.addPending(p) }
        for t in tasks { thread.apply(.taskEvent(t)) }
        if let lastError { thread.setError(lastError) }
        return thread
    }

    /// A chat as `thread/list` first hands it over: a title, a folder and a timestamp, with no
    /// transcript. Most of what the sidebar shows is this, so its grouping previews are built of it.
    public static func sampleListed(
        id: String = "listed-\(UUID().uuidString)",
        title: String,
        cwd: String?,
        secondsAgo: Double,
        status: ThreadStatus = .notLoaded,
        tag: String? = nil
    ) -> ThreadModel {
        var summary = ThreadSummary(threadId: id, title: title, cwd: cwd,
                                    updatedAt: preview(secondsAgo: secondsAgo), status: status)
        summary.tag = tag
        return ThreadModel(id: id, summary: summary)
    }

    /// A chat whose transcript hasn't arrived — what the transcript stands in for. With a message
    /// the read itself failed; without one the connection's own state has to explain it.
    public static func sampleUnloaded(lastError: String? = nil) -> ThreadModel {
        let thread = sampleListed(title: "Deploy to production", cwd: "/Users/hayden/Code/tether-app", secondsAgo: 300)
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
                .init(threadId: "preview-thread", seq: 4, event: "task_failed", taskId: "task-4",
                      description: "Render every inspector pane", status: "failed", data: [:]),
            ],
            mcpServers: [
                .init(name: "xcode", status: "connected", toolCount: 24),
                .init(name: "computer-use", status: "connected", toolCount: 1),
                .init(name: "linear", status: "needs-auth"),
                .init(name: "reminders", status: "failed", error: "spawn RemindersServer ENOENT"),
            ])
    }

    /// A finished conversation: a question, some visible thinking, and a Markdown reply that
    /// exercises headings, a bullet list, inline code and a fenced code block.
    /// A finished chat in which Claude suggested a task to start separately.
    public static func sampleWithSuggestedTask() -> ThreadModel {
        let t = sampleIdleChat()
        t.apply(.threadTaskSuggested(.init(threadId: t.id, seq: 10_000, title: "Add previews for SessionPane",
                                           prompt: "Add #Preview coverage for SessionPane's loading, failed and ready states.")))
        return t
    }

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

    /// Two finished turns of real-looking work: messages between runs of reads, searches, edits and
    /// commands, one of which failed. For comparing Settings ▸ Advanced ▸ Tool Calls.
    public static func sampleWorkChat() -> ThreadModel {
        let root = "/Users/hayden/Code/tether-app/TetherKit/Sources/TetherUI/"
        let build: JSONValue = ["command": "swift build --package-path TetherKit", "description": "Build TetherKit"]
        let edit: JSONValue = [
            "file_path": .string(root + "RootView.swift"),
            "old_string": "        .frame(minWidth: showInspector ? 1000 : 740)",
            "new_string": "        .frame(minWidth: 740)",
        ]
        var first: [Item] = [
            .sampleUserMessage("Resizing the window with the inspector open stutters. Can you find out why?", secondsAgo: 900),
            .sampleAgentMessage("I'll look at how the split view sets its widths.", secondsAgo: 895),
        ]
        first.append(.sampleToolCall(name: "Read", kind: .fileRead, input: ["file_path": .string(root + "RootView.swift")],
                                     status: .completed, secondsAgo: 890))
        first.append(.sampleToolCall(name: "Read", kind: .fileRead, input: ["file_path": .string(root + "Inspector/InspectorView.swift")],
                                     status: .completed, secondsAgo: 885))
        first.append(.sampleToolCall(name: "Grep", kind: .grep, input: ["pattern": "minWidth"], status: .completed,
                                     outputText: "RootView.swift:44\nRootView.swift:67", secondsAgo: 880))
        first.append(.sampleToolCall(name: "Bash", kind: .bash, input: build, status: .failed,
                                     outputText: "error: cannot find 'inspectorMinimum' in scope\n  --> RootView.swift:67:21", secondsAgo: 860))
        first.append(.sampleAgentMessage("The build caught a name I got wrong. Fixing it.", secondsAgo: 850))
        first.append(.sampleToolCall(name: "Edit", kind: .fileEdit, input: edit, status: .completed, secondsAgo: 840))
        first.append(.sampleToolCall(name: "Edit", kind: .fileEdit, input: [
            "file_path": .string(root + "RootView.swift"),
            "old_string": "    private var minWidth: CGFloat? {\n        guard showInspector else { return 740 }\n        return inspectorSettled ? 1000 : nil\n    }",
            "new_string": "    private var minWidth: CGFloat? {\n        guard showInspector else { return InspectorWidth.windowMinimum }\n        return inspectorSettled ? InspectorWidth.windowMinimum + InspectorWidth.column : nil\n    }",
        ], status: .completed, secondsAgo: 835))
        first.append(.sampleToolCall(name: "Write", kind: .fileWrite, input: [
            "file_path": .string(root + "Inspector/InspectorWidth.swift"),
            "content": "import CoreGraphics\n\n/// The widths the window's minimum is made of.\nenum InspectorWidth {\n    static let windowMinimum: CGFloat = 740\n    static let column: CGFloat = 260\n}\n",
        ], status: .completed, secondsAgo: 830))
        first.append(.sampleToolCall(name: "MultiEdit", kind: .fileEdit, input: [
            "file_path": .string(root + "Inspector/InspectorView.swift"),
            "edits": [
                ["old_string": ".inspectorColumnWidth(min: 260, ideal: 300, max: 420)",
                 "new_string": ".inspectorColumnWidth(min: InspectorWidth.column, ideal: 300, max: 420)"],
            ],
        ], status: .completed, secondsAgo: 825))
        // Failed, so it changed nothing and isn't counted.
        first.append(.sampleToolCall(name: "Edit", kind: .fileEdit, input: [
            "file_path": .string(root + "Thread/TranscriptView.swift"), "old_string": "minWidth", "new_string": "minimumWidth",
        ], status: .failed, outputText: "<tool_use_error>String to replace not found in file.</tool_use_error>", secondsAgo: 820))
        first.append(.sampleToolCall(name: "Bash", kind: .bash, input: build, status: .completed, outputText: "Build complete!", secondsAgo: 800))
        first.append(.sampleAgentMessage("Opening the inspector raised the window's minimum width from 740 to 1000 halfway through its animation, so AppKit resized the window while the split view was still laying out. The minimum now stays at 740.", secondsAgo: 690))
        var second: [Item] = [.sampleUserMessage("Does anything else change the width while it opens?", secondsAgo: 300)]
        second.append(.sampleToolCall(name: "Grep", kind: .grep, input: ["pattern": "inspectorColumnWidth"], status: .completed, secondsAgo: 295))
        second.append(.sampleToolCall(name: "Read", kind: .fileRead, input: ["file_path": .string(root + "Thread/TranscriptView.swift")],
                                      status: .completed, secondsAgo: 290))
        second.append(.sampleAgentMessage("Only the column width itself, which is fixed at 260. The transcript re-measures its rows when its width changes, but it keeps its place.", secondsAgo: 270))
        return sample(title: "Smooth out the inspector resize", items: first + second,
                      turns: [.sample(secondsAgo: 690), .sample(secondsAgo: 270)])
    }

    /// A chat picked up over more than a week, for its date separators: a prompt eight days ago,
    /// three days ago, yesterday, and a few hours ago, then a follow-up minutes after that reply,
    /// which gets none.
    public static func sampleDatedChat() -> ThreadModel {
        let day: Double = 86_400
        let root = "/Users/hayden/Code/tether-app/TetherKit/Sources/TetherUI/"
        let items: [Item] = [
            .sampleUserMessage("Sketch how the transcript could mark where a chat picks up after a break.", secondsAgo: 8 * day),
            .sampleAgentMessage("Messages puts the date above the first message after an hour's gap, and above every day change. The same rule suits a transcript.", secondsAgo: 8 * day - 40),
            .sampleUserMessage("Let's do it. Start with the decision, and test it.", secondsAgo: 3 * day),
            .sampleToolCall(name: "Read", kind: .fileRead, input: ["file_path": .string(root + "Thread/TranscriptView.swift")],
                            status: .completed, secondsAgo: 3 * day - 20),
            .sampleToolCall(name: "Edit", kind: .fileEdit, input: [
                "file_path": .string(root + "Thread/TranscriptView.swift"),
                "old_string": "TranscriptRowView(row: row, thread: thread)",
                "new_string": "TranscriptRowView(row: row, thread: thread)\n    // Dates come in as rows of their own.",
            ], status: .completed, secondsAgo: 3 * day - 30),
            .sampleAgentMessage("The decision is a pure function over the prompts' times, with tests for a day change and for an hour's gap.", secondsAgo: 3 * day - 60),
            .sampleUserMessage("Does it use the reader's locale?", secondsAgo: day),
            .sampleAgentMessage("Yes: the day and time come from the locale's own formats, and Today and Yesterday from its relative names.", secondsAgo: day - 20),
            .sampleUserMessage("Ship it.", secondsAgo: 3 * 3_600),
            .sampleAgentMessage("Committed.", secondsAgo: 3 * 3_600 - 30),
            .sampleUserMessage("One more thing: does a follow-up a few minutes later get one too?", secondsAgo: 3 * 3_600 - 300),
            .sampleAgentMessage("No. It's the same stretch of the chat, so it goes on without a date.", secondsAgo: 3 * 3_600 - 320),
        ]
        return sample(title: "Date separators", items: items,
                      turns: [.sample(secondsAgo: 8 * day - 40), .sample(secondsAgo: 3 * day - 60), .sample(secondsAgo: day - 20),
                              .sample(secondsAgo: 3 * 3_600 - 30), .sample(secondsAgo: 3 * 3_600 - 320)])
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

    /// A turn that failed, with `thread.lastError` also set — exercises TurnOutcome and StatusStrip.
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

    /// A finished chat whose plan limit is `status` (`allowed_warning`, `rejected`), resetting
    /// `resetsIn` seconds from now — exercises StatusStrip's usage line.
    public static func sampleRateLimited(_ status: String, kind: String, utilization: Double, resetsIn: TimeInterval) -> ThreadModel {
        let thread = sampleIdleChat()
        let info: [String: JSONValue] = [
            "status": .string(status), "rateLimitType": .string(kind), "utilization": .number(utilization),
            "resetsAt": .number(Date.now.addingTimeInterval(resetsIn).timeIntervalSince1970),
        ]
        thread.apply(.threadRateLimit(.init(threadId: thread.id, seq: 10_000, info: .object(info))))
        return thread
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
        let day: Double = 86_400
        let chats = [
            ThreadModel.sampleRunningTurn(),
            ThreadModel.samplePendingPermission(),
            ThreadModel.sampleIdleChat(),
            ThreadModel.sampleErrorTurn(),
            // Listed-only chats, spread across the date buckets and a few folders — including two
            // folders that share a last path component, which must stay two sections.
            .sampleListed(title: "Fold completed tool calls into a group", cwd: "/Users/hayden/Code/tether-app", secondsAgo: 3 * 3_600),
            .sampleListed(title: "Why does reconnect replay from zero?", cwd: "/Users/hayden/Code/tether-server", secondsAgo: day + 4 * 3_600),
            .sampleListed(title: "Bump the pinned server version", cwd: nil, secondsAgo: 3 * day),
            .sampleListed(title: "Sidebar grouping spike", cwd: "/Users/hayden/Developer/archive/tether-app", secondsAgo: 12 * day),
            .sampleListed(title: "First pass at the SSH bootstrapper", cwd: "/Users/hayden/Code/tether-server", secondsAgo: 45 * day),
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

    /// A connected host that has never been used: the sidebar's "No Chats" state.
    public static func sampleEmpty() -> HostConnection {
        let connection = HostConnection(host: .local)
        connection.previewSeed(state: .connected, client: RPCClient(transport: PreviewTransport()),
                               models: ModelInfo.sampleCatalog)
        return connection
    }

    /// A host nobody has connected to yet this launch.
    public static func sampleDisconnected() -> HostConnection {
        let connection = HostConnection(host: .init(name: "build-box", kind: .ssh(destination: "build-box")))
        connection.previewSeed(state: .disconnected)
        return connection
    }

    /// A connected SSH box with environment overrides and a Bedrock account — the second shape
    /// the Hosts settings have to show.
    public static func sampleConnectedSSH() -> HostConnection {
        let connection = HostConnection(host: .init(name: "build-box", kind: .ssh(destination: "build-box"),
                                                    env: ["AWS_PROFILE": "tether", "AWS_REGION": "us-west-2"]))
        connection.previewSeed(
            state: .connected,
            client: RPCClient(transport: PreviewTransport()),
            serverInfo: .init(
                serverInfo: .init(name: "tether-server", version: ServerRelease.version),
                protocolVersion: tetherProtocolVersion,
                host: .init(hostname: "build-box.local", platform: "linux", arch: "x86_64", home: "/home/hayden", pid: 812, mode: .daemon),
                claude: .init(path: "/usr/local/bin/claude", version: "2.1.4")),
            account: .init(tokenSource: "env", apiProvider: "bedrock"),
            models: ModelInfo.sampleCatalog,
            runner: .npx(node: "22.12.0"))
        return connection
    }

    /// A second host (an SSH box) mid-connection, to show the sidebar's other connection states.
    public static func sampleConnecting() -> HostConnection {
        let connection = HostConnection(host: .init(name: "build-box", kind: .ssh(destination: "build-box")))
        connection.previewSeed(state: .connecting("Handshaking…"))
        return connection
    }

    /// A host whose last connection attempt failed.
    public static func sampleFailed(reason: String = "Connection refused") -> HostConnection {
        let connection = HostConnection(host: .init(name: "staging", kind: .ssh(destination: "staging")))
        connection.previewSeed(state: .failed(reason))
        return connection
    }

    /// A host without Node.js 18 or later (`found`, when it has an older one), whose copy may have
    /// failed, or which has no build to copy.
    public static func sampleNeedsNode(found: String? = nil, canCopy: Bool = true, failure: String? = nil) -> HostConnection {
        let connection = HostConnection(host: .init(name: "claude-box", kind: .ssh(destination: "claude-box")))
        let copy = canCopy ? ServerCopy(platform: "linux-x64", failure: failure) : nil
        connection.previewSeed(state: .needsNode(NodeNeeded(found: found, copy: copy)))
        return connection
    }
}
#endif
