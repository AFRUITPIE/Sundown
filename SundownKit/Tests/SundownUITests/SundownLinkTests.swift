import Foundation
import Testing
@testable import SundownUI

@MainActor
@Suite
struct SundownLinkTests {
    private nonisolated static let host = UUID()

    @Test(arguments: [
        SundownLink.chat(host: host, thread: "abc-123"),
        .newChat(),
        .newChat(host: host, folder: "~/Code/my app", prompt: "Fix the build & run tests", sendToken: UUID()),
    ])
    func linksRoundTripThroughTheirURL(link: SundownLink) {
        #expect(SundownLink(link.url) == link)
    }

    @Test func otherURLsAreNotLinks() {
        #expect(SundownLink(URL(string: "https://claude.ai/chat")!) == nil)
        #expect(SundownLink(URL(string: "sundown://settings")!) == nil)
        #expect(SundownLink(URL(string: "sundown://chat?thread=abc")!) == nil)
    }

    /// A link from outside the app can fill in New Chat but never send: a token is good only if
    /// this process made it, and only once.
    @Test func onlyATokenFromThisProcessSendsAndOnlyOnce() {
        #expect(!SundownLink.redeem(nil))
        #expect(!SundownLink.redeem(UUID()))
        let token = SundownLink.authorizeSend()
        #expect(SundownLink.redeem(token))
        #expect(!SundownLink.redeem(token))
    }
}
