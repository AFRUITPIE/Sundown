import SwiftUI
import TetherKit
import TetherProtocol

/// A host's scheduled tasks (Host ▸ Scheduled Tasks…): prompts the daemon sends on a schedule, each
/// run a new chat. The list beside the selected task's editor; edits apply as they're made.
public struct ScheduledTasksWindow: View {
    let app: AppModel
    let hostID: UUID?
    @State private var tasks: Loaded<[ScheduledTask]> = .loading
    @State private var selection: String?

    public init(app: AppModel, hostID: UUID?) {
        self.app = app
        self.hostID = hostID
    }

    /// Seeded, for a preview, which has no daemon to ask.
    init(app: AppModel, hostID: UUID?, tasks: [ScheduledTask], selection: String?) {
        self.app = app
        self.hostID = hostID
        fetches = false
        _tasks = State(initialValue: .ready(tasks))
        _selection = State(initialValue: selection)
    }

    private var fetches = true

    public static let id = "scheduled-tasks"

    private var connection: HostConnection? { hostID.flatMap(app.connection) }

    private var isConnected: Bool {
        if case .connected = connection?.state { return true }
        return false
    }

    public var body: some View {
        NavigationSplitView {
            list
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .navigationTitle("Scheduled Tasks")
        .navigationSubtitle(connection?.host.name ?? "")
        .toolbar {
            Button("New Task", systemImage: "plus") { Task { await create() } }
                .disabled(!tasks.isReady)
                .help("New Task")
        }
        .task(id: isConnected) { await reload() }
        .frame(minWidth: 640, minHeight: 420)
        // A scene of its own, so it doesn't get the chat windows' environment.
        .environment(\.appearance, app.appearance)
    }

    @ViewBuilder private var list: some View {
        if fetches, let connection, !isConnected {
            NotConnectedView(connection: connection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            taskList
        }
    }

    @ViewBuilder private var taskList: some View {
        switch tasks {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load Scheduled Tasks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await reload() } }
            }
        case .ready(let all):
            List(selection: $selection) {
                ForEach(all, id: \.id) { task in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.name.isEmpty ? "Untitled Task" : task.name).lineLimit(1)
                        Text(ScheduledTaskText.summary(task))
                            .font(.caption)
                            .foregroundStyle(task.enabled ? .secondary : .tertiary)
                            .lineLimit(1)
                    }
                    .tag(task.id)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if all.isEmpty {
                    ContentUnavailableView {
                        Label("No Scheduled Tasks", systemImage: "calendar.badge.clock")
                    } actions: {
                        Button("New Task") { Task { await create() } }
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if case .ready(let all) = tasks, let id = selection, let task = all.first(where: { $0.id == id }), let connection {
            ScheduledTaskEditor(task: task, connection: connection, open: { threadID in
                app.open(.chat(host: connection.id, thread: threadID))
            }, changed: { updated in
                replace(updated)
            }, deleted: {
                if case .ready(var all) = tasks {
                    all.removeAll { $0.id == id }
                    tasks = .ready(all)
                }
                selection = nil
            })
            .id(task.id)
        } else {
            ContentUnavailableView("No Task Selected", systemImage: "calendar")
        }
    }

    private func replace(_ task: ScheduledTask) {
        guard case .ready(var all) = tasks else { return }
        if let i = all.firstIndex(where: { $0.id == task.id }) { all[i] = task } else { all.append(task) }
        tasks = .ready(all)
    }

    private func reload() async {
        guard fetches, let connection else { return }
        do {
            tasks = .ready(try await connection.scheduledTasks())
        } catch {
            tasks = .failed(error.localizedDescription)
        }
    }

    /// A new task starts off, runs daily at 9:00 in the host's most recent folder, and is selected.
    private func create() async {
        guard let connection else { return }
        let folder = connection.projects.first?.cwd ?? connection.serverInfo?.host.home ?? "~"
        do {
            let task = try await connection.saveScheduledTask(.init(name: "New Task", prompt: "", cwd: folder, cadence: .daily,
                                                                    hour: 9, minute: 0, enabled: false))
            replace(task)
            selection = task.id
        } catch {
            tasks = .failed(error.localizedDescription)
        }
    }
}

/// How a task's schedule reads: "Every weekday at 9:00 AM".
enum ScheduledTaskText {
    /// Sunday first, as `ScheduledTask.weekday` counts them, in the reader's language.
    static var weekdays: [String] { Calendar.current.weekdaySymbols }

    static func time(hour: Int, minute: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func summary(_ task: ScheduledTask) -> String {
        let when: String
        switch task.cadence {
        case .manual: when = "Only When Run"
        case .hourly: when = "Every hour at :\(task.minute.formatted(.number.precision(.integerLength(2))))"
        case .daily: when = "Every day at \(time(hour: task.hour, minute: task.minute))"
        case .weekdays: when = "Weekdays at \(time(hour: task.hour, minute: task.minute))"
        case .weekly: when = "Every \(weekdays[((task.weekday ?? 2) - 1) % 7]) at \(time(hour: task.hour, minute: task.minute))"
        default: when = task.cadence.rawValue.humanized
        }
        return task.enabled || task.cadence == .manual ? when : "Off · \(when)"
    }

    static func cadenceLabel(_ cadence: ScheduleCadence) -> String {
        switch cadence {
        case .manual: "Only When Run"
        case .hourly: "Every Hour"
        case .daily: "Every Day"
        case .weekdays: "Every Weekday"
        case .weekly: "Every Week"
        default: cadence.rawValue.humanized
        }
    }
}

/// One task's settings. Every change is saved as it's made; text fields save when they're left
/// or Return is pressed.
private struct ScheduledTaskEditor: View {
    let task: ScheduledTask
    let connection: HostConnection
    let open: (String) -> Void
    let changed: (ScheduledTask) -> Void
    let deleted: () -> Void

    @State private var name: String
    @State private var prompt: String
    @State private var cwd: String
    @State private var model: String?
    @State private var permissionMode: PermissionMode
    @Environment(\.appearance) private var appearance
    @State private var cadence: ScheduleCadence
    @State private var time: Date
    @State private var minute: Int
    @State private var weekday: Int
    @State private var enabled: Bool
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var choosingFolder = false
    @State private var running = false
    @FocusState private var promptFocused: Bool

    init(task: ScheduledTask, connection: HostConnection, open: @escaping (String) -> Void,
         changed: @escaping (ScheduledTask) -> Void, deleted: @escaping () -> Void) {
        self.task = task
        self.connection = connection
        self.open = open
        self.changed = changed
        self.deleted = deleted
        _name = State(initialValue: task.name)
        _prompt = State(initialValue: task.prompt)
        _cwd = State(initialValue: task.cwd)
        _model = State(initialValue: task.model)
        _permissionMode = State(initialValue: task.permissionMode ?? .default)
        _cadence = State(initialValue: task.cadence)
        _time = State(initialValue: Calendar.current.date(from: DateComponents(hour: task.hour, minute: task.minute)) ?? .now)
        _minute = State(initialValue: task.minute)
        _weekday = State(initialValue: task.weekday ?? 2)
        _enabled = State(initialValue: task.enabled)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit(save)
                // Recent directories, then Choose Directory… for any other, as New Chat offers them.
                Picker("Directory", selection: Binding<String?>(get: { cwd }, set: { if let new = $0 { cwd = new } else { choosingFolder = true } })) {
                    ForEach(folders, id: \.self) { Text($0.abbreviatingHome).tag(Optional($0)) }
                    Divider()
                    Text("Choose Directory…").tag(String?.none)
                }
            }
            Section("Prompt") {
                TextEditor(text: $prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                    .focused($promptFocused)
                    .accessibilityLabel("Prompt")
                    .accessibilityIdentifier("schedule.prompt")
            }
            Section("Schedule") {
                Picker("Repeat", selection: $cadence) {
                    ForEach([ScheduleCadence.manual, .hourly, .daily, .weekdays, .weekly], id: \.self) {
                        Text(ScheduledTaskText.cadenceLabel($0)).tag($0)
                    }
                }
                if cadence == .weekly {
                    Picker("Day", selection: $weekday) {
                        ForEach(1...7, id: \.self) { Text(ScheduledTaskText.weekdays[$0 - 1]).tag($0) }
                    }
                }
                if cadence == .hourly {
                    Picker("At Minute", selection: $minute) {
                        ForEach([0, 5, 10, 15, 20, 30, 45], id: \.self) { Text(":" + String(format: "%02d", $0)).tag($0) }
                    }
                } else if cadence != .manual {
                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                }
                if cadence != .manual {
                    Toggle("On", isOn: $enabled)
                }
            }
            Section("Runs With") {
                Picker("Model", selection: $model) {
                    Text("Default").tag(String?.none)
                    ForEach(connection.models.concrete, id: \.value) { Text($0.shortName).tag(Optional($0.value)) }
                }
                PermissionModeFormPicker(selection: $permissionMode,
                                         modes: PermissionMode.offered(bypass: appearance.offerBypass, current: permissionMode))
            }
            Section {
                if let next = task.nextRunAt {
                    LabeledContent("Next Run", value: Date(timeIntervalSince1970: next / 1000).formatted(date: .abbreviated, time: .shortened))
                }
                if let last = task.lastRunAt {
                    LabeledContent("Last Run") {
                        HStack {
                            Text(Date(timeIntervalSince1970: last / 1000).formatted(date: .abbreviated, time: .shortened))
                            if let thread = task.lastThreadId {
                                Button("Open Chat") { open(thread) }
                            }
                        }
                    }
                }
                if let problem = error ?? task.lastError {
                    // Quiet, as errors are everywhere else: the next run may well go fine.
                    Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).lineLimit(3)
                }
                HStack {
                    Button("Run Now") { run() }
                        .disabled(running || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        // Pickers and toggles apply at once; the prompt when it's left.
        .onChange(of: cwd) { save() }
        .onChange(of: model) { save() }
        .onChange(of: permissionMode) { save() }
        .onChange(of: cadence) { save() }
        .onChange(of: time) { save() }
        .onChange(of: minute) { save() }
        .onChange(of: weekday) { save() }
        .onChange(of: enabled) { save() }
        .onChange(of: promptFocused) { if !promptFocused { save() } }
        .onDisappear(perform: save)
        .directoryChooser(isPresented: $choosingFolder, connection: connection, current: cwd) { cwd = $0 }
        .confirmationDialog("Delete “\(task.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await connection.deleteScheduledTask(task.id)
                    deleted()
                }
            }
        } message: {
            Text("It won’t run again. Chats it already started are kept.")
        }
        .dialogSeverity(.critical)
    }

    /// The host's recent folders, and the task's own if it isn't one.
    private var folders: [String] {
        var all = connection.projects.prefix(15).map(\.cwd)
        if !all.contains(cwd) { all.insert(cwd, at: 0) }
        return all
    }

    private var params: ScheduleSaveParams {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return ScheduleSaveParams(id: task.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt, cwd: cwd,
                                  model: model, permissionMode: permissionMode, cadence: cadence,
                                  hour: parts.hour ?? 9, minute: cadence == .hourly ? minute : (parts.minute ?? 0),
                                  weekday: cadence == .weekly ? weekday : nil, enabled: enabled)
    }

    private func save() {
        let params = params
        // Nothing changed: nothing to send.
        guard params.name != task.name || params.prompt != task.prompt || params.cwd != task.cwd || params.model != task.model
            || params.permissionMode != (task.permissionMode ?? .default) || params.cadence != task.cadence || params.hour != task.hour
            || params.minute != task.minute || params.weekday != task.weekday || params.enabled != task.enabled else { return }
        Task {
            do {
                changed(try await connection.saveScheduledTask(params))
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func run() {
        save()
        running = true
        Task {
            do {
                let thread = try await connection.runScheduledTask(task.id)
                open(thread)
                if let updated = try? await connection.scheduledTasks().first(where: { $0.id == task.id }) { changed(updated) }
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}

/// Host ▸ Scheduled Tasks….
struct ShowScheduledTasksButton: View {
    let hostID: UUID
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Scheduled Tasks…") { openWindow(id: ScheduledTasksWindow.id, value: hostID) }
    }
}

#if DEBUG
#Preview("Scheduled Tasks") {
    let app = AppModel.sample()
    let tasks = [
        ScheduledTask(id: "a", name: "Morning Triage", prompt: "Read yesterday's failing CI runs and summarize what broke.",
                      cwd: "/Users/hayden/Code/tether-app", cadence: .weekdays, hour: 9, minute: 0, enabled: true,
                      lastRunAt: 1_758_800_000_000, lastThreadId: "t", nextRunAt: 1_758_900_000_000),
        ScheduledTask(id: "b", name: "Dependency Audit", prompt: "Check for outdated packages.", cwd: "/Users/hayden/Code/tether-server",
                      cadence: .weekly, hour: 16, minute: 30, weekday: 6, enabled: false),
    ]
    ScheduledTasksWindow(app: app, hostID: app.hosts.first?.id, tasks: tasks, selection: "a")
        .frame(width: 820, height: 620)
}
#endif

extension Loaded {
    var isReady: Bool { if case .ready = self { return true }; return false }
}
