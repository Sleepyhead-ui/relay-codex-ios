import test from "node:test";
import assert from "node:assert/strict";
import { RuntimeStateTracker } from "../dist/runtimeState.js";

test("tracks an active turn from the turn/start response", () => {
  const tracker = new RuntimeStateTracker();
  tracker.observeTurnStart("thread-1", { id: "turn-1", startedAt: 123 });
  assert.deepEqual(tracker.snapshot("thread-1"), {
    known: true,
    isRunning: true,
    activeTurnId: "turn-1",
    startedAt: 123,
    updatedAt: tracker.snapshot("thread-1").updatedAt,
  });
  assert.equal(tracker.activeCount, 1);
});

test("marks only the matching active turn completed", () => {
  const tracker = new RuntimeStateTracker();
  tracker.observeTurnStart("thread-1", { id: "turn-2" });
  tracker.observeNotification({
    method: "turn/completed",
    params: { threadId: "thread-1", turn: { id: "older-turn", status: "completed" } },
  });
  assert.equal(tracker.snapshot("thread-1").isRunning, true);
  tracker.observeNotification({
    method: "turn/completed",
    params: { threadId: "thread-1", turn: { id: "turn-2", status: "completed" } },
  });
  assert.deepEqual(tracker.snapshot("thread-1").isRunning, false);
  assert.equal(tracker.activeCount, 0);
});

test("restores first activity time, plan, and diff while a turn remains active", () => {
  let now = 200;
  const tracker = new RuntimeStateTracker(() => now);
  tracker.observeTurnStart("thread-live", { id: "turn-live", startedAt: 100 });
  tracker.observeNotification({
    method: "item/agentMessage/delta",
    params: { threadId: "thread-live", turnId: "turn-live", phase: "commentary", delta: "checking" },
  });
  now = 220;
  tracker.observeNotification({
    method: "turn/plan/updated",
    params: { threadId: "thread-live", turnId: "turn-live", plan: [{ step: "Inspect", status: "completed" }] },
  });
  now = 230;
  tracker.observeNotification({
    method: "turn/diff/updated",
    params: {
      threadId: "thread-live",
      turnId: "turn-live",
      diff: "diff --git a/App.swift b/App.swift\n--- a/App.swift\n+++ b/App.swift\n@@ -1,2 +1,3 @@\n-old\n+new\n+added",
    },
  });
  assert.deepEqual(tracker.snapshot("thread-live"), {
    known: true,
    isRunning: true,
    activeTurnId: "turn-live",
    startedAt: 100,
    outputStartedAt: 200,
    plan: [{ step: "Inspect", status: "completed" }],
    diffStatistics: {
      added: 2,
      removed: 1,
      files: [{ path: "App.swift", added: 2, removed: 1 }],
    },
    updatedAt: 230,
  });
});

test("does not start output timing for an empty assistant item", () => {
  const tracker = new RuntimeStateTracker(() => 200);
  tracker.observeTurnStart("thread-thinking", { id: "turn-thinking", startedAt: 100 });
  tracker.observeNotification({
    method: "item/started",
    params: { threadId: "thread-thinking", turnId: "turn-thinking", item: { type: "agentMessage", phase: "final_answer" } },
  });
  assert.equal(tracker.snapshot("thread-thinking").outputStartedAt, undefined);
});

test("returns unknown when the bridge has not observed a thread", () => {
  const tracker = new RuntimeStateTracker();
  const snapshot = tracker.snapshot("thread-missing");
  assert.equal(snapshot.known, false);
  assert.equal(snapshot.isRunning, false);
});

test("external terminal state clears stale runtime state", async () => {
  const tracker = new RuntimeStateTracker(() => 100);
  tracker.observeTurnStart("thread-stale", { id: "turn-stale", startedAt: 100 });
  const external = {
    snapshot: async () => ({
      active: false,
      turnId: "turn-stale",
      updatedAt: 200,
    }),
  };
  const snapshot = await tracker.snapshotWithExternal("thread-stale", external);
  assert.equal(snapshot.known, true);
  assert.equal(snapshot.isRunning, false);
  assert.equal(snapshot.observedTurnId, "turn-stale");
  assert.equal(tracker.activeCount, 0);
});

test("reconciles an already-read external observation without another tracker read", () => {
  const tracker = new RuntimeStateTracker(() => 100);
  const snapshot = tracker.snapshotWithObservation("thread-external", {
    active: true,
    turnId: "turn-external",
    startedAt: 80,
    updatedAt: 90,
  });
  assert.deepEqual(snapshot, {
    known: true,
    isRunning: true,
    activeTurnId: "turn-external",
    startedAt: 80,
    updatedAt: 100,
  });
  assert.equal(tracker.activeCount, 1);

  tracker.observeNotification({
    method: "item/reasoning/summaryTextDelta",
    params: { threadId: "thread-external", turnId: "turn-external", delta: "Recovered activity" },
  });
  assert.equal(tracker.snapshot("thread-external").outputStartedAt, 100);
});

test("ignores activity from a stale turn after external recovery", () => {
  const tracker = new RuntimeStateTracker(() => 100);
  tracker.snapshotWithObservation("thread-external", {
    active: true,
    turnId: "turn-current",
    startedAt: 80,
    updatedAt: 90,
  });

  tracker.observeNotification({
    method: "turn/diff/updated",
    params: { threadId: "thread-external", turnId: "turn-old", diff: "+stale" },
  });

  assert.equal(tracker.snapshot("thread-external").outputStartedAt, undefined);
  assert.equal(tracker.snapshot("thread-external").diffStatistics, undefined);
});

test("stale external terminal state cannot clear a fresh active runtime", async () => {
  const tracker = new RuntimeStateTracker(() => 200);
  tracker.observeTurnStart("thread-active", { id: "turn-active", startedAt: 200 });
  const external = {
    snapshot: async () => ({
      active: false,
      turnId: "turn-active",
      updatedAt: 100,
    }),
  };
  const snapshot = await tracker.snapshotWithExternal("thread-active", external);
  assert.equal(snapshot.isRunning, true);
  assert.equal(snapshot.activeTurnId, "turn-active");
  assert.equal(tracker.activeCount, 1);
});

test("terminal state from another turn cannot clear the active turn", async () => {
  const tracker = new RuntimeStateTracker(() => 200);
  tracker.observeTurnStart("thread-active", { id: "turn-new", startedAt: 200 });
  const external = {
    snapshot: async () => ({ active: false, turnId: "turn-old", updatedAt: 300 }),
  };
  const snapshot = await tracker.snapshotWithExternal("thread-active", external);
  assert.equal(snapshot.isRunning, true);
  assert.equal(snapshot.activeTurnId, "turn-new");
});

test("marks aborted notifications terminal", () => {
  const tracker = new RuntimeStateTracker();
  tracker.observeTurnStart("thread-aborted", { id: "turn-aborted" });
  tracker.observeNotification({
    method: "turn/aborted",
    params: { threadId: "thread-aborted", turnId: "turn-aborted" },
  });
  assert.equal(tracker.snapshot("thread-aborted").isRunning, false);
});

test("tracks a retryable upstream error without stopping the turn", () => {
  const tracker = new RuntimeStateTracker();
  tracker.observeTurnStart("thread-retry", { id: "turn-retry" });
  tracker.observeNotification({
    method: "error",
    params: {
      threadId: "thread-retry",
      turnId: "turn-retry",
      willRetry: true,
      error: { message: "stream disconnected" },
    },
  });
  assert.equal(tracker.snapshot("thread-retry").isRunning, true);
  assert.equal(tracker.snapshot("thread-retry").upstreamRetrying, true);
  assert.equal(tracker.snapshot("thread-retry").upstreamError, "stream disconnected");

  tracker.observeNotification({
    method: "item/agentMessage/delta",
    params: { threadId: "thread-retry", turnId: "turn-retry", delta: "resumed" },
  });
  assert.equal(tracker.snapshot("thread-retry").upstreamRetrying, undefined);
});

test("marks a non-retryable upstream error terminal", () => {
  const tracker = new RuntimeStateTracker();
  tracker.observeTurnStart("thread-failed", { id: "turn-failed" });
  tracker.observeNotification({
    method: "error",
    params: {
      threadId: "thread-failed",
      turnId: "turn-failed",
      willRetry: false,
      error: { message: "too many failed attempts" },
    },
  });
  const snapshot = tracker.snapshot("thread-failed");
  assert.equal(snapshot.isRunning, false);
  assert.equal(snapshot.upstreamRetrying, undefined);
  assert.equal(snapshot.upstreamError, "too many failed attempts");
  assert.equal(tracker.activeCount, 0);
});

test("stops every active turn when the app server exits", () => {
  const tracker = new RuntimeStateTracker();
  tracker.observeTurnStart("thread.1", { id: "turn.1", startedAt: 100 });
  tracker.observeTurnStart("thread.2", { id: "turn.2", startedAt: 200 });
  tracker.stopAll("Codex App Server exited.");
  assert.equal(tracker.activeCount, 0);
  assert.deepEqual(tracker.snapshot("thread.1"), {
    known: true,
    isRunning: false,
    upstreamError: "Codex App Server exited.",
    updatedAt: tracker.snapshot("thread.1").updatedAt,
  });
});
