import Foundation
import Testing
@testable import Relay

@Test("Structured checklist parsing preserves status and separates owners")
func taskPlanDecoding() throws {
    let event: [String: Any] = ["type": "PlanUpdated", "agent_id": "child", "plan": [
        ["step": "Inspect data", "status": "completed"],
        ["step": "Fit model", "status": "in_progress"]]]
    let plan = try #require(AgentTaskPlan.decode(event: event, provider: "codex", now: Date()))
    #expect(plan.id == "codex:child")
    #expect(plan.completedCount == 1)
    #expect(plan.steps.count == 2)
    #expect(AgentTaskPlan.decode(event: ["message": "All tasks completed"], provider: "codex", now: Date()) == nil)
    #expect(AgentTaskPlan.decode(event: ["type": "PlanUpdated", "plan": [["step": "x", "status": "maybe"]]], provider: "codex", now: Date()) == nil)
}

@Test("Claude todos require a successful post-tool event")
func taskPlanClaudeHooks() {
    var event: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "TodoWrite",
                              "tool_input": ["todos": [["content": "Read data", "status": "pending"]]]]
    #expect(AgentTaskPlan.decode(event: event, provider: "claude", now: Date()) == nil)
    event["hook_event_name"] = "PostToolUse"
    #expect(AgentTaskPlan.decode(event: event, provider: "claude", now: Date())?.steps.count == 1)
}

@Test("Claude task deltas preserve identity, reject stale events and remove deleted tasks")
func taskPlanDeltas() throws {
    let now = Date()
    var event: [String: Any] = ["hook_event_name": "TaskChanged", "task_id": "1", "task_subject": "Read data", "task_status": "pending"]
    let created = try #require(AgentTaskPlan.applyingTask(event: event, provider: "claude", plans: [], now: now))
    event["task_status"] = "completed"; event["task_subject"] = ""
    let changed = try #require(AgentTaskPlan.applyingTask(event: event, provider: "claude", plans: [created], now: now.addingTimeInterval(1)))
    #expect(changed.completedCount == 1)
    #expect(changed.steps[0].text == "Read data")
    #expect(AgentTaskPlan.applyingTask(event: event, provider: "claude", plans: [changed], now: now) == nil)
    event["task_status"] = "deleted"
    #expect(AgentTaskPlan.applyingTask(event: event, provider: "claude", plans: [changed], now: now.addingTimeInterval(2))?.steps.isEmpty == true)
}
