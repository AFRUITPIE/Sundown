import Foundation
import os

/// Signposts, for Instruments (the os_signpost instrument; Launch and Chat Switch also in Points of
/// Interest) and the performance UI tests' `XCTOSSignpostMetric`, and the connection log's `Logger`,
/// for Console and `log stream`. One subsystem; the tests and saved Instruments setups name the
/// categories and names below, so they don't change casually. A signpost costs next to nothing while
/// nothing records it.
///
/// - Connection: Connect, an attempt, with Bootstrap, Handshake and Catalog events in it.
/// - RPC: RPC, one request, with its method as the message.
/// - Transcript: History Load (a chat's last page read and subscribed), Older Page, Reply (a turn, as
///   an animation interval, so Instruments gives the hitch rate while it streams), and a Flush event
///   per coalesced batch of deltas, with its size.
/// - PointsOfInterest: Launch (`applicationDidFinishLaunching` until the first window's chat is on
///   hand) and Chat Switch (a window choosing a chat until its transcript is on hand).
public enum Signposts {
    public static let subsystem = "com.haydenhong.Sundown"

    static let connection = OSSignposter(subsystem: subsystem, category: "Connection")
    static let requests = OSSignposter(subsystem: subsystem, category: "RPC")
    static let transcript = OSSignposter(subsystem: subsystem, category: "Transcript")
    /// What a person waits for, in the lane the Time Profiler, SwiftUI and hitch templates show.
    static let pointsOfInterest = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// Each host's connection log, as its Connection Log window shows it.
    public static let connectionLog = Logger(subsystem: subsystem, category: "Connection")
    /// The transcript's own reports: when it found itself showing no rows, and what had just
    /// happened to the chat's items. Errors, so they're kept: `log show --predicate
    /// 'subsystem == "com.haydenhong.Sundown" AND category == "Transcript"'`.
    public static let transcriptLog = Logger(subsystem: subsystem, category: "Transcript")

    static func begin(_ signposter: OSSignposter, _ name: StaticString, _ message: String) -> SignpostInterval {
        let id = signposter.makeSignpostID()
        return SignpostInterval(signposter: signposter, name: name, id: id,
                                state: signposter.beginInterval(name, id: id, "\(message, privacy: .public)"))
    }
}

/// An interval that has begun. End it exactly once: os traps a second end in a debug build.
public struct SignpostInterval: Sendable {
    fileprivate let signposter: OSSignposter
    fileprivate let name: StaticString
    fileprivate let id: OSSignpostID
    fileprivate let state: OSSignpostIntervalState

    /// A moment inside the interval, grouped with it in Instruments.
    public func event(_ event: StaticString) { signposter.emitEvent(event, id: id) }
    public func end() { signposter.endInterval(name, state) }
    public func end(_ note: String) { signposter.endInterval(name, state, "\(note, privacy: .public)") }
}

// MARK: connection

extension Signposts {
    /// One connection attempt to `host`, until its catalog is loaded or it fails.
    static func connect(_ host: String) -> SignpostInterval { begin(connection, "Connect", host) }

    static func rpc(_ method: String) -> SignpostInterval { begin(requests, "RPC", method) }

    /// A line of `host`'s connection log: attempts, connections and failures at notice level, which
    /// the system keeps; the rest (bootstrap's progress) at debug. Public: nothing in the log is
    /// secret (a host's environment never goes into it), and it's there to be read.
    static func log(_ line: String, host: String) {
        let notable = line.hasPrefix("$ ") || line.hasPrefix("Connected") || line.hasPrefix("Disconnected")
            || line.localizedCaseInsensitiveContains("failed")
        connectionLog.log(level: notable ? .default : .debug, "\(host, privacy: .public): \(line, privacy: .public)")
    }
}

// MARK: transcript

extension Signposts {
    static func historyLoad(_ threadID: String) -> SignpostInterval { begin(transcript, "History Load", threadID) }
    static func olderPage(_ threadID: String) -> SignpostInterval { begin(transcript, "Older Page", threadID) }

    /// One per batch the client hands over (a frame at most while a reply streams): how many
    /// notifications went in together.
    static func flushed(_ count: Int) { transcript.emitEvent("Flush", "\(count) notifications") }

    /// Open Reply intervals, by thread.
    @MainActor private static var replies: [String: SignpostInterval] = [:]

    /// A turn started in `thread`. An animation interval, so Instruments reports the hitch rate of
    /// the frames its reply streams into. One per thread: a start without an end (the end was lost
    /// with a gap) ends the earlier one.
    @MainActor static func replyStarted(in thread: ThreadModel) {
        replies.removeValue(forKey: thread.id)?.end("Superseded")
        let id = transcript.makeSignpostID(from: thread)
        replies[thread.id] = SignpostInterval(signposter: transcript, name: "Reply", id: id,
                                              state: transcript.beginAnimationInterval("Reply", id: id))
    }

    @MainActor static func replyEnded(in thread: ThreadModel) {
        replies.removeValue(forKey: thread.id)?.end()
    }
}

// MARK: launch and chat switches

extension Signposts {
    @MainActor private static var chatSwitch: (threadID: String, interval: SignpostInterval)?

    /// A window chose `threadID`, until its transcript is on hand (`chatReady`). A switch made before
    /// the last one finished ends that one.
    @MainActor public static func chatSwitchBegan(to threadID: String) {
        chatSwitch?.interval.end("Superseded")
        chatSwitch = (threadID, begin(pointsOfInterest, "Chat Switch", threadID))
    }

    /// `threadID`'s transcript is on hand: loaded, found already loaded, or failed to load. Ends a
    /// switch to it, and the launch if it's the first. Nil: a window started on New Chat, which has
    /// nothing to load.
    @MainActor public static func chatReady(_ threadID: String?) {
        if let threadID, let pending = chatSwitch, pending.threadID == threadID {
            chatSwitch = nil
            pending.interval.end()
        }
        endLaunch(threadID == nil ? "New Chat" : "Chat")
    }

    @MainActor private static var launch: SignpostInterval?
    @MainActor private static var launchEnded = false
    /// What was ready before the launch began: a window can start on New Chat before
    /// `applicationDidFinishLaunching`.
    @MainActor private static var readyEarly: String?
    @MainActor private static var launchWaiters: [CheckedContinuation<Void, Never>] = []

    /// From `applicationDidFinishLaunching` until the first window's chat is on hand, or at most
    /// `timeLimit`: a host that doesn't connect mustn't leave the launch open.
    @MainActor public static func launchBegan(timeLimit: Duration = .seconds(30)) {
        guard launch == nil, !launchEnded else { return }
        launch = begin(pointsOfInterest, "Launch", "")
        if let readyEarly { return endLaunch(readyEarly) }
        Task { try? await Task.sleep(for: timeLimit); endLaunch("Timed Out") }
    }

    @MainActor private static func endLaunch(_ how: String) {
        guard let interval = launch else {
            if !launchEnded, readyEarly == nil { readyEarly = how }
            return
        }
        launch = nil
        launchEnded = true
        interval.end(how)
        for waiter in launchWaiters { waiter.resume() }
        launchWaiters = []
    }

    /// Returns once the launch has ended, for MetricKit's extended launch.
    @MainActor public static func launchFinished() async {
        guard launch != nil else { return }
        await withCheckedContinuation { launchWaiters.append($0) }
    }
}
