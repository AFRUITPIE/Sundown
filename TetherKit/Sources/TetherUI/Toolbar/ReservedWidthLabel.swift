import SwiftUI

/// A toolbar menu's label, sized for the widest title and symbol it can show, so choosing another
/// value never resizes the control or shifts the items beside it. The alternatives are laid out
/// hidden underneath: the layout system measures them, nothing here computes a width.
struct ReservedWidthLabel: View {
    let title: String
    let systemImage: String
    let titles: [String]
    let symbols: [String]

    init(_ title: String, systemImage: String, widestOf titles: [String] = [], symbols: [String] = []) {
        self.title = title
        self.systemImage = systemImage
        self.titles = titles.uniqued()
        self.symbols = symbols.uniqued()
    }

    var body: some View {
        Label {
            ZStack(alignment: .leading) {
                ForEach(titles, id: \.self) { Text($0).hidden().accessibilityHidden(true) }
                Text(title)
            }
        } icon: {
            ZStack {
                ForEach(symbols, id: \.self) { Image(systemName: $0).hidden().accessibilityHidden(true) }
                // One symbol turns into the next (the effort gauge's needle, the permission mode).
                Image(systemName: systemImage)
                    .contentTransition(.symbolEffect(.replace))
            }
            .animation(.default, value: systemImage)
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

#if DEBUG
/// Each label as wide as its widest value, so choosing another never resizes it: the outlines
/// match across each pair.
#Preview("ReservedWidthLabel") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(["Opus 5", "Sonnet 5"], id: \.self) { name in
            ReservedWidthLabel(name, systemImage: "sparkle", widestOf: ["Opus 5", "Sonnet 5", "Haiku 4.5"])
                .border(.quaternary)
        }
        ForEach(["gauge.with.dots.needle.0percent", "gauge.with.dots.needle.100percent"], id: \.self) { symbol in
            ReservedWidthLabel("Effort", systemImage: symbol, symbols: ["gauge.with.dots.needle.0percent", "gauge.with.dots.needle.100percent", "a.circle"])
                .labelStyle(.iconOnly)
                .border(.quaternary)
        }
    }
    .padding()
}
#endif
