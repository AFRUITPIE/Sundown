import Foundation
import Synchronization
import SundownKit
import TetherProtocol

/// The app's hosts for XCTest UI runs: each connection a `FakeHost` serving a scenario, in-process.
/// In every build, inert unless the app is launched with SUNDOWN_UI_TEST_MODE=1: the performance
/// tests run against a Release build. Methods a scenario doesn't answer are errors, never Claude.
public enum UITestFixture {
    public static let threadID = "fixture-thread"
    /// The chat the `showcase` scenario opens on.
    public static let showcaseThreadID = ShowcaseTranscript.mainThreadID

    /// The scenario SUNDOWN_UI_TEST_SCENARIO names for `host`: `prompts` and `performance` are
    /// this Mac's alone, the other host showing the short chat; `tasks` and `showcase` are every
    /// host's. SUNDOWN_UI_TEST_FAIL=a,b answers those methods with an error.
    public static func launchScenario(for host: HostConfig, environment: [String: String] = ProcessInfo.processInfo.environment)
        -> FixtureScenario {
        let local = host.id == HostConfig.local.id
        var scenario: FixtureScenario = switch environment["SUNDOWN_UI_TEST_SCENARIO"] {
        case "prompts" where local: .prompts
        case "performance" where local: .performance
        case "tasks": .tasks
        case "showcase": .showcase
        default: .standard
        }
        scenario.failing = Set((environment["SUNDOWN_UI_TEST_FAIL"] ?? "").split(separator: ",").map(String.init))
        return scenario
    }

    /// `host`'s connection in a launch: SUNDOWN_UI_TEST_SCENARIO's scenario; under `connect-failure`
    /// this Mac fails its first two attempts, which keep the status card up for a few seconds of
    /// retries, long enough to press its Reconnect; and with SUNDOWN_UI_TEST_GAP=1 every connection
    /// after the first is to a daemon that lost the stream, so resubscribing reports a replay gap and
    /// the chat reloads (sleep, a daemon restart). The showcase never reports one.
    @MainActor
    public static func launchConnection(host: HostConfig = .local,
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> HostConnection {
        let name = environment["SUNDOWN_UI_TEST_SCENARIO"]
        return connection(host: host, scenario: launchScenario(for: host, environment: environment),
                          failedConnects: host.id == HostConfig.local.id && name == "connect-failure" ? 2 : 0,
                          gapsAfterFirst: environment["SUNDOWN_UI_TEST_GAP"] == "1" && name != "showcase")
    }

    /// A connection to a fixture host serving `scenario`, afresh on each connection: `failedConnects`
    /// attempts fail before one succeeds, and with `gapsAfterFirst` each one after the first that
    /// succeeds reports a replay gap.
    @MainActor
    public static func connection(host: HostConfig = .local, scenario: FixtureScenario = .standard, failedConnects: Int = 0,
                                  gapsAfterFirst: Bool = false) -> HostConnection {
        let attempts = Mutex(0)
        return HostConnection(host: host, transportProvider: { _ in
            let attempt = attempts.withLock { n in n += 1; return n }
            if attempt <= failedConnects {
                throw TransportError.launchFailed("Fixture connection unavailable")
            }
            var scenario = scenario
            scenario.reportsGap = gapsAfterFirst && attempt > failedConnects + 1
            return try fixtureHost(scenario).connect()
        })
    }

    /// A host serving `scenario`, as the fixture's hosts are: it calls itself tether-fixture, on
    /// fixture-host.
    public static func fixtureHost(_ scenario: FixtureScenario) -> FakeHost {
        let host = FakeHost(unscripted: "Unexpected fixture method")
        host.initializeResult = InitializeResult(
            serverInfo: .init(name: "tether-fixture", version: "1"), protocolVersion: tetherProtocolVersion,
            host: .init(hostname: "fixture-host", platform: "darwin", arch: "arm64", home: "/tmp", pid: 1, mode: .daemon),
            claude: .init(path: "/fixture/claude", version: "fixture"))
        host.serve(scenario)
        return host
    }
}
