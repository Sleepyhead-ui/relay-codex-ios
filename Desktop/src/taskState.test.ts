import { describe, expect, it } from "vitest";
import { createTaskStateCore, decodeTaskRunEvents, idleTaskState, isTaskRunning, reduceTaskRunState, reduceTaskStateCore } from "./taskState";

describe("task run state", () => {
  it("binds plans to the active turn and ignores a stale previous-turn plan", () => {
    let state = reduceTaskRunState(idleTaskState("thread.1"), { type: "started", turnId: "turn.2" });
    state = reduceTaskRunState(state, {
      type: "plan", turnId: "turn.1", plan: [{ id: "turn.1.0", text: "旧步骤", status: "inProgress" }],
    });
    expect(state.plan).toEqual([]);
    state = reduceTaskRunState(state, {
      type: "plan", turnId: "turn.2", plan: [{ id: "turn.2.0", text: "当前步骤", status: "inProgress" }],
    });
    expect(state.plan.map((step) => step.text)).toEqual(["当前步骤"]);
    expect(state.planTurnId).toBe("turn.2");
  });

  it("does not let a late terminal event stop a newer turn", () => {
    const running = reduceTaskRunState(idleTaskState("thread.1"), { type: "started", turnId: "turn.2" });
    const state = reduceTaskRunState(running, { type: "terminal", turnId: "turn.1" });
    expect(state.phase).toBe("running");
    expect(state.turnId).toBe("turn.2");
  });

  it("clears plans when an authoritative new turn starts", () => {
    let state = reduceTaskRunState(idleTaskState("thread.1"), { type: "started", turnId: "turn.1" });
    state = reduceTaskRunState(state, { type: "plan", turnId: "turn.1", plan: [{ id: "1", text: "步骤", status: "pending" }] });
    state = reduceTaskRunState(state, { type: "started", turnId: "turn.2" });
    expect(state.plan).toEqual([]);
    expect(state.turnId).toBe("turn.2");
  });

  it("represents an accepted prompt before its turn id arrives", () => {
    let state = reduceTaskRunState(idleTaskState("thread.1"), { type: "starting" });
    expect(isTaskRunning(state)).toBe(true);
    expect(state.turnId).toBeUndefined();
    state = reduceTaskRunState(state, { type: "progress", turnId: "turn.1" });
    expect(state.phase).toBe("running");
    expect(state.turnId).toBe("turn.1");
  });

  it("does not replay completed turns but permits authoritative running hydration", () => {
    let core = createTaskStateCore();
    core = reduceTaskStateCore(core, "thread.1", { type: "started", turnId: "turn.1" });
    core = reduceTaskStateCore(core, "thread.1", { type: "terminal", turnId: "turn.1" });
    const completed = core.states["thread.1"];
    core = reduceTaskStateCore(core, "thread.1", { type: "progress", turnId: "turn.1" });
    expect(core.states["thread.1"]).toBe(completed);
    core = reduceTaskStateCore(core, "thread.1", { type: "hydrate", running: true, turnId: "turn.1" });
    expect(core.states["thread.1"]?.phase).toBe("running");
  });

  it("decodes plans as progress bound to the current turn", () => {
    const transition = decodeTaskRunEvents("turn/plan/updated", {
      threadId: "thread.1", turnId: "turn.1", plan: [{ step: "检查状态", status: "inProgress" }],
    });
    expect(transition.events.map((event) => event.type)).toEqual(["progress", "plan"]);
  });
});
