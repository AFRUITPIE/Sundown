import SwiftUI

/// Streamed text fading in as it arrives: each piece that lands is drawn at rising opacity for a
/// moment, so a reply's words appear rather than pop. Opacity only, with no movement, so it suits
/// Reduce Motion as it is.
///
/// Only the last block of the reply being streamed into uses it (`ThreadModel.streamingReplyID`),
/// since only it grows; every settled reply, and every code block, is plain text. It redraws only
/// while something is still fading, at most 60 times a second: a fade that short looks the same,
/// and on a 120 Hz display the stream drew twice as often. None of it while the Mac saves energy
/// (`reducesEffects`): the words just appear.
struct ArrivingText: View {
    let text: AttributedString
    /// Whether the text already there when the view appears is arriving too: true for a block that
    /// appears while its reply streams, false for one drawn again after scrolling back to it.
    var arrives = false
    @State private var arrivals = Arrivals()
    /// Bumped when the last piece has finished fading, to draw once more without the clock.
    @State private var settled = 0
    @Environment(\.reducesEffects) private var reducesEffects

    var body: some View {
        if reducesEffects {
            // Kept up to date, so what arrived meanwhile doesn't fade in when the effects come back.
            let _ = arrivals.settle(text)
            Text(text)
        } else {
            fading
        }
    }

    private var fading: some View {
        let _ = settled
        let now = Date.timeIntervalSinceReferenceDate
        let pieces = arrivals.text(for: text, at: now, arrives: arrives)
        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !arrivals.isFading(at: now))) { context in
            pieces.textRenderer(FadeInRenderer(now: context.date.timeIntervalSinceReferenceDate))
        }
        .task(id: arrivals.latest) {
            guard arrivals.latest != nil else { return }
            try? await Task.sleep(for: .seconds(FadeInRenderer.duration))
            if !Task.isCancelled { settled &+= 1 }
        }
    }
}

/// When each piece of one block's text arrived. A class, changed while drawing like
/// `MarkdownCache`: what it records is only ever read back by the same body.
@MainActor
final class Arrivals {
    /// How many characters had arrived as of the last draw; nil before the first.
    private var known: Int?
    /// Pieces still fading: where each starts, in characters, and when it arrived.
    private var pieces: [(start: Int, at: TimeInterval)] = []

    var latest: TimeInterval? { pieces.last?.at }

    /// Everything in `text` has arrived and nothing is fading.
    func settle(_ text: AttributedString) {
        known = text.characters.count
        pieces = []
    }

    func isFading(at now: TimeInterval) -> Bool {
        guard let latest else { return false }
        return now < latest + FadeInRenderer.duration
    }

    /// `text` as one `Text`, its still-fading pieces marked with when they arrived.
    func text(for text: AttributedString, at now: TimeInterval, arrives: Bool) -> Text {
        let count = text.characters.count
        if let known {
            if count > known {
                pieces.append((known, now))
            } else if count < known {
                // Not an append (the block was parsed again differently): nothing is fading.
                pieces = []
            }
        } else if arrives, count > 0 {
            pieces = [(0, now)]
        }
        known = count
        pieces.removeAll { $0.at + FadeInRenderer.duration <= now }
        guard let first = pieces.first else { return Text(text) }

        // Pieces are in order, so each boundary is found from the one before it: one walk over the
        // text, not one from its start per piece.
        let chars = text.characters
        var cursor = chars.startIndex
        var cursorOffset = 0
        func index(_ offset: Int) -> AttributedString.Index {
            let target = min(offset, count)
            cursor = chars.index(cursor, offsetBy: target - cursorOffset)
            cursorOffset = target
            return cursor
        }
        var start = index(first.start)
        var result = Text(AttributedString(text[text.startIndex..<start]))
        for (i, piece) in pieces.enumerated() {
            let end = index(i + 1 < pieces.count ? pieces[i + 1].start : count)
            let part = Text(AttributedString(text[start..<end])).customAttribute(Arrival(at: piece.at))
            result = Text("\(result)\(part)")
            start = end
        }
        return result
    }
}

/// Marks a piece of text with when it arrived, for `FadeInRenderer`.
struct Arrival: TextAttribute {
    let at: TimeInterval
}

/// Draws each piece marked with an `Arrival` at the opacity its age gives it.
struct FadeInRenderer: TextRenderer {
    static let duration: TimeInterval = 0.3
    let now: TimeInterval

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let arrival = run[Arrival.self] else {
                    context.draw(run)
                    continue
                }
                let progress = (now - arrival.at) / Self.duration
                var faded = context
                // Eased out, so a piece is readable almost at once and settles gently.
                faded.opacity = progress >= 1 ? 1 : 1 - pow(1 - max(progress, 0), 2)
                faded.draw(run)
            }
        }
    }
}

#if DEBUG
/// A reply being streamed into: its last block fades new words in, the ones before it are settled.
#Preview("Streaming reply") {
    MarkdownView(text: "Reading how the split view sets its widths.\n\nThe inspector column declares its minimum, so opening it", streams: true)
        .padding()
        .frame(width: 520)
}
#endif
