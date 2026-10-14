import Testing
import TetherProtocol
@testable import SundownKit

/// Waits for what the notification pump does on its own time. A timeout is recorded at the call
/// site and ends the test, rather than letting it run on against state that never arrived.
func eventually(
    isolation: isolated (any Actor)? = #isolation,
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(10),
    fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column,
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting for a condition",
                         sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
            throw EventuallyTimedOut()
        }
        try await Task.sleep(for: interval)
    }
}

struct EventuallyTimedOut: Error {}

// Test-only views of the enums' cases, so a test can `try #require` one rather than `guard case`.

extension Item {
    var toolCall: ToolCall? { if case .toolCall(let call) = self { call } else { nil } }
    var agentMessage: AgentMessage? { if case .agentMessage(let message) = self { message } else { nil } }
}

extension TranscriptRow {
    var item: Item? { if case .item(let item) = self { item } else { nil } }
    var toolGroup: [Item.ToolCall]? { if case .toolGroup(let calls) = self { calls } else { nil } }
    var turnWork: (rows: [TranscriptRow], durationMs: Double?)? {
        if case .turnWork(_, let rows, let durationMs) = self { (rows, durationMs) } else { nil }
    }
}

extension ServerRequest {
    var permissionRequest: PermissionRequestParams? { if case .permissionRequest(let p) = self { p } else { nil } }
    var unknown: (method: String, params: JSONValue)? { if case .unknown(let method, let params) = self { (method, params) } else { nil } }
}

extension ServerNotification {
    var itemAgentMessageDelta: ItemAgentMessageDeltaNotification? {
        if case .itemAgentMessageDelta(let delta) = self { delta } else { nil }
    }
    var unknown: (method: String, params: JSONValue)? { if case .unknown(let method, let params) = self { (method, params) } else { nil } }
}

extension HostConnection.State {
    var failure: String? { if case .failed(let message) = self { message } else { nil } }
}

/// Observation's `onChange` is `@Sendable`, so the flag it sets needs a reference to live in.
final class Changed: @unchecked Sendable {
    var happened = false
}
