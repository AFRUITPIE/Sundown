import Foundation
import TetherProtocol

/// A dynamic workflow as Claude Code and the daemon report one, for previews and the UI-test
/// fixture's `tasks` scenario: a Workflow call whose input is only its script, which comes back at
/// once with the launch receipt (`async_launched`); a `local_workflow` task whose progress events
/// carry the run's snapshot now and then and nothing between; the task's notification; the result
/// as a synthetic "workflow" message; and an agent's message to the main session, which the daemon
/// files under the workflow's call so it isn't a line of its own. In every build, as the fixture is.
enum WorkflowSample {
    static let callID = "workflow-call"
    static let taskID = "wf-1"
    static let runID = "wfr_8c2e41d0"
    static let name = "review-diff"
    static let description = "Review the diff for correctness, then verify each finding"

    static let script = """
    export const meta = {
      name: 'review-diff',
      description: 'Review the diff for correctness, then verify each finding',
      phases: [
        { title: 'Review', detail: 'One reviewer per changed file' },
        { title: 'Verify', detail: 'Three skeptics per finding' },
      ],
    }

    const files = ['TaskTree.swift', 'TasksPane.swift', 'ThreadModel.swift']
    const reviews = await phase('Review', () =>
      parallel(files.map((file) => agent(`Review ${file} for correctness bugs`, { label: file }))))
    const findings = reviews.flatMap((r) => r.findings ?? [])
    const verified = await phase('Verify', () =>
      parallel(findings.map((f, i) => agent(`Try to disprove: ${f.summary}`, { label: `skeptic ${i + 1}` }))))
    return { findings: findings.filter((_, i) => verified[i].holds) }
    """

    static let result = """
    {
      "findings": [
        {"file": "TaskTree.swift", "line": 45, "summary": "A workflow node never has children: agents aren't linked by parentToolUseId"},
        {"file": "ThreadModel.swift", "line": 489, "summary": "merged() drops workflow_name after the first progress event"}
      ]
    }
    """

    static var launchText: String {
        """
        Workflow launched in background. Task ID: \(taskID)
        Script: /tmp/sundown-fixture/.claude/workflows/review-diff.js
        Run ID: \(runID)
        To resume after editing the script: Workflow({scriptPath: "/tmp/sundown-fixture/.claude/workflows/review-diff.js", resumeFromRunId: "\(runID)"})

        You will be notified when it completes. Use /workflows to watch live progress.
        """
    }

    /// The chat: a prompt, the Workflow call, Claude's word that it's running, and once it has
    /// finished, its result and Claude's reply to it.
    static func items(now: Double, running: Bool, threadID: String = "") -> [Item] {
        func ago(_ seconds: Double) -> Double { now - seconds * 1000 }
        var items: [Item] = [
            .userMessage(.init(id: "wf-prompt", createdAt: ago(300),
                               content: [.text(.init(text: "Review the diff with a workflow, and verify what it finds."))])),
            .toolCall(.init(id: callID, createdAt: ago(290), name: "Workflow", kind: .other, input: ["script": .string(script)],
                            status: .completed, outputText: launchText,
                            output: ["status": "async_launched", "taskId": .string(taskID), "runId": .string(runID),
                                     "taskType": "local_workflow", "workflowName": .string(name)])),
            .agentMessage(.init(id: "wf-started-reply", createdAt: ago(288),
                                text: "The review workflow is running: a reviewer per changed file, then three skeptics per finding. I’ll go through what it finds when it’s done.")),
            // An agent's message to the main session, filed under the workflow's call.
            .userMessage(.init(id: "wf-peer", parentToolUseId: callID, createdAt: ago(200),
                               content: [.text(.init(text: "Reviewer for TaskTree.swift: found one issue, details in my result."))],
                               synthetic: true, origin: "peer", originName: "a1f09c3e2b7d")),
        ]
        if !running {
            items += [
                .userMessage(.init(id: "wf-result", createdAt: ago(60), content: [.text(.init(text: result))],
                                   synthetic: true, origin: "workflow", originName: name)),
                .agentMessage(.init(id: "wf-followup", createdAt: ago(50),
                                    text: "The workflow confirmed two findings. The first is why workflows look empty in Tasks: `TaskNode.tree` links children only through `parentToolUseId`.")),
            ]
        }
        return items
    }

    private struct AgentSpec {
        let label: String
        let phase: Int
        let state: String
        var agentId: String?
        var tokens: Double = 0
        var toolCalls: Double = 0
        var queuedOnly = false
        var lastTool: (String, String)?
        var result: String?
    }

    private static func agents(running: Bool) -> [AgentSpec] {
        [
            AgentSpec(label: "TaskTree.swift", phase: 1, state: "done", agentId: "a1f09c3e2b7d", tokens: 18_204, toolCalls: 6,
                      result: "One finding: workflow nodes never have children."),
            AgentSpec(label: "TasksPane.swift", phase: 1, state: "done", agentId: "a2c81d77e019", tokens: 15_877, toolCalls: 4,
                      result: "No findings."),
            AgentSpec(label: "ThreadModel.swift", phase: 1, state: "done", agentId: "a3d5e0b4c6f1", tokens: 21_090, toolCalls: 7,
                      result: "One finding: merged() drops workflow_name."),
            AgentSpec(label: "skeptic 1", phase: 2, state: running ? "progress" : "done", agentId: "a4b7c2d9e8f0",
                      tokens: running ? 9_310 : 14_388, toolCalls: running ? 3 : 5,
                      lastTool: running ? ("Read", "TaskTree.swift") : nil, result: running ? nil : "Holds: confirmed at TaskTree.swift:45."),
            AgentSpec(label: "skeptic 2", phase: 2, state: running ? "start" : "done", agentId: running ? nil : "a5e3f1a0b2c4",
                      tokens: running ? 0 : 12_102, toolCalls: running ? 0 : 3, queuedOnly: running,
                      result: running ? nil : "Holds: workflow_name is lost after the first progress event."),
        ]
    }

    /// The run as the daemon's snapshot says it (`task/event.workflow`, `workflow/read`).
    static func snapshot(now: Double, running: Bool) -> JSONValue {
        func ago(_ seconds: Double) -> Double { now - seconds * 1000 }
        let agents: [JSONValue] = Self.agents(running: running).enumerated().map { i, a in
            var o: [String: JSONValue] = [
                "index": .number(Double(i + 1)), "label": .string(a.label), "phaseIndex": .number(Double(a.phase)),
                "phaseTitle": .string(a.phase == 1 ? "Review" : "Verify"), "state": .string(a.state),
                "queuedAt": .number(ago(a.phase == 1 ? 285 : 150)), "model": "claude-sonnet-5",
                "promptPreview": .string(a.phase == 1 ? "Review \(a.label) for correctness bugs" : "Try to disprove the finding"),
                "lastProgressAt": .number(ago(a.state == "done" ? 160 : 4)),
            ]
            if !a.queuedOnly { o["startedAt"] = .number(ago(a.phase == 1 ? 284 : 148)) }
            if let id = a.agentId { o["agentId"] = .string(id) }
            if a.tokens > 0 { o["tokens"] = .number(a.tokens) }
            if a.toolCalls > 0 { o["toolCalls"] = .number(a.toolCalls) }
            if a.state == "done" { o["durationMs"] = .number(a.phase == 1 ? 118_000 : 74_000) }
            if let (tool, summary) = a.lastTool { o["lastToolName"] = .string(tool); o["lastToolSummary"] = .string(summary) }
            if let r = a.result { o["resultPreview"] = .string(r) }
            return .object(o)
        }
        var snapshot: [String: JSONValue] = [
            "runId": .string(runID), "name": .string(name), "description": .string(description),
            "status": running ? "running" : "completed",
            "phases": [
                ["index": 1, "title": "Review", "detail": "One reviewer per changed file"],
                ["index": 2, "title": "Verify", "detail": "Three skeptics per finding"],
            ],
            "agents": .array(agents),
            "totalTokens": running ? 64_481 : 81_661, "toolUses": running ? 20 : 25,
        ]
        if running {
            snapshot["activity"] = "Verify: skeptic 1"
        } else {
            snapshot["durationMs"] = 238_000
            snapshot["result"] = .string(result)
        }
        return .object(snapshot)
    }

    /// The task's events: started, progress with a snapshot, progress without one (throttled), and
    /// once it has finished, its notification.
    static func events(threadID: String, firstSeq: Int, now: Double, running: Bool) -> [TaskEventNotification] {
        var seq = firstSeq
        func event(_ name: String, status: String, summary: String? = nil, data: [String: JSONValue]) -> TaskEventNotification {
            defer { seq += 1 }
            var data = data
            data["task_type"] = "local_workflow"
            return TaskEventNotification(threadId: threadID, seq: seq, event: name, taskId: taskID, toolUseId: callID,
                                         description: name == "started" ? description : nil, status: status, summary: summary,
                                         data: .object(data))
        }
        let snapshot = snapshot(now: now, running: running)
        var events = [
            event("started", status: "running", data: ["workflow_name": .string(name), "workflow": snapshot.with(agents: [])]),
            event("progress", status: "running", data: ["workflow": snapshot,
                                                        "usage": ["total_tokens": 64_481, "tool_uses": 20, "duration_ms": 150_000]]),
            // Throttled: no snapshot; the last one still holds.
            event("progress", status: "running", data: ["usage": ["total_tokens": 64_900, "tool_uses": 20, "duration_ms": 152_000]]),
        ]
        if !running {
            events.append(event("notification", status: "completed", summary: "Dynamic workflow \"\(description)\" completed",
                                data: ["workflow": snapshot,
                                       "usage": ["total_tokens": 81_661, "tool_uses": 25, "duration_ms": 238_000]]))
        }
        return events
    }

    /// A background command skeptic 1 ran, as the daemon reports a workflow agent's own task: the
    /// CLI's `owned_by_subagent`, and which run and agent it was, on every event.
    static func agentCommandEvents(threadID: String, firstSeq: Int, running: Bool) -> [TaskEventNotification] {
        func event(_ name: String, seq: Int, status: String, data: [String: JSONValue] = [:]) -> TaskEventNotification {
            TaskEventNotification(threadId: threadID, seq: seq, event: name, taskId: "bg-skeptic-1", toolUseId: "skeptic-1-bash",
                                  description: name == "started" ? "swift test --filter TaskTreeTests" : nil, status: status,
                                  ownedBySubagent: true, workflowToolUseId: callID, workflowAgentId: "a4b7c2d9e8f0",
                                  data: .object(data.merging(["task_type": "local_bash"]) { a, _ in a }))
        }
        var events = [event("started", seq: firstSeq, status: "running", data: ["owned_by_subagent": true, "is_backgrounded": true])]
        if !running { events.append(event("notification", seq: firstSeq + 1, status: "completed")) }
        return events
    }

    /// One agent's transcript, as `workflow/agentItems` itemizes it.
    static func agentItems(agentId: String, now: Double) -> [Item] {
        func ago(_ seconds: Double) -> Double { now - seconds * 1000 }
        let label = agents(running: false).first { $0.agentId == agentId }?.label ?? "TaskTree.swift"
        let root = "/tmp/sundown-fixture/SundownKit/Sources/SundownUI/Panes/"
        return [
            .userMessage(.init(id: "\(agentId)-prompt", createdAt: ago(284),
                               content: [.text(.init(text: "Review \(label) for correctness bugs. Return {findings: [{file, line, summary}]}."))])),
            .toolCall(.init(id: "\(agentId)-read", createdAt: ago(280), name: "Read", kind: .fileRead,
                            input: ["file_path": .string(root + label)], status: .completed)),
            .toolCall(.init(id: "\(agentId)-grep", createdAt: ago(250), name: "Grep", kind: .grep,
                            input: ["pattern": "parentToolUseId", "path": .string(root)], status: .completed,
                            outputText: "TaskTree.swift:62\nTaskTree.swift:64")),
            .agentMessage(.init(id: "\(agentId)-reply", createdAt: ago(170),
                                text: "One finding. `TaskNode.tree` attaches a child only when its call's `parentToolUseId` is the parent's call, and a workflow's agents have no calls in the stream, so a workflow is always a leaf.")),
        ]
    }
}

private extension JSONValue {
    /// The snapshot with its agents replaced: the run as it starts.
    func with(agents: [JSONValue]) -> JSONValue {
        guard case .object(var o) = self else { return self }
        o["agents"] = .array(agents)
        o["status"] = "running"
        o["result"] = nil
        o["durationMs"] = nil
        o["activity"] = nil
        return .object(o)
    }
}
