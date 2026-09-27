import SwiftUI
import TetherKit

/// Chat ▸ Ask a Side Question… (⌥⌘;): a question about the chat, answered with everything it knows
/// but kept out of it, as the CLI's /btw is. Nothing here is saved.
struct SideQuestionSheet: View {
    let thread: ThreadModel
    let connection: HostConnection
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var exchanges: [Exchange] = []
    @State private var asking = false
    @FocusState private var focused: Bool

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask a Side Question").font(.headline)
            Text("Answered from this chat, but not added to it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !exchanges.isEmpty || asking {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(exchanges) { e in
                            Text(e.question).fontWeight(.medium)
                            MarkdownView(text: e.answer)
                                .accessibilityIdentifier("sideQuestion.answer")
                        }
                        if asking { ProgressView().controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(minHeight: 120, maxHeight: 360)
            }
            HStack {
                TextField("Question", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(ask)
                    .accessibilityIdentifier("sideQuestion.field")
                Button("Ask", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { focused = true }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        question = ""
        asking = true
        Task {
            let answer: String
            do {
                answer = try await connection.sideQuestion(thread, q) ?? "Claude didn’t answer."
            } catch {
                answer = error.localizedDescription
            }
            exchanges.append(Exchange(question: q, answer: answer))
            asking = false
        }
    }
}

#if DEBUG
#Preview("Side Question") {
    SideQuestionSheet(thread: .sampleIdleChat(), connection: .sample())
}
#endif
