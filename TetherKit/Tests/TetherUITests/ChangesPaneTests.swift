#if DEBUG
import Testing
import TetherKit
@testable import TetherUI

@MainActor
@Suite
struct ChangesPaneTests {
    /// Each file's widest line number is found once, when the changes are read, as its body used to
    /// find it on every update.
    @Test(arguments: [WorkingChanges.sample, .large])
    func widestLineNumbersAreFoundOnce(changes: WorkingChanges) {
        let widest = ChangesPane.widestNumbers(changes)
        for file in changes.files {
            let everyLine = file.hunks.flatMap(\.lines).compactMap { $0.newNumber ?? $0.oldNumber }.max().map(String.init) ?? ""
            #expect(widest[file.id] == everyLine, "\(file.path)")
        }
    }
}
#endif
