import Foundation
import SwiftUI
import TetherProtocol

extension JSONValue {
    /// Pretty-printed JSON for display.
    var pretty: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: enc.encode(self), as: UTF8.self)) ?? ""
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

    static func relative(msSinceEpoch: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: Date(timeIntervalSince1970: msSinceEpoch / 1000), relativeTo: .now)
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
