import Testing

/// Waits for what the app does on its own time. A timeout is recorded at the call site and ends
/// the test, rather than letting it run on against state that never arrived.
public func eventually(
    isolation: isolated (any Actor)? = #isolation,
    timeout: Duration = .seconds(3),
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

public struct EventuallyTimedOut: Error {}
