import Foundation
import TetherProtocol

/// A dynamic workflow as Claude Code and the daemon report one, for previews and the UI-test
/// fixture's `tasks` scenario: a Workflow call whose input is only its script, which comes back at
/// once with the launch receipt (`async_launched`); the run's tasks, the workflow's and one per
/// agent, as the daemon sends them; the result as a synthetic "workflow" message; and an agent's
/// message to the main session, which the daemon files under the workflow's call so it isn't a line
/// of its own. In every build, as the fixture is.
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
    static func items(now: Double, running: Bool) -> [Item] {
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
        let status: TaskStatus
        var agentId: String?
        var tokens: Double = 0
        var toolCalls: Double = 0
        var lastTool: String?
        var result: String?
    }

    private static func agents(running: Bool) -> [AgentSpec] {
        [
            AgentSpec(label: "TaskTree.swift", phase: 1, status: .done, agentId: "a1f09c3e2b7d", tokens: 18_204, toolCalls: 6,
                      result: "One finding: workflow nodes never have children."),
            AgentSpec(label: "TasksPane.swift", phase: 1, status: .done, agentId: "a2c81d77e019", tokens: 15_877, toolCalls: 4,
                      result: "No findings."),
            AgentSpec(label: "ThreadModel.swift", phase: 1, status: .done, agentId: "a3d5e0b4c6f1", tokens: 21_090, toolCalls: 7,
                      result: "One finding: merged() drops workflow_name."),
            AgentSpec(label: "skeptic 1", phase: 2, status: running ? .running : .done, agentId: "a4b7c2d9e8f0",
                      tokens: running ? 9_310 : 14_388, toolCalls: running ? 3 : 5,
                      lastTool: running ? "Read" : nil, result: running ? nil : "Holds: confirmed at TaskTree.swift:45."),
            AgentSpec(label: "skeptic 2", phase: 2, status: running ? .waiting : .done, agentId: running ? nil : "a5e3f1a0b2c4",
                      tokens: running ? 0 : 12_102, toolCalls: running ? 0 : 3,
                      result: running ? nil : "Holds: workflow_name is lost after the first progress event."),
        ]
    }

    /// The run's tasks as the daemon sends them: the workflow's, and each agent's under it.
    static func tasks(now: Double, running: Bool) -> [TaskState] {
        func ago(_ seconds: Double) -> Double { now - seconds * 1000 }
        let phases = [TaskPhase(index: 1, title: "Review", status: .done),
                      TaskPhase(index: 2, title: "Verify", status: running ? .running : .done)]
        let workflow = TaskState(
            id: callID, toolUseId: callID, taskId: taskID, kind: .workflow, taskType: "local_workflow", title: name,
            status: running ? .running : .done, startedAt: ago(290), endedAt: running ? nil : ago(60),
            summary: running ? nil : "Dynamic workflow \"\(description)\" completed",
            usage: .init(durationMs: running ? 150_000 : 238_000, totalTokens: running ? 64_481 : 81_661, toolUses: running ? 20 : 25),
            workflow: .init(runId: runID, name: name, description: description, phases: phases,
                            activity: running ? "Verify: skeptic 1" : nil, result: running ? nil : result))
        let agents = Self.agents(running: running).enumerated().map { i, a in
            TaskState(
                id: "\(callID)/agent/\(i + 1)", parentId: callID, kind: .workflowAgent, title: a.label, status: a.status,
                startedAt: a.status == .waiting ? nil : ago(a.phase == 1 ? 284 : 148),
                endedAt: a.status == .done ? ago(a.phase == 1 ? 166 : 74) : nil,
                output: a.result,
                usage: .init(durationMs: a.status == .done ? (a.phase == 1 ? 118_000 : 74_000) : nil,
                             totalTokens: a.tokens > 0 ? a.tokens : nil, toolUses: a.toolCalls > 0 ? a.toolCalls : nil),
                workflowAgent: .init(runId: runID, index: i + 1, agentId: a.agentId, phase: a.phase == 1 ? "Review" : "Verify",
                                     phaseIndex: a.phase,
                                     prompt: a.phase == 1 ? "Review \(a.label) for correctness bugs" : "Try to disprove the finding",
                                     model: "claude-sonnet-5", lastToolName: a.lastTool))
        }
        return [workflow] + agents
    }

    /// A background command skeptic 1 ran, which the daemon puts under that agent.
    static func agentCommand(now: Double, running: Bool) -> TaskState {
        TaskState(id: "skeptic-1-bash", parentId: "\(callID)/agent/4", toolUseId: "skeptic-1-bash", taskId: "bg-skeptic-1",
                  kind: .command, taskType: "local_bash", title: "swift test --filter TaskTreeTests",
                  status: running ? .running : .done, startedAt: now - 120_000, endedAt: running ? nil : now - 90_000,
                  backgrounded: true)
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
