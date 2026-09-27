import SwiftUI

/// Streamed text fading in as it arrives: each piece that lands is drawn at rising opacity for a
/// moment, so a reply's words appear rather than pop. Opacity only, with no movement, so it suits
/// Reduce Motion as it is.
///
/// Only the block at the end of a streaming reply uses it, since only it grows, and it redraws per
/// frame only while something is still fading.
struct ArrivingText: View {
    let text: AttributedString
    /// Whether the text already there when the view appears is arriving too: true for a block that
    /// appears while its reply streams, false for one drawn again after scrolling back to it.
    var arrives = false
    @State private var arrivals = Arrivals()
    /// Bumped when the last piece has finished fading, to draw once more without the clock.
    @State private var settled = 0

    var body: some View {
        let _ = settled
        let now = Date.timeIntervalSinceReferenceDate
        let pieces = arrivals.text(for: text, at: now, arrives: arrives)
        TimelineView(.animation(paused: !arrivals.isFading(at: now))) { context in
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

        let chars = text.characters
        func index(_ offset: Int) -> AttributedString.Index {
            chars.index(chars.startIndex, offsetBy: min(offset, count))
        }
        var result = Text(AttributedString(text[text.startIndex..<index(first.start)]))
        for (i, piece) in pieces.enumerated() {
            let end = i + 1 < pieces.count ? pieces[i + 1].start : count
            let part = Text(AttributedString(text[index(piece.start)..<index(end)]))
                .customAttribute(Arrival(at: piece.at))
            result = Text("\(result)\(part)")
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
