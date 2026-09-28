import SwiftUI
import TetherKit

/// The subagents and workflows this chat has started. Reads `thread.taskEntries`, which is stored
/// and rebuilt only on task events, so streamed message deltas never touch this pane. A task's
/// detail replaces the list, with its own back button: not a `NavigationStack`, whose Back button
/// went to the window's toolbar, over the chat, rather than over the pane.
struct TasksPane: View {
    let thread: ThreadModel
    let connection: HostConnection
    @Binding var selectedTaskID: String?

    var body: some View {
        let entries = thread.taskEntries
        if let selectedTaskID, let entry = entries.first(where: { $0.id == selectedTaskID }) {
            InspectorTaskDetail(entry: entry, thread: thread, connection: connection) { self.selectedTaskID = nil }
        } else if entries.isEmpty {
            InspectorEmptyState("No Tasks", symbol: InspectorPane.tasks.symbol)
        } else {
            Form {
                Section {
                    ForEach(entries) { entry in
                        Button { selectedTaskID = entry.id } label: {
                            TaskRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// One subagent or workflow run: what it is, and whether it's still going.
struct TaskRow: View {
    let entry: InspectorTaskEntry

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.task?.description ?? entry.call?.summary
                     ?? entry.call?.input.string("description") ?? entry.task?.taskId ?? "Task")
                    .lineLimit(2)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            // The status line says it in words; the spinner and glyphs are for the eye, or the
            // row would read as a progress indicator.
            Group {
                if SubagentLifecycle.isRunning(call: entry.call, task: entry.task) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusSymbol).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if entry.isBackgrounded { return "Running in background" }
        guard let call = entry.call else {
            // A lifecycle event with no call of ours: the server's own word for it, in plain English.
            return (entry.task?.status ?? entry.task?.event ?? "Task").humanized
        }
        return SubagentLifecycle.title(call: call, task: entry.task, isBackgrounded: entry.isBackgrounded)
    }

    private var statusSymbol: String {
        let state = (entry.task?.status ?? entry.task?.event ?? entry.call?.status.rawValue ?? "").lowercased()
        if state.contains("fail") { return "exclamationmark.circle" }
        if state.contains("stop") || state.contains("interrupt") { return "stop.circle" }
        return "checkmark.circle"
    }
}

/// One task on its own: how it's going, what it was asked, and what it has done so far.
struct InspectorTaskDetail: View {
    let entry: InspectorTaskEntry
    let thread: ThreadModel
    let connection: HostConnection
    let close: () -> Void

    var body: some View {
            Form {
                // Unheaded: a "Status" section whose first row is "Status" says it twice.
                Section {
                    if let call = entry.call {
                        LabeledContent(
                            "Status",
                            value: SubagentLifecycle.title(
                                call: call,
                                task: entry.task,
                                isBackgrounded: entry.isBackgrounded
                            )
                        )
                        if let seconds = call.elapsedSeconds {
                            LabeledContent("Elapsed", value: Format.duration(seconds))
                        }
                    } else if let task = entry.task {
                        LabeledContent("Status", value: entry.isBackgrounded
                            ? "Running in background"
                            : (task.status ?? task.event).humanized)
                    }
                    if let summary = entry.task?.summary, !summary.isEmpty {
                        Text(summary).lineLimit(nil).textSelection(.enabled)
                    }
                    if entry.isTaskRunning, let task = entry.task {
                        HStack {
                            // Only the chat's own command or agent, while it still holds up its turn.
                            if entry.canMoveToBackground, let toolUseId = task.toolUseId, thread.isTopLevelCall(toolUseId) {
                                Button("Move to Background") {
                                    Task { await connection.moveToBackground(thread, toolUseId: toolUseId) }
                                }
                            }
                            Button("Stop Task", role: .destructive) {
                                Task { await connection.stopTask(thread, taskId: task.taskId) }
                            }
                        }
                    }
                }
                if let prompt = entry.call?.input.string("prompt"), !prompt.isEmpty {
                    Section("Prompt") {
                        Text(prompt).lineLimit(nil).textSelection(.enabled)
                    }
                }
                if let toolUseId = entry.call?.id {
                    let children = thread.children(of: toolUseId)
                    if !children.isEmpty {
                        Section("Activity") {
                            ForEach(children, id: \.id) { ItemView(item: $0, thread: thread) }
                        }
                    } else if let output = entry.call?.outputText, !output.isEmpty {
                        Section("Result") {
                            Text(output).lineLimit(nil).textSelection(.enabled)
                        }
                    }
                }
            }
            // Back to the list, over the task, which scrolls under it.
            .safeAreaBar(edge: .top) {
                HStack {
                    Button("All Tasks", systemImage: "chevron.left", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    Text(entry.task?.description ?? entry.call?.input.string("description") ?? "Task")
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
    }
}

#if DEBUG
#Preview("Tasks") {
    inspectorPreview {
        ThreadInspector(thread: .sampleWithTasks(), connection: .sample())
    }
}

#Preview("Tasks (empty)") {
    inspectorPreview {
        ThreadInspector(thread: .sampleIdleChat(), connection: .sample())
    }
}

#Preview("Tasks (subagent detail)") {
    inspectorPreview {
        ThreadInspector(thread: .sampleToolCalls(), connection: .sample(),
                        selectedTaskID: .constant("tool-subagent-explore"))
    }
}

/// A task still running: it can be stopped from here.
#Preview("Tasks (running task detail)") {
    inspectorPreview {
        ThreadInspector(thread: .sampleWithTasks(), connection: .sample(), selectedTaskID: .constant("task:task-1"))
    }
}

/// Every shape a row can take, at the inspector's width: running, finished, failed, backgrounded.
#Preview("TaskRow") {
    Form {
        Section {
            ForEach(ThreadModel.sampleWithTasks().taskEntries) { TaskRow(entry: $0) }
        }
    }
    .formStyle(.grouped)
    .lineLimit(1)
    .frame(width: 300, height: 260)
}
#endif
