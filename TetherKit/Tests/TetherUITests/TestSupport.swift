import Testing
import TetherProtocol
@testable import TetherUI

/// Waits for what the app does on its own time. A timeout is recorded at the call site and ends
/// the test, rather than letting it run on against state that never arrived.
func eventually(
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

struct EventuallyTimedOut: Error {}

// Test-only views of the enums' cases, so a test can `try #require` one rather than `guard case`.

extension Composer.Attachment.Kind {
    var image: (base64: String, mediaType: UserInput.Image.MediaType)? {
        if case .image(let base64, let mediaType) = self { (base64, mediaType) } else { nil }
    }
    var text: (content: String, name: String)? {
        if case .text(let content, let name) = self { (content, name) } else { nil }
    }
}

extension Composer.Prepared {
    var attachment: Composer.Attachment? { if case .attachment(let attachment) = self { attachment } else { nil } }
    var mention: String? { if case .mention(let path) = self { path } else { nil } }
}
