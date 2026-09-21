import Foundation
import SwiftUI
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
}

enum Layout {
    static let gutter: CGFloat = 28
}

enum Format {
    static func cost(_ usd: Double) -> String {
        usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.0fs", seconds) : String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
    }

    static func tokens(_ n: Double) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", n / 1_000_000) : n >= 1000 ? String(format: "%.1fk", n / 1000) : String(Int(n))
    }

    /// Shared: building a formatter costs more than using one.
    @MainActor private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @MainActor
    static func relative(msSinceEpoch: Double) -> String {
        relativeFormatter.localizedString(for: Date(timeIntervalSince1970: msSinceEpoch / 1000), relativeTo: .now)
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
    /// One word each: a pop-up button is as wide as its widest item.
    var label: String {
        switch self {
        case .default: return "Ask"
        case .acceptEdits: return "Accept Edits"
        case .plan: return "Plan"
        case .auto: return "Auto"
        case .dontAsk: return "Deny"
        case .bypassPermissions: return "Bypass"
        default: return rawValue
        }
    }

    /// Spelled out, for Settings.
    var longLabel: String {
        switch self {
        case .default: return "Ask before edits"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan mode"
        case .auto: return "Auto"
        case .dontAsk: return "Don't ask (deny)"
        case .bypassPermissions: return "Bypass permissions"
        default: return rawValue
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

extension ThreadStatus {
    var color: Color {
        switch self {
        case .running, .starting: return .blue
        case .requiresAction: return .orange
        case .error: return .red
        case .idle: return .green
        default: return .secondary
        }
    }
}

struct StatusDot: View {
    let status: ThreadStatus
    var body: some View {
        Group {
            if status == .running || status == .starting {
                ProgressView().controlSize(.mini)
            } else if status == .requiresAction {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            } else if status == .idle {
                Circle().fill(.green.opacity(0.8)).frame(width: 6, height: 6)
            } else {
                Color.clear.frame(width: 6, height: 6)
            }
        }
        .frame(width: 14, height: 14)
        .help(status.rawValue)
    }
}

#if DEBUG
#Preview("StatusDot") {
    HStack(spacing: 12) {
        ForEach([ThreadStatus.idle, .running, .requiresAction, .starting, .error, .closed], id: \.self) { status in
            VStack(spacing: 4) {
                StatusDot(status: status)
                Text(status.rawValue).font(.caption2)
            }
        }
    }
    .padding(20)
}

#endif
