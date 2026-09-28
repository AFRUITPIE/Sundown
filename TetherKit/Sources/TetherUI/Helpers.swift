import Foundation
import SwiftUI
import TetherKit
import TetherProtocol

extension JSONValue {
    private static let prettyEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    /// Pretty-printed JSON for display.
    var pretty: String {
        (try? String(decoding: Self.prettyEncoder.encode(self), as: UTF8.self)) ?? ""
    }

    func string(_ key: String) -> String? { self[key]?.stringValue }
}

extension String {
    /// Last path component, or the whole string.
    var lastPathComponent: String { (self as NSString).lastPathComponent }

    /// ~-abbreviated path.
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }

    /// A server's own word for a state, as UI text: `notLoaded` → "Not Loaded", `needs-auth` →
    /// "Needs Auth", `task_started` → "Task Started". Statuses reach us as raw strings so that
    /// unknown future ones still display; none of them should reach the user spelled that way.
    var humanized: String {
        var out = ""
        for character in replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") {
            if character.isUppercase, let last = out.last, !last.isWhitespace { out.append(" ") }
            out.append(character)
        }
        return out.capitalized
    }
}

/// How wide the transcript may get. Narrow keeps lines near a comfortable 45–75 characters.
public enum TranscriptWidth: String, CaseIterable, Identifiable, Sendable {
    case narrow, medium, wide

    public var id: Self { self }
    public var label: String { rawValue.capitalized }

    var points: CGFloat {
        switch self {
        case .narrow: return 700
        case .medium: return 900
        case .wide: return 1180
        }
    }
}

extension EnvironmentValues {
    /// The transcript's maximum width, shared with the composer so their edges line up.
    @Entry var readingWidth: CGFloat = TranscriptWidth.narrow.points

    /// What the composer's field starts with. Empty everywhere in the app; previews set it to show
    /// the field with a draft in it, which is otherwise the composer's own private state.
    @Entry var composerDraft: String = ""

    /// Where each chat's unsent text is kept; the shell sets it to the app's store.
    @Entry var composerDrafts = ComposerDrafts()
}

/// The app's per-chat drafts, as the composer reaches them. Compares by the store it points at, so
/// setting it in a body doesn't invalidate every composer.
struct ComposerDrafts: Equatable {
    weak var app: AppModel?

    /// Read when a composer appears; not observed.
    @MainActor func text(for key: String) -> String { app?.draft(for: key) ?? "" }
    @MainActor func set(_ text: String, for key: String) { app?.setDraft(text, for: key) }
    /// Text put in the composer from outside it; observed, and changed only by a delivery.
    @MainActor func delivery(for key: String) -> AppModel.DraftDelivery? { app?.draftDeliveries[key] }

    static func == (a: Self, b: Self) -> Bool { a.app === b.app }
}

enum Layout {
    static let gutter: CGFloat = 28
    /// The corners every card shares (the message field, the prompt, status and connection cards),
    /// so shapes stacked together read as one family.
    static let cardCornerRadius: CGFloat = 22
    /// Below the composer, in a chat and on New Chat alike, so it doesn't move when a chat starts.
    static let composerBottom: CGFloat = 14
}

extension View {
    /// The shared reading column. The transcript, the bottom bar and the New Chat composer all go
    /// through this one modifier, so their left and right edges cannot drift apart — the gutter is
    /// inside the maximum width, and what is left over is split evenly.
    func readingColumn() -> some View {
        modifier(ReadingColumn())
    }
}

/// The environment read lives here rather than in each caller, so a width change invalidates only
/// the column itself.
private struct ReadingColumn: ViewModifier {
    @Environment(\.readingWidth) private var readingWidth

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Layout.gutter)
            .frame(maxWidth: readingWidth)
            .frame(maxWidth: .infinity)
    }
}

/// Numbers as the reader's locale writes them.
enum Format {
    /// "$0.42", or four places below a cent, where two would say nothing.
    static func cost(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(usd < 0.01 ? 4 : 2)))
    }

    /// "42s", "3m 12s", "1h 5m": the two largest units.
    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    /// "950", "12.3K", "1.2M".
    static func tokens(_ n: Double) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// When a message was sent: the time today, the day and time before that.
    static func messageTime(msSinceEpoch: Double) -> String {
        let date = Date(timeIntervalSince1970: msSinceEpoch / 1000)
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

extension ModelInfo {
    /// Family and version from `resolvedModel` (the catalog's `displayName` has no version):
    /// claude-opus-5 → "Opus 5", claude-haiku-4-5-20251001 → "Haiku 4.5".
    var shortName: String {
        guard let resolved = resolvedModel else { return displayName }
        var parts = resolved.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, !family.isEmpty else { return displayName }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    /// The CLI's "whatever I would pick" pseudo-model; `resolvedModel` names the real one.
    var isDefaultAlias: Bool { value == "default" }
}

extension Array where Element == ModelInfo {
    /// The real models, without the CLI's "default" alias.
    var concrete: [ModelInfo] { filter { !$0.isDefaultAlias } }

    /// The model the CLI would choose on its own, named concretely.
    var defaultValue: String? {
        if let resolved = first(where: { $0.isDefaultAlias })?.resolvedModel,
           let match = concrete.first(where: { $0.resolvedModel == resolved }) {
            return match.value
        }
        return concrete.first?.value
    }

    /// Maps a reported model onto a picker row, following the default alias. Unlisted IDs (Bedrock)
    /// come back unchanged so they stay selectable.
    func concreteValue(for id: String?) -> String? {
        guard let id else { return defaultValue }
        if let exact = concrete.first(where: { $0.value == id || $0.resolvedModel == id }) { return exact.value }
        if let alias = first(where: { $0.value == id }), let resolved = alias.resolvedModel,
           let match = concrete.first(where: { $0.resolvedModel == resolved }) {
            return match.value
        }
        return id
    }
}

/// Symbols the session menus and Settings' New Chat defaults share, so one value never reads
/// differently in two places. `SessionSymbolTests` checks that every one of them resolves.
enum SessionSymbol {
    static let model = "sparkle"
    static let fastMode = "hare"
    /// Not a gauge: every needle position means a level, and Automatic is the absence of one.
    /// "A" in a circle is what the system uses elsewhere for automatic, and it keeps the round
    /// silhouette the gauges have.
    static let automaticEffort = "a.circle"
}

extension EffortLevel {
    /// "xhigh" isn't a word; the rest are just capitalised.
    var label: String { self == .xhigh ? "Extra High" : rawValue.capitalized }

    /// A gauge whose needle sits where this level falls among the ones the model supports, so the
    /// icon-only control says "how hard" without a word. A level the model doesn't list shows the
    /// Automatic symbol rather than claiming a position on a scale it isn't on.
    func symbol(in levels: [EffortLevel]) -> String {
        guard let index = levels.firstIndex(of: self) else { return SessionSymbol.automaticEffort }
        guard levels.count > 1 else { return "gauge.with.dots.needle.50percent" }
        // The gauge family only draws these five needle positions; pick the nearest.
        let needles = [0, 33, 50, 67, 100]
        let position = Double(index) / Double(levels.count - 1) * 100
        let nearest = needles.min { abs(Double($0) - position) < abs(Double($1) - position) } ?? 50
        return "gauge.with.dots.needle.\(nearest)percent"
    }
}

extension Optional where Wrapped == EffortLevel {
    /// No effort is a real choice: the model then decides per turn.
    var label: String { self?.label ?? "Automatic" }

    func symbol(in levels: [EffortLevel]) -> String { self?.symbol(in: levels) ?? SessionSymbol.automaticEffort }
}

extension PermissionMode {
    /// The modes offered, ordered as they escalate with the dangerous one last. Shared by the
    /// toolbar menu and Settings so the two lists can't drift apart.
    static let selectable: [PermissionMode] = [.default, .acceptEdits, .plan, .auto, .dontAsk, .bypassPermissions]

    /// The modes a menu lists: Bypass Permissions only with Settings ▸ General ▸ Offer Bypass
    /// Permissions, or while it is the mode already chosen, so leaving it is still possible.
    static func offered(bypass: Bool, current: PermissionMode) -> [PermissionMode] {
        selectable.filter { $0 != .bypassPermissions || bypass || current == .bypassPermissions }
    }

    /// One word each: a pop-up button is as wide as its widest item.
    var label: String {
        switch self {
        case .default: return "Ask"
        case .acceptEdits: return "Accept Edits"
        case .plan: return "Plan"
        case .auto: return "Auto"
        case .dontAsk: return "Deny"
        case .bypassPermissions: return "Bypass"
        default: return rawValue.humanized
        }
    }

    /// Spelled out, for menu rows and Settings. Title Case, like every other macOS menu item.
    var longLabel: String {
        switch self {
        case .default: return "Ask Before Edits"
        case .acceptEdits: return "Accept Edits"
        case .plan: return "Plan Mode"
        case .auto: return "Auto"
        case .dontAsk: return "Don't Ask"
        case .bypassPermissions: return "Bypass Permissions"
        default: return rawValue.humanized
        }
    }

    /// What Claude does in this mode, in one line under its name wherever it's chosen. Nil for a
    /// mode a newer server sends that this build can't describe.
    var summary: String? {
        switch self {
        case .default: return "Asks before editing files or running commands"
        case .acceptEdits: return "Edits files without asking; asks before commands"
        case .plan: return "Plans without making changes"
        case .auto: return "Doesn’t ask; a classifier blocks risky actions"
        case .dontAsk: return "Denies anything not already allowed"
        case .bypassPermissions: return "Never asks. Use only in a sandbox."
        default: return nil
        }
    }

    /// The one mode that lets Claude act without ever asking; shown in red.
    var isDangerous: Bool { self == .bypassPermissions }

    var symbol: String {
        switch self {
        case .default: return "hand.raised"
        case .acceptEdits: return "pencil.and.outline"
        case .plan: return "list.bullet.clipboard"
        case .auto: return "wand.and.stars"
        case .dontAsk: return "nosign"
        case .bypassPermissions: return "exclamationmark.shield"
        default: return "questionmark"
        }
    }
}

extension HostConfig {
    /// The same symbol in the sidebar's host menu and in Settings.
    var symbol: String { isLocal ? "laptopcomputer" : "network" }
}

extension HostConnection.State {
    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
}

extension ThreadStatus {
    /// Title case, never the wire value: the inspector shows "Not Loaded", not `notLoaded`.
    var label: String { rawValue.humanized }
}

// MARK: text size

extension EnvironmentValues {
    /// How much larger than the system's sizes the transcript and composer draw their text
    /// (View ▸ Bigger / Smaller). macOS has no Dynamic Type, so the app offers its own.
    @Entry var textScale: CGFloat = 1
}

/// The sizes View ▸ Bigger and Smaller step through, up to the 200% the HIG asks apps to allow.
enum TextScale {
    static let steps: [CGFloat] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]

    static func bigger(than scale: CGFloat) -> CGFloat? { steps.first { $0 > scale + 0.001 } }
    static func smaller(than scale: CGFloat) -> CGFloat? { steps.last { $0 < scale - 0.001 } }

    /// "100%", as Settings lists a step.
    static func label(_ scale: CGFloat) -> String { "\(Int((scale * 100).rounded()))%" }
}

/// A text style at the reader's chosen size: the system style, scaled, so it keeps the style's
/// weight, leading and tracking at every size.
private struct ScaledFont: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?
    let explicitDesign: Font.Design?
    @Environment(\.textScale) private var scale
    func body(content: Content) -> some View {
        content.font(.system(style, design: explicitDesign ?? .default, weight: weight).scaled(by: scale))
    }
}

extension EnvironmentValues {
    /// Whether the window's host is this Mac, so a path in the transcript can be opened here.
    @Entry var hostIsLocal = false

    /// Settings ▸ General ▸ Open Files With, on its own rather than read from `appearance`, so
    /// another setting changing doesn't redraw every tool call.
    @Entry var openFilesWith: Appearance.FileEditor = .defaultApp
}

extension View {
    /// For content the reader resizes with View ▸ Bigger and Smaller — the transcript, prompts and
    /// the composer — not for controls and chrome.
    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(ScaledFont(style: style, weight: weight, explicitDesign: design))
    }
}

/// The app's settings every view reads from the environment, set once for each scene.
extension Scene {
    public func appEnvironment(_ app: AppModel) -> some Scene {
        environment(\.appearance, app.appearance)
            .environment(\.textScale, app.textScale)
            .environment(\.openFilesWith, app.appearance.openFilesWith)
            .environment(\.readingWidth, app.transcriptWidth.points)
    }
}

extension View {
    /// The same, for a preview, which has no scene to set them.
    func appEnvironment(_ app: AppModel) -> some View {
        environment(\.appearance, app.appearance)
            .environment(\.textScale, app.textScale)
            .environment(\.openFilesWith, app.appearance.openFilesWith)
            .environment(\.readingWidth, app.transcriptWidth.points)
    }
}

extension AnyTransition {
    /// `transition`, which moves or scales something, or a plain fade under Reduce Motion.
    static func moving(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }
}
