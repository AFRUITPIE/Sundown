import SwiftUI
import SundownKit

/// Where the reader is, and taking them places: the scroll geometry as it changes, the place kept
/// across changes to the rows, the end followed, the rows built near the view, Find, Previous and
/// Next Prompt, and older pages as the reader nears the top.
extension TranscriptModel {
    /// What the scroll geometry says, as last seen.
    struct ViewGeometry: Equatable {
        var offset: CGFloat = 0
        var visibleTop: CGFloat = 0
        var visibleBottom: CGFloat = 0
        var content: CGFloat = 0
        var container = CGSize.zero
        /// The scroll view's top inset (the toolbar's), which `ScrollPosition.scrollTo(y:)` counts from.
        var contentInsetTop: CGFloat = 0
        var height: CGFloat { visibleBottom > visibleTop ? visibleBottom - visibleTop : 800 }
        /// From the content offset to the top of what's visible: the toolbar's inset.
        var insetTop: CGFloat { visibleTop - offset }
    }

    enum Place {
        case end
        /// A settled row at the top of the view, with the first item it shows (to find it again
        /// folded into another), how far down it the view's top is, and how tall the row was then:
        /// if its height has changed since (its text wrapping at a new width), the view's top is as
        /// far down it in proportion, so the reader stays at the same text of a long reply rather
        /// than the same number of points into it.
        case row(id: String, item: String?, offset: CGFloat, height: CGFloat)
        /// Elsewhere: the view's top, from the live turn's top, or from the content's.
        case live(CGFloat)
        case top(CGFloat)
    }

    var historyTop: CGFloat { Self.topPadding + (showsOlder ? Self.olderRowHeight + Self.spacing : 0) }
    var liveTop: CGFloat { historyTop + index.total }

    /// Where the reader is.
    func place() -> Place {
        guard ready, !following else { return .end }
        let y = view.visibleTop - historyTop
        // Above the rows (at the older-history row): kept by the first row, as far below.
        if y < 0 { return settled.first.map { .row(id: $0.id, item: $0.row.firstItemID, offset: y, height: 0) } ?? .top(view.visibleTop) }
        if y >= index.total { return .live(view.visibleTop - liveTop) }
        guard let (i, offset) = index.anchor(at: y) else { return .top(view.visibleTop) }
        return .row(id: settled[i].id, item: settled[i].row.firstItemID, offset: offset, height: index.height(i))
    }

    /// Back to `place`, with whatever changed above it.
    func restore(_ place: Place) {
        switch place {
        case .end: goToEnd(reader: false, moved: true)
        case .top(let y): scroll(toVisibleTop: y, keeping: true)
        case .live(let o): scroll(toVisibleTop: liveTop + o, keeping: true)
        case .row(let id, let item, var offset, let was):
            let i = index.index(of: id) ?? item.flatMap { item in settled.firstIndex { $0.row.holds(itemID: item) } }
            guard let i else {
                Signposts.transcriptLog.error("Transcript lost the reader's row; went to the end")
                goToEnd(reader: false)
                return
            }
            let now = index.height(i)
            if offset > 0, was > 0, abs(now - was) >= 0.5 { offset *= now / was }
            scroll(toVisibleTop: historyTop + index.top(i) + min(offset, now), keeping: true)
        }
    }

    /// The view's top to `y`, in the content's coordinates, with the rows there built. `keeping`:
    /// the reader's place after a change to the rows, which the scroll keeper applies too, as it
    /// lands even while the reader's wheel turns.
    func scroll(toVisibleTop y: CGFloat, keeping: Bool = false) {
        following = false
        setWindow(visibleTop: y)
        let offset = y - view.insetTop
        guard abs(offset - view.offset) >= 0.5 else { return }
        // In the same update as the change that moved the rows: SwiftUI lays out both before it
        // draws, so no frame shows the rows moved (checked frame by frame, macOS 27.2, 2026-11).
        // `scrollTo(y:)` counts from below the toolbar's inset.
        landing = offset
        if keeping { keeper?.target = offset }
        scroll { $0.scrollTo(y: offset + self.view.contentInsetTop) }
        // As it will be once laid out, for anything else this update does.
        view.visibleTop += offset - view.offset
        view.visibleBottom += offset - view.offset
        view.offset = offset
    }

    private func setWindow(visibleTop y: CGFloat) {
        let top = y - historyTop
        let w = index.window(for: top...(top + view.height), overscan: view.height)
        if w != window { window = w }
    }

    /// To the end: sending, Jump to Latest, Next Prompt past the last, a chat opening. Followed as
    /// it grows: the bottom edge is the position. `moved`: the rows changed under a reader at the
    /// end, and the edge is asked for again.
    func goToEnd(reader: Bool = true, moved: Bool = false) {
        if reader { lastPrompt = nil }
        following = true
        let w = index.window(for: max(0, index.total - view.height)...index.total, overscan: view.height)
        if w != window { window = w }
        if !edgeArmed || reader || moved { scroll { $0.scrollTo(edge: .bottom) } }
    }

    /// Takes the reader somewhere: a new request for the scroll view.
    func scroll(_ change: (inout ScrollPosition) -> Void) {
        change(&storedPosition)
        edgeArmed = storedPosition.edge == .bottom
        positionRequests &+= 1
    }

    /// The bottom edge again, asked for from a scroll geometry callback: after the layout pass
    /// that called it, and once however many passes ask. Asked from inside the pass, each request
    /// was resolved in that pass, writing the position back and laying the transcript out again,
    /// which called back again: the feedback behind a live resize that never returned (2026-11).
    private func followEndSoon() {
        guard !endPending else { return }
        endPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.endPending = false
            if self.following { self.scroll { $0.scrollTo(edge: .bottom) } }
        }
    }

    /// The scroll geometry, as it changes: the reader scrolling, the rows growing, a resize.
    func scrolled(_ g: ViewGeometry) {
        guard !hidden, ready else { view = g; return }
        let was = view
        view = g
        if let landing {
            // On its way: the reader didn't move, so nothing follows from it yet.
            if abs(g.offset - landing) >= 1, landingSkips < 2 {
                landingSkips += 1
                return
            }
            self.landing = nil
        }
        let atEnd = g.content - g.visibleBottom < 24
        if atEnd {
            arrived = true
            if !following { following = true }
            // Back at the end by scrolling there: followed from now on.
            if !edgeArmed, g.container == was.container { followEndSoon() }
        } else if following, g.offset < was.offset - 0.5, g.container == was.container {
            // Scrolled up, away from the end: the scroll view no longer follows it.
            following = false
            edgeArmed = false
            lastPrompt = nil
        } else if !following, g.offset != was.offset {
            lastPrompt = nil
        }
        // A resize at the end: the bottom edge again, which a new size doesn't keep.
        if following, g.container != was.container { followEndSoon() }
        let far = g.content - g.visibleBottom > g.height
        if far != farFromEnd { farFromEnd = far }
        let top = g.visibleTop - historyTop
        let visible = top...(top + g.height)
        if !index.covers(window, visible, margin: g.height / 3) {
            let w = index.window(for: visible, overscan: g.height)
            if w != window { window = w }
        }
        loadOlderIfNear()
    }

    /// Builds, off the main thread, the text of messages up to two screens beyond the rows built,
    /// into the text views' cache: built in its row as it was mounted, a long reply held up the
    /// scroll that brought it in.
    func buildAhead() {
        guard buildingAhead == nil, let thread, !settled.isEmpty else { return }
        let h = view.height, top = view.visibleTop - historyTop
        let ahead = index.window(for: top...(top + h), overscan: 3 * h)
        var replies: [String] = [], prompts: [String] = []
        for i in ahead where !window.contains(i) {
            switch TextShape(settled[i], thread: thread) {
            case .reply(let text, _): replies.append(text)
            case .prompt(let texts, _): prompts += texts
            case nil: break
            }
        }
        guard !replies.isEmpty || !prompts.isEmpty else { return }
        let metrics = measurer.metrics
        buildingAhead = Task { [weak self] in
            await MarkdownView.prewarm(replies, theme: metrics.theme(.reply))
            await MarkdownView.prewarm(prompts, theme: metrics.theme(.prompt))
            self?.buildingAhead = nil
        }
    }

    // MARK: Going places

    /// Find's current match, in the middle of the view.
    func show(match id: String) {
        lastPrompt = nil
        show(id, centered: true)
    }

    /// Chat ▸ Previous and Next Prompt: the prompt before or after the reader's place to the top;
    /// past the last, Next goes to the end. Before the first prompt held, Previous loads older
    /// pages until one has a prompt.
    func goToPrompt(_ direction: PromptNavigation.Direction) {
        guard let thread else { return }
        if let id = promptTarget(direction) {
            showPrompt(id)
        } else if direction == .next {
            goToEnd()
        } else if thread.hasMoreHistory, let connection {
            Task {
                var waits = 0
                pages: while promptTarget(.previous) == nil, thread.hasMoreHistory, waits < 50 {
                    switch await connection.loadOlderHistory(thread) {
                    case .loaded:
                        // Once its rows are measured and in.
                        await settledHolds(thread.items.first?.id)
                    case .busy:
                        // The page the top asked for is on its way.
                        waits += 1
                        try? await Task.sleep(for: .milliseconds(100))
                    case .failed, .unavailable, .complete: break pages
                    }
                }
                if let id = promptTarget(.previous) { showPrompt(id) }
            }
        }
    }

    /// Waits until the settled rows hold `item`: an older page measured and put in (`commit`).
    private func settledHolds(_ item: String?) async {
        guard let item else { return }
        while !settled.contains(where: { $0.row.holds(itemID: item) }), thread != nil {
            await withCheckedContinuation { commitWaiters.append($0) }
        }
    }

    private func showPrompt(_ id: String) {
        lastPrompt = id
        show(id, centered: false)
    }

    private func show(_ id: String, centered: Bool) {
        guard let (top, height) = frame(of: id) else { return }
        // In what isn't under the toolbar (and Find's bar): the top of that, or its middle.
        let inset = view.contentInsetTop, room = view.height - inset
        let y = centered && height < room ? top - (room - height) / 2 : top
        scroll(toVisibleTop: y - inset)
    }

    /// A row's top and height in the content's coordinates, built or not.
    private func frame(of id: String) -> (CGFloat, CGFloat)? {
        if let i = index.index(of: id) { return (historyTop + index.top(i), index.height(i)) }
        var y = liveTop
        for entry in live {
            let h = liveHeights[entry.id] ?? 0
            if entry.id == id { return (y, h) }
            y += h + Self.spacing
        }
        return nil
    }

    /// The rows the view shows now.
    private func visibleIDs() -> Set<String> {
        let top = view.visibleTop + view.contentInsetTop - historyTop
        var ids = Set(index.rows(from: top, to: view.visibleBottom - historyTop).map { settled[$0].id })
        var y = liveTop
        for entry in live {
            let h = liveHeights[entry.id] ?? 0
            if y + h >= view.visibleTop + view.contentInsetTop, y <= view.visibleBottom { ids.insert(entry.id) }
            y += h + Self.spacing
        }
        return ids
    }

    private func promptTarget(_ direction: PromptNavigation.Direction) -> String? {
        guard let thread else { return nil }
        return PromptNavigation.target(direction, rows: thread.rows(folding), visible: visibleIDs(), lastTarget: lastPrompt)
    }

    /// For VoiceOver's Prompts rotor: the prompt's row brought to the top, built.
    func reveal(_ id: String) { showPrompt(id) }

    // MARK: Older pages

    /// Asks for the page before the rows held once the reader is within a screen of the top, one
    /// page at a time. The page goes in above them with their place kept, which takes them a page
    /// from the top, so the next is asked only as they come up again. After a failure it waits
    /// 2, 4 and 8 s before asking again, then says it couldn't, with Try Again.
    private func loadOlderIfNear() {
        guard let thread, let connection, ready, arrived, thread.historyLoaded, thread.hasMoreHistory, !loadingOlder,
              !olderFailed, connection.state == .connected, view.visibleTop < max(view.height, 400) else { return }
        loadingOlder = true
        Task {
            let outcome = await connection.loadOlderHistory(thread)
            switch outcome {
            case .loaded:
                // Cleared once the page's rows are in (`commit`), so the next waits for the reader.
                olderFailures = 0
            case .failed:
                loadingOlder = false
                olderFailures += 1
                guard olderFailures <= 3 else {
                    olderFailed = true
                    return
                }
                // Asking again at once would likely fail the same way.
                try? await Task.sleep(for: .seconds(1 << olderFailures))
                loadOlderIfNear()
            case .busy, .complete, .unavailable:
                loadingOlder = false
            }
        }
    }

    func retryOlder() {
        olderFailures = 0
        olderFailed = false
        loadOlderIfNear()
    }
}
