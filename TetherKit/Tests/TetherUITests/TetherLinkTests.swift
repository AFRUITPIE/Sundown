import Foundation
import Testing
@testable import TetherUI

@MainActor
@Suite
struct TetherLinkTests {
    @Test func linksRoundTripThroughTheirURL() {
        let host = UUID()
        let links: [TetherLink] = [
            .chat(host: host, thread: "abc-123"),
            .newChat(),
            .newChat(host: host, folder: "~/Code/my app", prompt: "Fix the build & run tests", sendToken: UUID()),
        ]
        for link in links {
            #expect(TetherLink(link.url) == link)
        }
    }

    @Test func otherURLsAreNotLinks() {
        #expect(TetherLink(URL(string: "https://claude.ai/chat")!) == nil)
        #expect(TetherLink(URL(string: "tether://settings")!) == nil)
        #expect(TetherLink(URL(string: "tether://chat?thread=abc")!) == nil)
    }

    /// A link from outside the app can fill in New Chat but never send: a token is good only if
    /// this process made it, and only once.
    @Test func onlyATokenFromThisProcessSendsAndOnlyOnce() {
        #expect(!TetherLink.redeem(nil))
        #expect(!TetherLink.redeem(UUID()))
        let token = TetherLink.authorizeSend()
        #expect(TetherLink.redeem(token))
        #expect(!TetherLink.redeem(token))
    }
}
