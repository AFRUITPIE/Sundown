import AppKit
import SwiftUI
import SundownKit
import TetherProtocol

/// What a row's height is made of when it's a message: its text, laid out by TextKit (off the main
/// thread for a page of rows), and chrome that doesn't depend on the text.
enum TextShape: Equatable {
    /// A reply; `bar`: the turn's actions under it (the room of the hover capsule).
    case reply(String, bar: Bool)
    /// A prompt in its bubble, each text part in turn.
    case prompt([String], queued: Bool)

    /// The message rows whose height is predicted from their text; every other row is measured.
    @MainActor init?(_ entry: TranscriptEntry, thread: ThreadModel) {
        guard case .item(let row) = entry.row else { return nil }
        switch thread.box(for: row).item {
        case .agentMessage(let m):
            self = .reply(m.text, bar: entry.place == nil || entry.place?.isEnd == true)
        case .userMessage(let m) where m.origin != "wakeup" && m.synthetic != true && m.parentToolUseId == nil && m.origin != "workflow":
            let parts = m.content.filter(UserMessageView.draws)
            var texts: [String] = []
            for part in parts {
                guard case .text(let t) = part else { return nil }
                texts.append(t.text)
            }
            guard !texts.isEmpty else { return nil }
            self = .prompt(texts, queued: m.queued == true)
        default:
            return nil
        }
    }

    var style: MarkdownStyle {
        if case .reply = self { .reply } else { .prompt }
    }

    var texts: [String] {
        switch self {
        case .reply(let t, _): [t]
        case .prompt(let ts, _): ts
        }
    }
}

/// How a message row's height follows from its text's, measured once per text size and contrast
/// by SwiftUI itself (`RowMeasurer.calibrate`), so no constant here can drift from the views.
struct MessageChrome: Equatable {
    /// How much narrower than the reading column the text is laid out.
    var replyInset: CGFloat = 0
    var promptInset: CGFloat = 0
    /// Height besides the text: a reply with and without its actions' room, a prompt, and a
    /// queued prompt's note.
    var replyBar: CGFloat = 0
    var replyPlain: CGFloat = 0
    var prompt: CGFloat = 0
    var queued: CGFloat = 0
    /// Between a prompt's parts (`UserMessageView`).
    static let promptPartSpacing: CGFloat = 6
}

/// What a row's height depends on beyond the row and the width.
struct RowMetrics: Equatable {
    var textScale: CGFloat = 1
    var readingWidth: CGFloat = TranscriptWidth.narrow.points
    var increasedContrast = false
    var bodySize: CGFloat = 13
    /// Settings ▸ Wrap Long Lines in Code, which an open tool call's code follows. Not the whole
    /// `Appearance`: its Tool Calls folding changes the rows, not their heights.
    var wrapCode = true

    @MainActor init() {}

    @MainActor init(_ values: EnvironmentValues) {
        textScale = values.textScale
        readingWidth = values.readingWidth
        increasedContrast = values.colorSchemeContrast == .increased
        bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        wrapCode = values.appearance.wrapCode
    }

    func theme(_ style: MarkdownStyle) -> MarkdownTheme {
        MarkdownTheme(style: style, scale: textScale, increasedContrast: increasedContrast)
    }

    /// The reading column's width inside a row `width` wide (`readingColumn`).
    func column(_ width: CGFloat) -> CGFloat { min(width, readingWidth) - 2 * Layout.gutter }
}

/// A message's text height at a width, with its built text: a job for `TextHeights`.
struct TextJob: Sendable {
    let text: String
    let style: MarkdownStyle
    let width: CGFloat
}

/// Text heights off the main thread, a few jobs at a time in parallel.
enum TextHeights {
    /// A message's text as built off the main thread, for the text views' cache.
    struct Built: @unchecked Sendable {
        let text: String
        let theme: MarkdownTheme
        /// Immutable once built.
        let string: NSAttributedString
    }

    /// The jobs' heights, and the built text of the last `keeping` of them (the rows nearest the
    /// reader), which the text views would otherwise build again on the main thread.
    @concurrent
    nonisolated static func heights(_ jobs: [TextJob], scale: CGFloat, increasedContrast: Bool,
                                    keeping: Int = 0) async -> (heights: [CGFloat], built: [Built]) {
        let chunk = max(8, jobs.count / max(2, ProcessInfo.processInfo.activeProcessorCount))
        let kept = jobs.count - keeping
        return await withTaskGroup(of: (Int, [CGFloat], [Built]).self) { group in
            for start in stride(from: 0, to: jobs.count, by: chunk) {
                let slice = Array(jobs[start..<min(start + chunk, jobs.count)])
                group.addTask {
                    var out: [CGFloat] = [], built: [Built] = []
                    out.reserveCapacity(slice.count)
                    for (i, job) in slice.enumerated() {
                        if Task.isCancelled { out.append(0); continue }
                        let theme = MarkdownTheme(style: job.style, scale: scale, increasedContrast: increasedContrast)
                        let string = MarkdownBuilder.build(job.text, theme: theme)
                        out.append(MarkdownNSTextView.predictedHeight(of: string, theme: theme, width: job.width))
                        if start + i >= kept { built.append(Built(text: job.text, theme: theme, string: string)) }
                    }
                    return (start, out, built)
                }
            }
            var all = [CGFloat](repeating: 0, count: jobs.count)
            var built: [Built] = []
            for await (start, part, b) in group {
                all.replaceSubrange(start..<start + part.count, with: part)
                built += b
            }
            return (all, built)
        }
    }

    /// One text, on the main thread: by the view showing it, else laid out here from the text views'
    /// cache of built messages when it's there.
    @MainActor static func height(_ job: TextJob, metrics: RowMetrics) -> CGFloat {
        let theme = metrics.theme(job.style)
        // On screen: its own view lays it out at this width, once, for this and for SwiftUI's
        // sizing that follows; laid out here as well, a resize cost each built message twice.
        if let view = MarkdownView.Coordinator.shown(job.text, theme: theme) { return view.measure(width: job.width).height }
        let built = MarkdownView.Coordinator.built(job.text, theme: theme) ?? MarkdownBuilder.build(job.text, theme: theme)
        return MarkdownNSTextView.predictedHeight(of: built, theme: theme, width: job.width)
    }
}

/// Heights for rows before they're built: a message's from its text and its calibrated chrome, any
/// other row's measured once by SwiftUI in a sizing hosting controller (a tool row, a date, a
/// turn's edits: lines whose height is the view's, not the text's).
@MainActor
final class RowMeasurer {
    private(set) var metrics = RowMetrics()
    private(set) var chrome: MessageChrome?
    /// The transcript's environment, for rows measured here: they inherit none of it.
    var environment = EnvironmentValues()
    /// The transcript's open rows, so a row is measured as it's drawn.
    var expansion: RowExpansion?
    private var sizer: NSHostingController<AnyView>?
    private var sizerUses = 0

    /// New text size, contrast, reading width or tool-call display: chrome measured again.
    func setMetrics(_ new: RowMetrics) -> Bool {
        guard new != metrics else { return false }
        metrics = new
        chrome = nil
        return true
    }

    // MARK: Messages

    func textJobs(_ shape: TextShape, width: CGFloat) -> [TextJob] {
        guard let chrome else { return [] }
        let column = metrics.column(width)
        let w = column - (shape.style == .reply ? chrome.replyInset : chrome.promptInset)
        return shape.texts.map { TextJob(text: $0, style: shape.style, width: w) }
    }

    /// The row's height from its text's.
    func height(_ shape: TextShape, texts: [CGFloat]) -> CGFloat {
        guard let chrome else { return 0 }
        let sum = texts.reduce(0, +)
        switch shape {
        case .reply(_, let bar): return sum + (bar ? chrome.replyBar : chrome.replyPlain)
        case .prompt(let parts, let queued):
            return sum + CGFloat(parts.count - 1) * MessageChrome.promptPartSpacing + chrome.prompt + (queued ? chrome.queued : 0)
        }
    }

    /// The row's height on the main thread: a message's text laid out here, anything else measured.
    func heightNow(_ entry: TranscriptEntry, thread: ThreadModel, width: CGFloat) -> CGFloat {
        if let shape = TextShape(entry, thread: thread), calibrate(thread: thread, width: width) {
            return height(shape, texts: textJobs(shape, width: width).map { TextHeights.height($0, metrics: metrics) })
        }
        return measured(entry, thread: thread, width: width)
    }

    // MARK: Measured rows

    /// The row's height as SwiftUI lays it out at `width`, in the same view the transcript builds.
    func measured(_ entry: TranscriptEntry, thread: ThreadModel, width: CGFloat, probe: MarkdownWidthProbe? = nil) -> CGFloat {
        // The probe inside the transcript's environment, which would otherwise reset it.
        let root = AnyView(TranscriptRowContent(entry: entry, thread: thread)
            .environment(\.markdownWidthProbe, probe)
            .environment(\.rowExpansion, expansion)
            .environment(\.self, environment))
        // A new controller every few dozen rows: one given root view after root view kept more of
        // their observation to undo with each, and measuring a page's rows went quadratic
        // (Every Call's 4480 rows: 10.7 s on one controller, 1.2 s this way; 2026-11).
        sizerUses += 1
        if sizerUses % 50 == 0 { self.sizer = nil }
        let sizer = self.sizer ?? {
            let s = NSHostingController(rootView: root)
            s.sizingOptions = []
            s.safeAreaRegions = []
            self.sizer = s
            return s
        }()
        sizer.rootView = root
        let column = metrics.column(width)
        return Self.rounded(sizer.sizeThatFits(in: CGSize(width: column, height: .greatestFiniteMagnitude)).height)
    }

    static func rounded(_ h: CGFloat) -> CGFloat { max(0, (h * 2).rounded(.up) / 2) }

    // MARK: Calibration

    /// The chrome of a reply and a prompt, from sample rows measured as SwiftUI lays them out at
    /// `width`, less their text as TextKit lays it out. Once per metrics.
    @discardableResult
    func calibrate(thread: ThreadModel, width: CGFloat) -> Bool {
        if chrome != nil { return true }
        guard width >= 200 else { return false }
        let sample = "Calibrating the transcript’s heights"
        let column = metrics.column(width)
        func message(_ item: Item, end: Bool) -> (height: CGFloat, textWidth: CGFloat) {
            let probe = MarkdownWidthProbe()
            let entry = TranscriptEntry(row: .item(item), place: TurnPlace(turn: "calibration", isEnd: end))
            let h = measured(entry, thread: thread, width: width, probe: probe)
            let finite = probe.widths.filter { $0.isFinite && $0 > 0 }
            return (h, finite.max() ?? column)
        }
        var c = MessageChrome()
        let reply = Item.agentMessage(.init(id: "calibration-reply", createdAt: 0, text: sample))
        let withBar = message(reply, end: true)
        let plain = message(reply, end: false)
        let t = TextHeights.height(TextJob(text: sample, style: .reply, width: withBar.textWidth), metrics: metrics)
        c.replyInset = column - withBar.textWidth
        c.replyBar = withBar.height - t
        c.replyPlain = plain.height - t
        let prompt = Item.userMessage(.init(id: "calibration-prompt", createdAt: 0, content: [.text(.init(text: sample))]))
        let p = message(prompt, end: false)
        let tp = TextHeights.height(TextJob(text: sample, style: .prompt, width: p.textWidth), metrics: metrics)
        c.promptInset = column - p.textWidth
        c.prompt = p.height - tp
        let queued = Item.userMessage(.init(id: "calibration-queued", createdAt: 0, content: [.text(.init(text: sample))], queued: true))
        c.queued = message(queued, end: false).height - p.height
        chrome = c
        #if DEBUG
        TranscriptModel.log.debug("Chrome at width \(width): \(String(describing: c), privacy: .public)")
        #endif
        return true
    }
}

/// A row as the transcript builds it and as `RowMeasurer` measures it: the same view, so the two
/// agree. At the transcript's text size, as wide as the reading column its container is (one
/// column around all the rows, as the original transcript had it: one around each row asked a
/// message for its unwrapped size, laying a streamed reply out twice more per delta).
struct TranscriptRowContent: View {
    let entry: TranscriptEntry
    let thread: ThreadModel

    var body: some View {
        TranscriptRowView(row: entry.row, thread: thread, place: entry.place)
            // Set here too, not only by the row's own `transformEnvironment`: in a sizing hosting
            // controller that didn't reach the message, which measured without its actions' room.
            .environment(\.turnPlace, entry.place)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaledFont(.body)
    }
}
