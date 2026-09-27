import SwiftUI
import TetherKit
import TetherProtocol

/// Status, any pending prompt, and the composer, grouped so their glass shapes blend.
struct BottomBar: View {
    let thread: ThreadModel
    let connection: HostConnection
    @Environment(\.appearance) private var appearance

    var body: some View {
        // One read of `pending`: it decides both the card and whether the composer can send.
        let pending = thread.pending.first
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                StatusStrip(thread: thread)
                if let pending {
                    PendingRequestView(pending: pending, thread: thread)
                        .id(pending.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Always mounted, so a draft survives a prompt arriving (#3). The prompt is answered
                // first — Send is disabled under it, Stop is not.
                Composer(connection: connection, cwd: thread.cwd, thread: thread, draftKey: thread.id,
                         awaitingAnswer: pending != nil, onStop: {
                    Task { await connection.interrupt(thread) }
                }, accessory: appearance.contextRing ? AnyView(ContextRing(thread: thread, connection: connection)) : nil,
                submit: { input in
                    await connection.send(thread, input: input)
                })
            }
            // The only explicit animation down here, and it runs only when a prompt comes or goes.
            // It has to sit on the stack the prompt is inserted into for the transition to have an
            // animation to use.
            .animation(.snappy, value: pending?.id)
        }
        .padding(.bottom, 14)
        .readingColumn()
        .scaledFont(.body)
    }
}

struct StatusStrip: View {
    let thread: ThreadModel

    var body: some View {
        let parts = messages
        let auth = thread.authStatus.flatMap { $0.isAuthenticating || $0.error != nil ? $0 : nil }
        if !parts.isEmpty || auth != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(parts, id: \.self) { m in
                    // Selectable, so an error can be copied into a search or a bug report.
                    Text(m).font(.callout).lineLimit(3).textSelection(.enabled)
                }
                if let auth { AuthStatusView(status: auth) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(thread.lastError != nil ? .red.opacity(0.25) : nil), in: .rect(cornerRadius: 18))
        }
    }

    private var messages: [String] {
        var out: [String] = []
        if let e = thread.lastError { out.append(e) }
        if let r = thread.apiRetry { out.append("Retrying API request (attempt \(r.attempt)/\(r.maxRetries))\(r.error.map { ": \($0)" } ?? "")") }
        if thread.activity == "compacting" { out.append("Compacting conversation…") }
        return out
    }
}

/// Shows `awsAuthRefresh` / login helper output (e.g. AWS SSO device-code URLs) with clickable links.
struct AuthStatusView: View {
    let status: ThreadAuthStatusNotification
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(status.isAuthenticating ? "Refreshing credentials…" : "Authentication problem", systemImage: "key")
                .font(.caption.bold())
            ForEach(Array(status.output.suffix(8).enumerated()), id: \.offset) { _, line in
                if let url = line.firstMatch(of: /https?:\/\/\S+/).flatMap({ URL(string: String($0.output)) }) {
                    Link(line, destination: url).font(.caption.monospaced())
                } else {
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let e = status.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }
}

#if DEBUG
#Preview("BottomBar (composer)") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.sampleIdleChat()
    VStack {
        Spacer()
        BottomBar(thread: thread, connection: connection)
    }
    .frame(width: 900, height: 220)
}

#Preview("BottomBar (pending request)") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.samplePendingPermission()
    VStack {
        Spacer()
        BottomBar(thread: thread, connection: connection)
    }
    .frame(width: 900, height: 380)
}

/// Issue #3: the draft has to still be there under the prompt, with Send disabled until it is answered.
#Preview("BottomBar (pending request + draft)") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.samplePendingPermission()
    VStack {
        Spacer()
        BottomBar(thread: thread, connection: connection)
    }
    .environment(\.composerDraft, "…and once that's done, run the package tests")
    .frame(width: 900, height: 380)
}

#Preview("BottomBar (error + retry)") {
    let connection = HostConnection.sample()
    VStack {
        Spacer()
        BottomBar(thread: .sampleErrorTurn(), connection: connection)
        BottomBar(thread: .sampleApiRetry(), connection: connection)
    }
    .frame(width: 900, height: 420)
}

#Preview("StatusStrip") {
    VStack(alignment: .leading, spacing: 16) {
        StatusStrip(thread: .sampleErrorTurn())
        StatusStrip(thread: .sampleApiRetry())
    }
    .padding(20)
    .frame(width: 560)
}

#Preview("AuthStatusView") {
    AuthStatusView(status: .init(threadId: "preview-thread", seq: 1, isAuthenticating: true,
                                  output: ["Visit https://device.sso.us-west-2.amazonaws.com/", "Enter code: ABCD-EFGH"], error: nil))
        .padding(20)
        .frame(width: 480)
}

#endif
