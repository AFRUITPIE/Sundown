import SundownFixtures
import SwiftUI

/// Monospaced block that wraps and sizes itself; long output collapses to `lineLimit` lines.
struct CodeBlock: View {
    let code: String
    var language: String = ""
    var lineLimit: Int? = nil
    @State private var expanded = false
    /// The shown code in color, once it has been scanned off the main actor.
    @State private var colored: (source: String, text: AttributedString)?
    @Environment(\.appearance) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast

    private func styled(_ text: some View) -> some View {
        text
            .scaledFont(.callout, design: .monospaced)
            .foregroundStyle(.primary)
            .lineLimit(expanded ? nil : lineLimit)
            .textSelection(.enabled)
            // Read as code, punctuation and all.
            .accessibilityTextContentType(.sourceCode)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How many lines the code has, and, when it has more than `limit` and one, where its first
    /// `limit` and one end. Collapsed, only those are drawn: a tool's output can be megabytes, and
    /// Text laid all of it out to show 14 lines. The one past the limit keeps the last line shown
    /// ending in an ellipsis, as it did. One pass over the bytes, not two over the Characters.
    nonisolated static func measure(_ code: String, limit: Int?) -> (lines: Int, collapsedEnd: String.Index?) {
        let utf8 = code.utf8
        var lines = 1
        var end: String.Index?
        var i = utf8.startIndex
        while i != utf8.endIndex {
            if utf8[i] == UInt8(ascii: "\n") {
                if let limit, lines == limit + 1 { end = i }
                lines += 1
            }
            utf8.formIndex(after: &i)
        }
        return (lines, end)
    }

    var body: some View {
        let measure = Self.measure(code, limit: lineLimit)
        let isTruncated = lineLimit.map { measure.lines > $0 } ?? false
        let shown = !expanded ? measure.collapsedEnd.map { String(code[..<$0]) } ?? code : code
        // Plain until its colors are ready: only the colors change, never the layout.
        let codeText = colored.flatMap { $0.source == shown ? Text($0.text) : nil }
            ?? SyntaxHighlight.cached(shown, language: language).map(Text.init)
            ?? Text(verbatim: shown)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.isEmpty ? "Code" : language)
                    .fontWeight(.medium)
                Spacer()
                if isTruncated {
                    Button(expanded ? "Show Less" : "Show All \(measure.lines) Lines") { expanded.toggle() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("code.expand")
                }
                CopyButton { Clipboard.copy(code) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("code.copy")
            }
            .scaledFont(.caption, design: .default)
            .foregroundStyle(.secondary)
            // The header drags the code out, as text; the code itself stays selectable.
            .draggable(code)
            if appearance.wrapCode {
                styled(codeText)
            } else {
                // Unwrapped, a long line scrolls sideways: its own width, not the column's.
                ScrollView(.horizontal) {
                    styled(codeText.fixedSize(horizontal: true, vertical: false))
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
        .controlSize(.regular)
        .padding(12)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.12))
                .allowsHitTesting(false)
        }
        .task(id: shown) {
            guard colored?.source != shown, let text = await SyntaxHighlight.highlight(shown, language: language),
                  !Task.isCancelled else { return }
            colored = (shown, text)
        }
    }
}

#if DEBUG
#Preview("Markdown") {
    ScrollView {
        MarkdownView(text: sampleMarkdownPreviewText)
            .padding(20)
    }
    .frame(width: 480, height: 900)
}

#Preview("Code block") {
    CodeBlock(code: """
    case .itemAgentMessageDelta(let e):
        mutate(e.itemId) { if case .agentMessage(var m) = $0 { m.text += e.delta } }
    """, language: "swift")
        .padding(20)
        .frame(width: 460)
}

#Preview("Code block (truncated)") {
    CodeBlock(code: (1...30).map { "line \($0) of output" }.joined(separator: "\n"), language: "output", lineLimit: 8)
        .padding(20)
        .frame(width: 420)
}

private let sampleMarkdownPreviewText = """
# Release notes

## What's new

- Native **Liquid Glass** controls for the composer and prompt cards
- `#Preview` support across every `SundownUI` view
- Faster reconnect after the daemon restarts

**Cause.** On attach, the app's only source of settings is the `thread` object returned by
`thread/subscribe`, so the toolbar fell back to *your* defaults.

1. Read the tail of the transcript
2. Skip subagent turns

Run the tests with:

```swift
swift test --filter ThreadModelTests
```

> Transcript content stays on standard fills — glass is reserved for the controls layer, and a long quote wraps under itself.

- [x] Parse blocks off the main actor
- [ ] Select across every block
  - Nested items hang under their own text when they wrap onto a second line
    - And nest again

9. Ninth, holding code:

   ```sh
   swift test --package-path SundownKit
   ```

   And a second paragraph, lined up with the item's text.
10. Tenth, whose marker is wider

| Option | Effect | Default |
|---|---|--:|
| `wrapCode` | Wraps long lines | On |
| Reading width | Narrow, Medium or Wide | Narrow |

---

See [Apple's documentation](https://developer.apple.com/documentation/swiftui) for more.
"""

#endif
