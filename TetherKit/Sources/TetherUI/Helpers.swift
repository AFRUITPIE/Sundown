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

/// One reading column, shared by the transcript and the bar beneath it so the composer lines up
/// with the text above it instead of sitting a few points wider on each side.
enum Layout {
    static let readingWidth: CGFloat = 920
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

    /// Shared: building a formatter costs more than the formatting, and the sidebar formats one
    /// per row on every pass.
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

extension PermissionMode {
    var label: String {
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
