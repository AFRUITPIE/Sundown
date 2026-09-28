import Testing
import TetherProtocol
@testable import TetherKit

/// The daemon passes on the header of `git status -b` as git wrote it; New Chat's branch chip and
/// the Changes pane show only a branch's name, never git's sentences.
@Suite
struct GitStatusTests {
    private func branch(_ header: String?, isRepo: Bool = true) -> String? {
        GitStatusResult(isRepo: isRepo, branch: header, files: []).branchName
    }

    @Test func aBranchIsItsName() {
        #expect(branch("main") == "main")
        #expect(branch("feature/new-chat") == "feature/new-chat")
    }

    @Test func aNewRepositoryNamesTheBranchItWillHave() {
        #expect(branch("No commits yet on main") == "main")
        #expect(branch("Initial commit on trunk") == "trunk")
    }

    @Test func noBranchToName() {
        #expect(branch("HEAD (no branch)") == nil)
        #expect(branch(nil) == nil)
        #expect(branch("") == nil)
        #expect(branch("main", isRepo: false) == nil)
    }
}
