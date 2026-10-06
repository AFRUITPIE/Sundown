import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

/// Dynamic workflows: the script's meta, a run from the daemon's snapshot or the CLI's raw
/// progress, how the chat keeps it between events and across a reload, and how its call folds.
@MainActor
@Suite
struct WorkflowRunTests {
    private let threadID = "wf"

    // MARK: the script's meta

    @Test func metaIsReadInAnyQuotes() throws {
        let script = """
        // A comment before it.
        export const meta = {
          name: "spec",
          'description': `Write the spec, then check it`, // trailing comment
          phases: [
            { title: 'Draft', detail: "One writer" },
            { title: `Check`, },
          ],
        }
        const x = { name: 'not this one' }
        """
        let meta = try #require(WorkflowScript.meta(script))
        #expect(meta.name == "spec")
        #expect(meta.description == "Write the spec, then check it")
        #expect(meta.phases.map(\.title) == ["Draft", "Check"])
        #expect(meta.phases.map(\.detail) == ["One writer", nil])
    }

    @Test func aScriptWithoutMetaHasNone() {
        #expect(WorkflowScript.meta("await agent('hi')") == nil)
        #expect(WorkflowScript.meta("export const meta = {") == nil)
        #expect(WorkflowScript.meta(WorkflowSample.script)?.name == "review-diff")
    }

    // MARK: launch receipt

    @Test func theLaunchReceiptGivesTheRunAndTaskIDs() {
        #expect(WorkflowRun.runID(fromLaunchText: WorkflowSample.launchText) == WorkflowSample.runID)
        #expect(WorkflowRun.taskID(fromLaunchText: WorkflowSample.launchText) == WorkflowSample.taskID)
        #expect(WorkflowRun.runID(fromLaunchText: "Workflow launched in background. Task ID: t1") == nil)
        #expect(WorkflowRun.runID(fromLaunchText: nil) == nil)
    }

    // MARK: a run

    private func call(script: String = WorkflowSample.script, output: String? = WorkflowSample.launchText,
                      status: ToolStatus = .completed) -> Item.ToolCall {
        .init(id: WorkflowSample.callID, createdAt: 1_000, name: "Workflow", kind: .other, input: ["script": .string(script)],
              status: status, outputText: output)
    }

    private func task(_ event: String, seq: Int, status: String = "running", description: String? = nil,
                      data: [String: JSONValue] = [:]) -> TaskEventNotification {
        var data = data
        data["task_type"] = "local_workflow"
        return .init(threadId: threadID, seq: seq, event: event, taskId: WorkflowSample.taskID, toolUseId: WorkflowSample.callID,
                     description: description, status: status, data: .object(data))
    }

    /// An older daemon passes the CLI's raw progress through, phases withheld as "phase N" when the
    /// script is; their titles come from the script's meta.
    @Test func aRunIsReadFromTheCLIsRawProgress() {
        let raw: JSONValue = [
            ["type": "workflow_phase", "index": 1, "title": "phase 1"],
            ["type": "workflow_phase", "index": 2, "title": "phase 2"],
            ["type": "workflow_agent", "index": 1, "label": "a", "phaseIndex": 1, "state": "done", "durationMs": 4000, "agentId": "x1"],
            ["type": "workflow_agent", "index": 2, "label": "b", "phaseIndex": 2, "state": "progress", "startedAt": 5000],
            ["type": "workflow_agent", "index": 3, "label": "c", "phaseIndex": 2, "state": "start", "queuedAt": 5000],
            ["type": "workflow_agent", "index": 4, "label": "d", "phaseIndex": 2, "state": "error", "error": "skipped by user", "skipped": true],
            ["type": "workflow_agent", "index": 5, "label": "e", "phaseIndex": 2, "state": "error", "error": "stalled"],
            ["type": "workflow_log", "message": "ignored"],
        ]
        let run = WorkflowRun(call: call(), task: task("progress", seq: 1, data: ["workflow_progress": raw, "workflow_name": "review-diff"]))
        #expect(run.status == .running)
        #expect(run.name == "review-diff")
        #expect(run.runId == WorkflowSample.runID)
        #expect(run.taskId == WorkflowSample.taskID)
        #expect(run.phases.map(\.title) == ["Review", "Verify"])
        #expect(run.agents.map(\.state) == [.done, .running, .waiting, .stopped, .failed])
        #expect(run.agents.map(\.phaseTitle) == ["Review", "Verify", "Verify", "Verify", "Verify"])
        #expect(run.progressText == "Verify: 1 of 5 agents done")
    }

    /// A daemon that passes the CLI's agent states through as they are (with `skipped` for one the
    /// person skipped), and an older one's names for them, read the same.
    @Test func agentStatesAreReadAsTheCLINamesThem() {
        let snapshot: JSONValue = [
            "runId": "r", "status": "running", "error": "boom",
            "phases": [],
            "agents": [
                ["index": 1, "label": "a", "state": "queued"],
                ["index": 2, "label": "b", "state": "start", "queuedAt": 1, "startedAt": 2],
                ["index": 3, "label": "c", "state": "progress"],
                ["index": 4, "label": "d", "state": "cached"],
                ["index": 5, "label": "e", "state": "skipped"],
                ["index": 6, "label": "f", "state": "error", "skipped": true, "error": "skipped"],
                ["index": 7, "label": "g", "state": "error", "error": "stalled"],
                ["index": 8, "label": "h", "state": "something new"],
            ],
        ]
        let run = WorkflowRun(call: call(), task: nil, loaded: snapshot)
        #expect(run.agents.map(\.state) == [.waiting, .running, .running, .done, .stopped, .stopped, .failed, .running])
        #expect(run.error == "boom")
    }

    @Test func aRunReadsItsWordsFromTheSnapshot() {
        let snapshot = WorkflowSample.snapshot(now: 1_000_000, running: false)
        let run = WorkflowRun(call: call(), task: nil, loaded: snapshot)
        #expect(run.status == .completed)
        #expect(run.description == WorkflowSample.description)
        #expect(run.agents.count == 5 && run.agents.allSatisfy { $0.state == .done })
        #expect(run.usageText == "5 agents · 81,661 tokens · 25 tool uses · 3m 58s")
        #expect(run.finishedCaption == "5 agents · 3m 58s")
        #expect(run.result?.contains("findings") == true)
    }

    /// The call comes back at once; with nothing else known, a reloaded run's state is unknown, and
    /// a run whose workflow ended stopped its agents still going.
    @Test func theCallDoesNotSayTheRunHasFinished() {
        #expect(WorkflowRun(call: call(), task: nil).status == .unknown)
        #expect(WorkflowRun(call: call(output: nil, status: .running), task: nil).status == .running)
        let stopped = WorkflowRun(call: call(), task: task("notification", seq: 2, status: "stopped"),
                                  loaded: WorkflowSample.snapshot(now: 1_000_000, running: true))
        #expect(stopped.status == .stopped)
        #expect(!stopped.agents.contains { $0.state == .running || $0.state == .waiting })
        #expect(stopped.agents.contains { $0.state == .stopped })
        // A completed run's agents still going when it was last heard of finished with it.
        let completed = WorkflowRun(call: call(), task: task("notification", seq: 2, status: "completed"),
                                    loaded: WorkflowSample.snapshot(now: 1_000_000, running: true))
        #expect(completed.status == .completed)
        #expect(completed.agents.allSatisfy { $0.state == .done })
        // A run the daemon can't say how it ended (cut off) stopped them.
        var cutOff = WorkflowSample.snapshot(now: 1_000_000, running: true)
        if case .object(var o) = cutOff { o["status"] = "unknown"; cutOff = .object(o) }
        let unknown = WorkflowRun(call: call(), task: nil, loaded: cutOff)
        #expect(unknown.status == .unknown)
        #expect(!unknown.agents.contains { $0.state == .running || $0.state == .waiting })
        #expect(WorkflowRun(call: call(), task: task("started", seq: 1)).progressText == "Starting")
    }

    // MARK: the thread

    private func loaded() -> ThreadModel {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: WorkflowSample.items(now: 1_000_000, running: true), turns: [], seq: 1)
        return thread
    }

    /// Progress without a snapshot keeps the last one, the workflow's name, and its started
    /// description; an older daemon's newest-agent description is its activity, not its name.
    @Test func progressCarriesTheLastSnapshotForward() throws {
        let thread = loaded()
        thread.apply(.taskEvent(task("started", seq: 2, description: "Review the diff", data: ["workflow_name": "review-diff"])))
        thread.apply(.taskEvent(task("progress", seq: 3, data: ["workflow": WorkflowSample.snapshot(now: 1_000_000, running: true)])))
        thread.apply(.taskEvent(task("progress", seq: 4, description: "Verify: skeptic 1", data: ["usage": ["total_tokens": 9]])))
        let run = try #require(thread.workflowRuns[WorkflowSample.callID])
        #expect(run.agents.count == 5)
        #expect(run.name == "review-diff")
        #expect(thread.taskEvent(forToolUseId: WorkflowSample.callID)?.description == "Review the diff")
        #expect(thread.taskEvent(forToolUseId: WorkflowSample.callID)?.data["workflow_name"]?.stringValue == "review-diff")
        #expect(run.activity == "Verify: skeptic 1")
        #expect(run.status == .running)
        // The Tasks list has it as its call, with its run.
        #expect(thread.taskEntries.map(\.id) == [WorkflowSample.callID])
        #expect(thread.taskEntries.first?.workflow?.agents.count == 5)
    }

    @Test func aClosedThreadStopsItsWorkflow() throws {
        let thread = loaded()
        thread.apply(.taskEvent(task("progress", seq: 2, data: ["workflow": WorkflowSample.snapshot(now: 1_000_000, running: true)])))
        thread.apply(.threadClosed(.init(threadId: threadID, seq: 3)))
        let run = try #require(thread.workflowRuns[WorkflowSample.callID])
        #expect(run.status == .stopped)
        #expect(!run.agents.contains { $0.state == .running })
    }

    /// After a reload there are no task events: the entry is the call, and its run is what
    /// `workflow/read` says, which is asked for only until a finished run has been read.
    @Test func aReloadBuildsTheRunFromTheCallAndARead() throws {
        let thread = loaded()
        #expect(thread.taskEntries.map(\.id) == [WorkflowSample.callID])
        #expect(thread.workflowRuns[WorkflowSample.callID]?.status == .unknown)
        #expect(thread.workflowsToRead.map(\.runId) == [WorkflowSample.runID])
        thread.setLoadedWorkflow(WorkflowSample.snapshot(now: 1_000_000, running: false), for: WorkflowSample.callID)
        let run = try #require(thread.workflowRuns[WorkflowSample.callID])
        #expect(run.status == .completed)
        #expect(run.agents.count == 5)
        #expect(thread.taskEntries.first?.workflow == run)
        #expect(thread.workflowsToRead.isEmpty)
        // Trimmed, a held call keeps its run.
        thread.trim(toLast: 3)
        #expect(thread.workflowRuns[WorkflowSample.callID]?.status == .completed)
        thread.unload()
        #expect(thread.workflowRuns.isEmpty)
    }

    /// A finished agent's transcript is kept with the chat only while its workflow's call is.
    @Test func trimmingLetsGoOfAgentTranscriptsWithTheirCall() {
        let thread = loaded()
        let item = Item.agentMessage(.init(id: "a1", createdAt: 1, text: "hi"))
        thread.rememberWorkflowAgentTranscript([item], runId: WorkflowSample.runID, agentId: "x")
        thread.rememberWorkflowAgentTranscript([item], runId: "gone", agentId: "y")
        thread.trim(toLast: 3)
        #expect(thread.workflowAgentTranscript(runId: WorkflowSample.runID, agentId: "x") != nil)
        #expect(thread.workflowAgentTranscript(runId: "gone", agentId: "y") == nil)
        thread.trim(toLast: 1)
        #expect(thread.workflowRuns.isEmpty)
        #expect(thread.workflowAgentTranscript(runId: WorkflowSample.runID, agentId: "x") == nil)
    }

    /// An event that changes nothing about a run leaves the runs alone, so the rows reading them
    /// don't redraw.
    @Test func anUnchangedRunIsNotAssignedAgain() {
        let thread = loaded()
        thread.apply(.taskEvent(task("progress", seq: 2, data: ["workflow": WorkflowSample.snapshot(now: 1_000_000, running: true)])))
        let changed = Changed()
        withObservationTracking { _ = thread.workflowRuns } onChange: { changed.happened = true }
        thread.apply(.taskEvent(task("progress", seq: 3)))
        #expect(!changed.happened)
    }

    // MARK: folding

    private func prompt(_ id: String, at ms: Double) -> Item {
        .userMessage(.init(id: id, createdAt: ms, content: [.text(.init(text: id))]))
    }

    private func reply(_ id: String, at ms: Double) -> Item { .agentMessage(.init(id: id, createdAt: ms, text: id)) }

    private func bash(_ id: String, at ms: Double) -> Item {
        .toolCall(.init(id: id, createdAt: ms, name: "Bash", kind: .bash, input: [:], status: .completed))
    }

    private var workflow: Item { .toolCall(call()) }

    @Test func aWorkflowIsAlwaysARowOfItsOwn() {
        let items = [prompt("p", at: 0), bash("b1", at: 1), workflow, bash("b2", at: 3), reply("r", at: 4)]
        for running in [false, true] {
            let rows = foldTranscriptRows(items, folding: .summarized, lastTurnRunning: running)
            #expect(rows.contains { $0.id == WorkflowSample.callID }, "summarized, running: \(running)")
            #expect(!rows.contains { $0.toolGroup?.contains { $0.isWorkflow } == true })
        }
        #expect(foldTranscriptRows(items, folding: .everyCall, lastTurnRunning: false).map(\.id)
            == ["p", "b1", WorkflowSample.callID, "b2", "r"])
    }

    /// Worked For folds the turn's work but lifts its workflow out, after it.
    @Test func workedForLiftsAWorkflowOut() throws {
        let items = [prompt("p", at: 0), bash("b1", at: 1), workflow, bash("b2", at: 3), reply("r", at: 4)]
        let rows = foldTranscriptRows(items, folding: .workedFor, lastTurnRunning: false)
        #expect(rows.map(\.id) == ["p", "work-p", WorkflowSample.callID, "r"])
        guard case .turnWork(_, let work, _) = rows[1] else { Issue.record("no turn work"); return }
        #expect(!work.contains { $0.id == WorkflowSample.callID })
    }

    /// The workflow's result is a message of its own, so the turn after it stands on its own.
    @Test func theResultStartsATurn() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: WorkflowSample.items(now: 1_000_000, running: false), turns: [], seq: 1)
        let rows = thread.rows(.workedFor)
        let ids = rows.map(\.id)
        #expect(ids.contains("wf-result"))
        #expect(!ids.contains("wf-peer"), "an agent's message is filed under the workflow")
        #expect(rows.firstIndex { $0.id == "wf-result" }! < rows.firstIndex { $0.id == "wf-followup" }!)
    }

    // MARK: the wire

    /// A daemon's `task/event.workflow` reaches the app in the event's data, though the protocol
    /// package it was built with predates the member.
    @Test func theSnapshotIsKeptFromTheWire() throws {
        let params = Data(#"{"threadId":"wf","seq":1,"event":"progress","taskId":"t","data":{"task_type":"local_workflow"},"workflow":{"runId":"r1","phases":[],"agents":[]}}"#.utf8)
        let decoder = JSONDecoder()
        let n = try ServerNotification(method: "task/event", params: params, decoder: decoder)
        guard case .taskEvent(let e) = RPCClient.carryingWorkflow(n, params: params, decoder: decoder) else {
            Issue.record("not a task event"); return
        }
        #expect(e.data["workflow"]?["runId"]?.stringValue == "r1")
        #expect(e.data["task_type"]?.stringValue == "local_workflow")
    }

    /// An event whose data isn't an object still carries its snapshot.
    @Test func theSnapshotIsKeptWhenDataIsNotAnObject() throws {
        let params = Data(#"{"threadId":"wf","seq":1,"event":"notification","taskId":"t","data":null,"workflow":{"runId":"r1","status":"completed","phases":[],"agents":[]}}"#.utf8)
        let decoder = JSONDecoder()
        let n = try ServerNotification(method: "task/event", params: params, decoder: decoder)
        guard case .taskEvent(let e) = RPCClient.carryingWorkflow(n, params: params, decoder: decoder) else {
            Issue.record("not a task event"); return
        }
        #expect(e.data["workflow"]?["status"]?.stringValue == "completed")
    }
}
