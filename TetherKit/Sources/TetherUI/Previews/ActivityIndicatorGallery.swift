#if DEBUG
import SwiftUI

/// Debug ▸ Activity Indicators…: the running turn's words with each built-in way of showing
/// that something is happening, side by side. Every row cycles the same three phrases.
public struct ActivityIndicatorGallery: View {
    private static let phrases = ["Thinking", "Reading RootView.swift", "Running a command"]
    private static let symbols = ["brain", "doc.text", "terminal"]

    @State private var step = 0

    public init() {}

    private var text: String { Self.phrases[step % 3] }
    private var symbol: String { Self.symbols[step % 3] }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                row("1. ShimmerText sweep + blur-replace") {
                    ActivityLabel(text: text, live: true)
                }
                row("2. ProgressView, small, before") {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(text) }
                }
                row("3. Ellipsis, variableColor.iterative, after") {
                    HStack(spacing: 6) {
                        Text(text)
                        Image(systemName: "ellipsis").symbolEffect(.variableColor.iterative)
                    }
                }
                row("4. Sparkle, pulse") {
                    HStack(spacing: 6) { Image(systemName: "sparkle").symbolEffect(.pulse); Text(text) }
                }
                row("5. Sparkle, breathe") {
                    HStack(spacing: 6) { Image(systemName: "sparkle").symbolEffect(.breathe); Text(text) }
                }
                row("6. Symbol follows words, pulse + replace") {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                            .symbolEffect(.pulse)
                            .contentTransition(.symbolEffect(.replace))
                        Text(text)
                    }
                }
                row("7. Opacity pulse, phaseAnimator") {
                    Text(text).phaseAnimator([0.45, 1.0]) { view, opacity in
                        view.opacity(opacity)
                    } animation: { _ in .easeInOut(duration: 0.9) }
                }
                row("8. contentTransition(.interpolate) only") {
                    Text(text).contentTransition(.interpolate)
                }
                row("9. transition(.blurReplace) only") {
                    ZStack(alignment: .leading) {
                        Text(text).id(text).transition(.blurReplace)
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.spring(duration: 0.45, bounce: 0.25), value: step)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                step += 1
            }
        }
    }

    private func row<Content: View>(_ caption: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.tertiary)
            content()
        }
    }
}

#Preview("Activity indicators") {
    ActivityIndicatorGallery().frame(width: 420, height: 520)
}
#endif
