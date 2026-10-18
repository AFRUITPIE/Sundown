import Foundation
import TetherProtocol

/// The `showcase` scenario (SUNDOWN_UI_TEST_SCENARIO=showcase): a week of believable work for the
/// README's screenshots and recordings. A weather app (Tidecast), a Node API (pantry-api) and this
/// repository, with a finished chat that edited files, one waiting on a permission, one running a
/// workflow and agents, and a reply streamed whenever a prompt is sent. Times are relative to
/// launch, so the sidebar's dates and the transcript's read as today's.
enum ShowcaseTranscript {
    static let mainThreadID = "showcase-offline"
    static let flakyThreadID = "showcase-flaky"
    static let reviewThreadID = "showcase-review"

    static let tidecast = "/Users/demo/Code/Tidecast"
    static let pantry = "/Users/demo/Code/pantry-api"
    static let site = "/Users/demo/Code/tidecast-site"
    static let sundown = "/Users/demo/Code/Sundown"

    static var now: Double { Date().timeIntervalSince1970 * 1000 }
    static func ago(minutes: Double) -> Double { now - minutes * 60_000 }

    // MARK: The chat list

    static var summaries: [ThreadSummary] {
        let day = 60.0 * 24
        let chats: [(String, String, String, Double, ThreadStatus)] = [
            (flakyThreadID, "Fix the flaky sign-in test", pantry, 4, .requiresAction),
            (mainThreadID, "Cache forecasts for offline use", tidecast, 12, .idle),
            (reviewThreadID, "Review the transcript changes", sundown, 38, .running),
            ("showcase-widget", "Lock Screen widget layout", tidecast, 95, .idle),
            ("showcase-rate", "Rate-limit the search endpoint", pantry, 140, .idle),
            ("showcase-units", "Metric and imperial units setting", tidecast, 210, .idle),
            ("showcase-og", "Open Graph images for each page", site, 300, .idle),
            ("showcase-swiftdata", "Migrate settings to SwiftData", tidecast, day + 60, .idle),
            ("showcase-notes", "Write release notes for 2.4", tidecast, day + 120, .idle),
            ("showcase-site", "Dark mode for the marketing site", site, day + 200, .idle),
            ("showcase-migrate", "Add a migration for pantry tags", pantry, day + 320, .idle),
            ("showcase-thumbs", "Speed up thumbnail generation", pantry, day * 3, .idle),
            ("showcase-sync", "Explain the sync engine", tidecast, day * 3.5, .idle),
            ("showcase-ci", "Cache CI dependencies", pantry, day * 4, .idle),
            ("showcase-launch", "Profile cold launch", tidecast, day * 5, .idle),
            ("showcase-a11y", "Dynamic Type in the tide chart", tidecast, day * 5.5, .idle),
            ("showcase-webhooks", "Retry failed Stripe webhooks", pantry, day * 6, .idle),
            ("showcase-voiceover", "Add VoiceOver labels to the tide chart", tidecast, day * 12, .idle),
            ("showcase-ipad", "iPad layout for the forecast", tidecast, day * 15, .idle),
            ("showcase-pagination", "Cursor pagination for /items", pantry, day * 18, .idle),
            ("showcase-blog", "Blog post: how tides are predicted", site, day * 22, .idle),
            ("showcase-sentry", "Triage last week's crash reports", tidecast, day * 26, .idle),
        ]
        return chats.map { id, title, cwd, minutes, status in
            ThreadSummary(threadId: id, title: title, cwd: cwd, gitBranch: "main", updatedAt: ago(minutes: minutes), status: status)
        }
    }

    static func cwd(of threadID: String) -> String {
        summaries.first { $0.threadId == threadID }?.cwd ?? tidecast
    }

    static let models: [ModelInfo] = [
        .init(value: "opus", displayName: "Opus", description: "Most capable for complex work", supportsEffort: true,
              supportedEffortLevels: [.low, .medium, .high, .xhigh, .max], supportsFastMode: true, supportsAutoMode: true),
        .init(value: "sonnet", displayName: "Sonnet", description: "Best for everyday tasks", supportsEffort: true,
              supportedEffortLevels: [.low, .medium, .high], supportsAutoMode: true),
        .init(value: "haiku", displayName: "Haiku", description: "Fastest for quick answers"),
    ]

    static let mcpServers: [McpServerStatus] = [
        .init(name: "github", status: "connected", source: "user", toolCount: 26),
        .init(name: "xcode", status: "connected", source: "project", toolCount: 21),
        .init(name: "sentry", status: "needs-auth", source: "user"),
    ]

    static let contextUsage: JSONValue = [
        "totalTokens": 71_800,
        "maxTokens": 200_000,
        "categories": [
            ["name": "System prompt", "tokens": 3_100, "kind": "used"],
            ["name": "System tools", "tokens": 12_600, "kind": "used"],
            ["name": "MCP tools", "tokens": 6_400, "kind": "used"],
            ["name": "Memory files", "tokens": 2_300, "kind": "used"],
            ["name": "Skills", "tokens": 1_000, "kind": "used"],
            ["name": "Messages", "tokens": 46_400, "kind": "used"],
            ["name": "Free space", "tokens": 95_200, "kind": "free"],
            ["name": "Autocompact buffer", "tokens": 33_000, "kind": "buffer"],
        ],
    ]

    // MARK: Transcripts

    static func items(for threadID: String) -> [Item] {
        switch threadID {
        case mainThreadID: return offlineCaching()
        case flakyThreadID: return flakyTest()
        default:
            guard let chat = summaries.first(where: { $0.threadId == threadID }) else { return [] }
            let t = chat.updatedAt - 120_000
            return [
                .userMessage(.init(id: "\(threadID)-user", createdAt: t, content: [.text(.init(text: chat.title))])),
                .agentMessage(.init(id: "\(threadID)-reply", createdAt: t + 90_000, text: "Done. Everything builds, and the tests pass.")),
            ]
        }
    }

    private static func call(_ id: String, _ name: String, _ kind: ToolKind, _ input: JSONValue, at time: Double,
                             status: ToolStatus = .completed, output: String? = nil) -> Item {
        // An edit's change, as the daemon sends it with the finished call.
        .toolCall(Item.ToolCall(id: id, createdAt: time, name: name, kind: kind, input: input, status: status, outputText: output)
            .withComparedEdit)
    }

    private static func path(_ file: String) -> JSONValue { .string("\(tidecast)/\(file)") }

    static let cacheSource = """
    import Foundation

    /// The last forecast fetched for each location, kept in the app group's Caches so the app and
    /// its widgets can show it when the network can't.
    actor ForecastCache {
        static let shared = ForecastCache()

        private let directory: URL

        init(directory: URL = .appGroupCaches.appending(path: "Forecasts")) {
            self.directory = directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func store(_ forecast: Forecast, for location: Location) throws {
            let data = try JSONEncoder.forecast.encode(forecast)
            try data.write(to: file(for: location), options: .atomic)
        }

        func load(for location: Location) throws -> Forecast? {
            guard let data = try? Data(contentsOf: file(for: location)) else { return nil }
            return try JSONDecoder.forecast.decode(Forecast.self, from: data)
        }

        private func file(for location: Location) -> URL {
            directory.appending(path: "\\(location.id).json")
        }
    }
    """

    static let testsSource = """
    import Testing
    @testable import Tidecast

    @Suite struct ForecastCacheTests {
        let cache = ForecastCache(directory: .temporaryDirectory.appending(path: UUID().uuidString))

        @Test func returnsNothingBeforeTheFirstFetch() async throws {
            #expect(try await cache.load(for: .seattle) == nil)
        }

        @Test func returnsTheLastForecastStored() async throws {
            try await cache.store(.sample, for: .seattle)
            #expect(try await cache.load(for: .seattle) == .sample)
        }

        @Test func keepsLocationsApart() async throws {
            try await cache.store(.sample, for: .seattle)
            #expect(try await cache.load(for: .bainbridge) == nil)
        }
    }
    """

    static let serviceOld = """
        func forecast(for location: Location) async throws -> Forecast {
            try await client.forecast(for: location)
        }
    """

    static let serviceNew = """
        func forecast(for location: Location) async throws -> Forecast {
            do {
                let fresh = try await client.forecast(for: location)
                try? await cache.store(fresh, for: location)
                return fresh
            } catch let error as URLError where error.isOffline {
                guard let saved = try await cache.load(for: location) else { throw error }
                return saved.marked(stale: true)
            }
        }
    """

    static let viewOld = """
                Text(forecast.location.name)
                    .font(.largeTitle.bold())
    """

    static let viewNew = """
                Text(forecast.location.name)
                    .font(.largeTitle.bold())
                if forecast.isStale {
                    Label("Updated \\(forecast.fetchedAt, format: .relative(presentation: .named))",
                          systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
    """

    static let finalReply = """
    Offline forecasts work now. When a request fails because there's no connection, the forecast \
    screen shows the last one it fetched for that location, with its age under the title, instead \
    of going blank.

    ### What changed

    - **`ForecastCache`** (new) keeps the last forecast for each location as JSON in the app group's \
    Caches, so the widgets can read it too.
    - **`ForecastService.forecast(for:)`** stores every fresh forecast, and falls back to the stored \
    one when the request fails offline.
    - **`ForecastView`** says *Updated 2 hours ago* when it's showing a stored forecast.

    ```swift
    func forecast(for location: Location) async throws -> Forecast {
        do {
            let fresh = try await client.forecast(for: location)
            try? await cache.store(fresh, for: location)
            return fresh
        } catch let error as URLError where error.isOffline {
            guard let saved = try await cache.load(for: location) else { throw error }
            return saved.marked(stale: true)
        }
    }
    ```

    | Situation | Before | Now |
    |---|---|---|
    | Online | Live forecast | Live forecast |
    | Offline, seen before | Blank screen | Last forecast, with its age |
    | Offline, never seen | Blank screen | “No forecast yet” and Retry |

    The three new tests in `ForecastCacheTests` pass, along with the existing 48. Want me to add a \
    background refresh, so the stored forecast is never more than an hour old?
    """

    static func offlineCaching() -> [Item] {
        let t = ago(minutes: 31)
        func at(_ seconds: Double) -> Double { t + seconds * 1000 }
        return [
            .userMessage(.init(id: "offline-user-1", createdAt: t, content: [.text(.init(text:
                "The forecast screen goes blank whenever I lose signal on the ferry. Can you keep the last forecast around so it still shows offline?"))])),
            call("offline-glob", "Glob", .glob, ["pattern": "**/Forecast*.swift"], at: at(4),
                 output: "Sources/Tidecast/Forecast/ForecastView.swift\nSources/Tidecast/Forecast/ForecastService.swift\nSources/Tidecast/Forecast/ForecastModel.swift"),
            call("offline-read-view", "Read", .fileRead, ["file_path": path("Sources/Tidecast/Forecast/ForecastView.swift")], at: at(7),
                 output: "1\timport SwiftUI\n2\n3\tstruct ForecastView: View {\n4\t    let forecast: Forecast"),
            call("offline-read-service", "Read", .fileRead, ["file_path": path("Sources/Tidecast/Forecast/ForecastService.swift")], at: at(9),
                 output: "1\timport Foundation\n2\n3\tstruct ForecastService {\n4\t    let client: WeatherClient"),
            call("offline-grep", "Grep", .grep, ["pattern": "URLCache|cachePolicy", "path": path("Sources")], at: at(12),
                 output: "No matches found"),
            .agentMessage(.init(id: "offline-note", createdAt: at(18), text:
                "`ForecastService` fetches straight into the view and nothing is kept on disk, so a failed request leaves the screen with nothing to show. I'll add a small cache keyed by location and fall back to it when the request fails offline.")),
            call("offline-write-cache", "Write", .fileWrite, ["file_path": path("Sources/Tidecast/Forecast/ForecastCache.swift"),
                                                              "content": .string(cacheSource)], at: at(40),
                 output: "File created successfully."),
            call("offline-edit-service", "Edit", .fileEdit, ["file_path": path("Sources/Tidecast/Forecast/ForecastService.swift"),
                                                             "old_string": .string(serviceOld), "new_string": .string(serviceNew)], at: at(55),
                 output: "The file has been updated."),
            call("offline-edit-view", "Edit", .fileEdit, ["file_path": path("Sources/Tidecast/Forecast/ForecastView.swift"),
                                                          "old_string": .string(viewOld), "new_string": .string(viewNew)], at: at(68),
                 output: "The file has been updated."),
            call("offline-write-tests", "Write", .fileWrite, ["file_path": path("Tests/TidecastTests/ForecastCacheTests.swift"),
                                                              "content": .string(testsSource)], at: at(80),
                 output: "File created successfully."),
            call("offline-test", "Bash", .bash, ["command": "swift test", "description": "Run the test suite"], at: at(96),
                 output: "Test Suite 'All tests' passed.\n    Executed 51 tests, with 0 failures (0 unexpected) in 1.208 seconds"),
            .agentMessage(.init(id: "offline-answer", createdAt: at(130), text: finalReply)),
        ]
    }

    static func flakyTest() -> [Item] {
        let t = ago(minutes: 9)
        func at(_ seconds: Double) -> Double { t + seconds * 1000 }
        let root = "\(pantry)/src"
        return [
            .userMessage(.init(id: "flaky-user", createdAt: t, content: [.text(.init(text:
                "`signIn.test.ts` fails about one run in five on CI, always on “refreshes an expired token”. Find out why."))])),
            call("flaky-read-test", "Read", .fileRead, ["file_path": .string("\(root)/auth/signIn.test.ts")], at: at(5)),
            call("flaky-read-session", "Read", .fileRead, ["file_path": .string("\(root)/auth/session.ts")], at: at(8)),
            call("flaky-grep", "Grep", .grep, ["pattern": "Date.now\\(\\)", "path": .string(root)], at: at(12),
                 output: "src/auth/session.ts:41\nsrc/auth/token.ts:17"),
            .agentMessage(.init(id: "flaky-note", createdAt: at(30), text:
                "The token's expiry is checked against `Date.now()` in two places that can straddle a millisecond boundary, so the test only fails when the clock ticks between them. I'd like to confirm it by running the test 200 times with a fixed clock.")),
            call(flakyCallID, "Bash", .bash, ["command": .string(flakyCommand), "description": "Run the test 200 times"], at: at(34), status: .pending),
        ]
    }

    static let flakyCallID = "flaky-repeat"
    static let flakyCommand = "npx vitest run src/auth/signIn.test.ts --repeat 200 --sequence.seed=42"

    static func permission(threadID: String) -> PermissionRequestParams {
        .init(threadId: threadID, requestId: "showcase-permission", toolUseId: flakyCallID, toolName: "Bash",
              input: ["command": .string(flakyCommand), "description": "Run the test 200 times"],
              title: "Allow Claude to run this command?")
    }

    // MARK: The Diff tab

    static func gitStatus(cwd: String) -> JSONValue {
        guard cwd == tidecast else { return ["isRepo": true, "branch": "main", "files": []] }
        return ["isRepo": true, "branch": "offline-forecasts", "files": [
            ["status": "M", "path": "Sources/Tidecast/Forecast/ForecastService.swift"],
            ["status": "M", "path": "Sources/Tidecast/Forecast/ForecastView.swift"],
            ["status": "??", "path": "Sources/Tidecast/Forecast/ForecastCache.swift"],
            ["status": "??", "path": "Tests/TidecastTests/ForecastCacheTests.swift"],
        ]]
    }

    /// The working tree as `git/changes` says it: two files edited, two new ones.
    static func gitChanges(cwd: String) -> GitChangesResult {
        guard cwd == tidecast else { return GitChangesResult(isRepo: true, root: cwd, branch: "main", files: [], omittedFiles: 0) }
        func lines(_ text: String) -> [String] { text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        func new(_ path: String, _ content: String) -> WorkingFileChange {
            let added = content.split(separator: "\n", omittingEmptySubsequences: false).dropLast(content.hasSuffix("\n") ? 1 : 0)
            return WorkingFileChange(path: path, status: .untracked,
                                     hunks: [DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: added.count,
                                                      lines: added.map { "+" + $0 })],
                                     added: added.count, removed: 0, truncatedLines: 0)
        }
        return GitChangesResult(isRepo: true, root: tidecast, branch: "offline-forecasts", files: [
            new("Sources/Tidecast/Forecast/ForecastCache.swift", cacheSource),
            WorkingFileChange(path: "Sources/Tidecast/Forecast/ForecastService.swift", status: .modified, hunks: [
                DiffHunk(oldStart: 3, oldLines: 10, newStart: 3, newLines: 18, lines: lines("""
                 struct ForecastService {
                     let client: WeatherClient
                +    var cache: ForecastCache = .shared
                 
                     func forecast(for location: Location) async throws -> Forecast {
                -        try await client.forecast(for: location)
                +        do {
                +            let fresh = try await client.forecast(for: location)
                +            try? await cache.store(fresh, for: location)
                +            return fresh
                +        } catch let error as URLError where error.isOffline {
                +            guard let saved = try await cache.load(for: location) else { throw error }
                +            return saved.marked(stale: true)
                +        }
                     }
                 }
                """), header: "import Foundation"),
            ], added: 9, removed: 1, truncatedLines: 0),
            WorkingFileChange(path: "Sources/Tidecast/Forecast/ForecastView.swift", status: .modified, hunks: [
                DiffHunk(oldStart: 8, oldLines: 6, newStart: 8, newLines: 12, lines: lines("""
                         VStack(alignment: .leading, spacing: 4) {
                             Text(forecast.location.name)
                                 .font(.largeTitle.bold())
                +            if forecast.isStale {
                +                Label("Updated \\(forecast.fetchedAt, format: .relative(presentation: .named))",
                +                      systemImage: "wifi.slash")
                +                    .font(.subheadline)
                +                    .foregroundStyle(.secondary)
                +            }
                             TideChart(tides: forecast.tides)
                         }
                         .padding()
                """), header: "struct ForecastView: View {"),
            ], added: 6, removed: 0, truncatedLines: 0),
            new("Tests/TidecastTests/ForecastCacheTests.swift", testsSource),
        ], omittedFiles: 0)
    }

    static let searchablePaths = [
        "Sources/Tidecast/Forecast/ForecastView.swift", "Sources/Tidecast/Forecast/ForecastService.swift",
        "Sources/Tidecast/Forecast/ForecastCache.swift", "Sources/Tidecast/Forecast/ForecastModel.swift",
        "Sources/Tidecast/TidecastApp.swift", "Sources/TidecastWidget/TodayProvider.swift",
        "Tests/TidecastTests/ForecastCacheTests.swift", "README.md",
    ]

    // MARK: A reply streamed live

    /// Whatever was asked, the background refresh the last reply offered: calls that run and
    /// finish a moment later, then Markdown a few characters a frame, each notification numbered from
    /// `firstSeq`.
    static func liveReply(threadID: String, turn: Int, firstSeq: Int) -> [(String, JSONValue)] {
        let base = now
        var seq = firstSeq
        var out: [(String, JSONValue)] = []
        func next() -> Int { seq += 1; return seq - 1 }
        let calls: [Item] = [
            call("live-\(turn)-read-app", "Read", .fileRead, ["file_path": path("Sources/Tidecast/TidecastApp.swift")], at: base,
                 output: "1\timport SwiftUI\n2\timport BackgroundTasks"),
            call("live-\(turn)-read-plist", "Read", .fileRead, ["file_path": path("Sources/Tidecast/Info.plist")], at: base + 1),
            call("live-\(turn)-edit-app", "Edit", .fileEdit, ["file_path": path("Sources/Tidecast/TidecastApp.swift"),
                                                              "old_string": .string("        WindowGroup {\n            RootView()\n        }"),
                                                              "new_string": .string(liveCode)], at: base + 2,
                 output: "The file has been updated."),
            call("live-\(turn)-build", "Bash", .bash, ["command": "xcodebuild -scheme Tidecast -quiet build", "description": "Build the app"],
                 at: base + 3, output: "** BUILD SUCCEEDED **"),
        ]
        for item in calls {
            guard case .toolCall(var running) = item else { continue }
            running.status = .running
            running.outputText = nil
            out.append(("item/started", json(ItemStartedNotification(threadId: threadID, seq: next(), item: .toolCall(running)))))
            for _ in 0..<(running.kind == .bash ? 70 : 25) {
                out.append(("item/toolCall/progress", json(ItemToolCallProgressNotification(
                    threadId: threadID, seq: next(), itemId: running.id, elapsedSeconds: 0.1))))
            }
            out.append(("item/completed", json(ItemCompletedNotification(threadId: threadID, seq: next(), item: item))))
        }
        let answerID = "live-\(turn)-answer"
        out.append(("item/started", json(ItemStartedNotification(threadId: threadID, seq: next(), item:
            .agentMessage(.init(id: answerID, createdAt: base + 4, text: ""))))))
        var rest = Substring(liveAnswer)
        while !rest.isEmpty {
            out.append(("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                threadId: threadID, seq: next(), itemId: answerID, delta: String(rest.prefix(5))))))
            rest = rest.dropFirst(5)
        }
        out.append(("item/completed", json(ItemCompletedNotification(threadId: threadID, seq: next(), item:
            .agentMessage(.init(id: answerID, createdAt: base + 4, text: liveAnswer))))))
        return out
    }

    static let liveCode = """
            WindowGroup {
                RootView()
            }
            .backgroundTask(.appRefresh("forecast.refresh")) {
                await ForecastRefresher.shared.refreshSavedLocations()
                await ForecastRefresher.shared.scheduleNext()
            }
    """

    static let liveAnswer = """
    Added a background refresh. Tidecast now asks for an app refresh about every 30 minutes, and \
    each one fetches the saved locations' forecasts into the cache, so what you see offline is \
    rarely more than an hour old.

    ```swift
    .backgroundTask(.appRefresh("forecast.refresh")) {
        await ForecastRefresher.shared.refreshSavedLocations()
        await ForecastRefresher.shared.scheduleNext()
    }
    ```

    - `forecast.refresh` is registered in **Info.plist** under *Permitted background task scheduler identifiers*.
    - The system decides when it actually runs; Low Power Mode and rarely used apps get fewer refreshes.

    The app builds. To try it, run *Simulate Background Fetch* from Xcode's Debug menu.
    """
}

// MARK: The Tasks tab

extension ShowcaseTranscript {
    /// The review chat's work beyond the `tasks` scenario's: more agents, one with an agent of its
    /// own, background commands and a monitor, running, finished and failed, so Tasks is busy.
    static func reviewItems() -> [Item] {
        let clock = TaskClock()
        let root = "\(sundown)/SundownKit/Sources/SundownUI/"
        return [
            clock.call("agent-tests", "Task", .subagent, [
                "subagent_type": "general-purpose", "description": "Write tests for TaskNode.tree",
                "prompt": "Write tests for TaskNode.tree covering nested agents and orphaned commands.",
            ], output: "Added 9 tests to TaskTreeTests; all pass.", at: 640),
            clock.call("bg-lint", "Bash", .bash, ["command": "swiftlint --strict", "run_in_background": true],
                       output: "Command running in background", at: 520),
            clock.call("agent-a11y", "Task", .subagent, [
                "subagent_type": "Explore", "description": "Audit VoiceOver labels in Tasks",
                "prompt": "Check that every status in the Tasks tab is said in words, not only by color.",
            ], status: .running, at: 260),
            clock.call("agent-a11y-grep", "Grep", .grep, ["pattern": "accessibilityLabel", "path": .string(root + "Panes")],
                       output: "TasksPane.swift:212\nTaskTree.swift:88", parent: "agent-a11y", at: 250),
            clock.call("agent-a11y-dot", "Task", .subagent, [
                "description": "Check TaskStateDot's label", "prompt": "Read TaskStateDot and say what VoiceOver reads for each state.",
            ], status: .running, parent: "agent-a11y", at: 120),
            clock.call("agent-perf", "Task", .subagent, [
                "subagent_type": "general-purpose", "description": "Profile scrolling a long chat",
                "prompt": "Record a SwiftUI trace while scrolling the performance scenario's long chat.",
            ], status: .running, at: 180),
            clock.call("bg-trace", "Bash", .bash, [
                "command": "xcrun xctrace record --template SwiftUI --time-limit 30s --launch Sundown.app",
                "run_in_background": true,
            ], output: "Command running in background", parent: "agent-perf", at: 150),
        ]
    }

    /// A chat's tasks as the daemon sends them: the review chat's, the `tasks` scenario's and its
    /// own; none for the others.
    static func tasks(of threadID: String) -> [TaskState] {
        guard threadID == reviewThreadID else { return [] }
        let clock = TaskClock()
        return TaskTranscript.tasks() + [
            TaskState(id: "agent-tests", toolUseId: "agent-tests", taskId: "task-tests", kind: .agent, taskType: "local_agent",
                      title: "Write tests for TaskNode.tree", status: .done, startedAt: clock.ago(640),
                      summary: "Added 9 tests to TaskTreeTests; all pass.",
                      usage: .init(durationMs: 184_000, totalTokens: 41_200, toolUses: 23)),
            TaskState(id: "bg-lint", toolUseId: "bg-lint", taskId: "task-lint", kind: .command, taskType: "local_bash",
                      title: "swiftlint --strict", status: .done, startedAt: clock.ago(520), backgrounded: true,
                      summary: "No violations.", usage: .init(durationMs: 38_000)),
            TaskState(id: "agent-a11y", toolUseId: "agent-a11y", taskId: "task-a11y", kind: .agent, taskType: "local_agent",
                      title: "Audit VoiceOver labels in Tasks", status: .running, startedAt: clock.ago(260)),
            TaskState(id: "agent-a11y-dot", parentId: "agent-a11y", toolUseId: "agent-a11y-dot", taskId: "task-a11y-dot",
                      kind: .agent, taskType: "local_agent", title: "Check TaskStateDot's label", status: .running,
                      startedAt: clock.ago(120)),
            TaskState(id: "agent-perf", toolUseId: "agent-perf", taskId: "task-perf", kind: .agent, taskType: "local_agent",
                      title: "Profile scrolling a long chat", status: .running, startedAt: clock.ago(180)),
            TaskState(id: "bg-trace", parentId: "agent-perf", toolUseId: "bg-trace", taskId: "task-trace", kind: .command,
                      taskType: "local_bash", title: "xcrun xctrace record --template SwiftUI", status: .running,
                      startedAt: clock.ago(150), backgrounded: true),
            TaskState(id: "task:task-daemon-log", taskId: "task-daemon-log", kind: .monitor, taskType: "monitor",
                      title: "Tail the daemon's log for errors", status: .running, startedAt: clock.ago(100)),
        ]
    }
}
