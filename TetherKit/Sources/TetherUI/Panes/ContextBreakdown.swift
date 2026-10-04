import Charts
import SwiftUI
import TetherProtocol

/// What fills a chat's context window, from `thread/contextUsage`: each category Claude Code counts,
/// in its order, sorted by what it is. Classified by the SDK's `kind`; a host whose Claude Code
/// predates it is read by the two names it has always given free space and the compaction reserve.
struct ContextBreakdown: Equatable {
    struct Category: Equatable, Identifiable {
        enum Kind: Equatable { case used(Int), free, buffer, deferred }
        let name: String
        let tokens: Double
        /// `used` carries its place among the used categories, which picks its color.
        let kind: Kind
        var id: String { name }
    }

    let categories: [Category]
    let total: Double
    let limit: Double

    init?(_ usage: JSONValue) {
        var used = 0
        categories = (usage["categories"]?.arrayValue ?? []).compactMap { c in
            guard let name = c.string("name") else { return nil }
            let kind: Category.Kind
            switch c.string("kind") ?? Self.legacyKind(name, deferred: c["isDeferred"] == .bool(true)) {
            case "free": kind = .free
            case "buffer": kind = .buffer
            case "deferred": kind = .deferred
            default: kind = .used(used); used += 1
            }
            return Category(name: name, tokens: c["tokens"]?.doubleValue ?? 0, kind: kind)
        }
        total = usage["totalTokens"]?.doubleValue ?? 0
        limit = usage["maxTokens"]?.doubleValue ?? usage["rawMaxTokens"]?.doubleValue ?? 0
        guard limit > 0 else { return nil }
    }

    private static func legacyKind(_ name: String, deferred: Bool) -> String {
        deferred ? "deferred" : name == "Free space" ? "free" : name == "Autocompact buffer" ? "buffer" : "used"
    }

    /// Where each category sits along the window: the used ones from the start, in order, and the
    /// compaction reserve at the end. Free space is the track left showing between them.
    var segments: [(category: Category, range: ClosedRange<Double>)] {
        var start = 0.0
        return categories.compactMap { c in
            switch c.kind {
            case .used:
                defer { start += c.tokens }
                return (c, start...min(start + c.tokens, limit))
            case .buffer: return (c, max(limit - c.tokens, 0)...limit)
            case .free, .deferred: return nil
            }
        }
    }

    /// System colors, in the order Claude Code lists what's used; they come round again past the last.
    static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo, .green, .yellow, .mint, .brown]

    static func color(_ kind: Category.Kind) -> Color? {
        switch kind {
        case .used(let i): palette[i % palette.count]
        case .buffer: .gray
        case .free, .deferred: nil
        }
    }
}

/// The window as one bar, each category in its color over an empty track: a stacked bar chart
/// rather than a `Gauge`, which shows one value. Read by VoiceOver as one element, with the
/// categories listed after it.
struct ContextBar: View {
    let breakdown: ContextBreakdown

    var body: some View {
        Chart(breakdown.segments, id: \.category.id) { segment in
            BarMark(xStart: .value("Start", segment.range.lowerBound), xEnd: .value("End", segment.range.upperBound))
                .foregroundStyle(ContextBreakdown.color(segment.category.kind) ?? .clear)
                // Square where one meets the next.
                .cornerRadius(0)
        }
        .chartXScale(domain: 0...breakdown.limit)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.background(.fill) }
        .frame(height: 8)
        // Barely rounded, as the storage bar in System Settings is: a capsule turned the small
        // categories at the ends into rounded slivers.
        .clipShape(.rect(cornerRadius: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context")
        .accessibilityValue("\(Format.tokens(breakdown.total)) of \(Format.tokens(breakdown.limit)) tokens used")
    }
}

/// One category's line: its color, name and size. Free space has an empty dot, the color of the
/// track; tools loaded only when used (deferred) have none, since they take no room yet.
struct ContextCategoryRow: View {
    let category: ContextBreakdown.Category

    var body: some View {
        LabeledContent {
            Text(Format.tokens(category.tokens))
        } label: {
            Label {
                Text(category.name)
            } icon: {
                switch category.kind {
                case .used, .buffer:
                    Image(systemName: "circle.fill").foregroundStyle(ContextBreakdown.color(category.kind) ?? .secondary)
                case .free:
                    Image(systemName: "circle.fill").foregroundStyle(.fill)
                case .deferred:
                    Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                }
            }
            .labelIconToTitleSpacing(6)
            .imageScale(.small)
        }
        .foregroundStyle(category.kind == .deferred ? .secondary : .primary)
    }
}
