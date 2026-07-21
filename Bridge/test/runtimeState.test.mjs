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

test("returns unknown when the bridge has not observed a thread", () => {
  const tracker = new RuntimeStateTracker();
  const snapshot = tracker.snapshot("thread-missing");
  assert.equal(snapshot.known, false);
  assert.equal(snapshot.isRunning, false);
});

test("external terminal state clears stale runtime state", async () => {
  const tracker = new RuntimeStateTracker();
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
  assert.equal(tracker.activeCount, 0);
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
