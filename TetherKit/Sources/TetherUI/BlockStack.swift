import SwiftUI

/// A vertical stack of full-width blocks, measuring each once per width. `VStack` measures its
/// children several times per width to find how flexible each is, and each measurement of text is a
/// layout pass, of selectable text an expensive one. A block always takes the width it's offered, so
/// one proposal is enough, and its answer is kept for the rest of the layout pass. A reply lays out
/// about 17% faster this way at a new width (`MarkdownBenchmark`). After swiftui-prose's `BlockStack`.
struct BlockStack: SwiftUI.Layout {
    var spacing: CGFloat = 0

    struct Cache {
        fileprivate var first: (width: CGFloat?, value: Measurement)?
        fileprivate var second: (width: CGFloat?, value: Measurement)?
    }

    fileprivate struct Measurement {
        var heights: [CGFloat]
        var size: CGSize
    }

    static var layoutProperties: LayoutProperties {
        var properties = LayoutProperties()
        properties.stackOrientation = .vertical
        return properties
    }

    func makeCache(subviews: LayoutSubviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: LayoutSubviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout Cache) -> CGSize {
        measure(width: proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout Cache) {
        let measurement = measure(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            // The size it was measured at, so it reuses that measurement.
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
            y += measurement.heights[index] + spacing
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: LayoutSubviews, cache: inout Cache) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else { return nil }
        return bounds.minY + first.dimensions(in: ProposedViewSize(width: bounds.width, height: nil))[guide]
    }

    private func measure(width: CGFloat?, subviews: LayoutSubviews, cache: inout Cache) -> Measurement {
        if let first = cache.first, first.width == width { return first.value }
        if let second = cache.second, second.width == width { return second.value }
        let proposal = ProposedViewSize(width: width, height: nil)
        var heights: [CGFloat] = []
        heights.reserveCapacity(subviews.count)
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(proposal)
            heights.append(size.height)
            widest = max(widest, size.width)
        }
        let height = heights.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        let measurement = Measurement(heights: heights,
                                      size: CGSize(width: width.flatMap { $0.isFinite ? $0 : nil } ?? widest, height: height))
        cache.second = cache.first
        cache.first = (width, measurement)
        return measurement
    }
}

/// Something in a gutter beside a block's text, the text measured once for the width left: a list
/// item's marker, on the text's first baseline, or a quote's bar, as tall as the text. `HStack`
/// measured the text several times to share the width out. After swiftui-prose's `ListItemLayout`.
struct GutterLayout: SwiftUI.Layout {
    var spacing: CGFloat
    /// The gutter's view takes the text's height (a quote's bar) rather than its own, on the text's
    /// first baseline (a list item's marker).
    var stretches = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let gutter = subviews[0].sizeThatFits(stretches ? ProposedViewSize(width: nil, height: 0) : .unspecified)
        let text = subviews[1].sizeThatFits(textProposal(proposal.width, gutter: gutter.width))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? gutter.width + spacing + text.width
        return CGSize(width: width, height: stretches ? text.height : max(text.height, gutter.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let gutter = subviews[0].dimensions(in: stretches ? ProposedViewSize(width: nil, height: 0) : .unspecified)
        let textProposal = textProposal(bounds.width, gutter: gutter.width)
        let text = subviews[1].dimensions(in: textProposal)
        subviews[1].place(at: CGPoint(x: bounds.minX + gutter.width + spacing, y: bounds.minY), proposal: textProposal)
        if stretches {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: gutter.width, height: text.height))
        } else {
            let offset = max(0, text[.firstTextBaseline] - gutter[.firstTextBaseline])
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + offset), proposal: .unspecified)
        }
    }

    private func textProposal(_ width: CGFloat?, gutter: CGFloat) -> ProposedViewSize {
        ProposedViewSize(width: width.map { max(0, $0 - gutter - spacing) }, height: nil)
    }
}
