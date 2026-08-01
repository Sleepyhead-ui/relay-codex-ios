import assert from "node:assert/strict";
import test from "node:test";
import { PerformanceMetrics } from "../dist/performanceMetrics.js";

test("reports bounded latency percentiles and session compression", () => {
  const metrics = new PerformanceMetrics();
  metrics.recordInbound(100);
  metrics.recordOutbound({ type: "sessionSnapshot" }, 1_000);
  metrics.recordOutbound({ type: "sessionPatch" }, 100);
  metrics.recordSuppressedSessionUpdate();
  metrics.recordBackpressure(2_000);
  metrics.recordCoalescedSessionUpdate(500);
  metrics.recordSessionFrame(1_200, 2_500);
  metrics.recordCodexEvent("item/agentMessage/delta");
  for (let value = 1; value <= 300; value += 1) metrics.recordRpcLatency(value);

  const report = metrics.report();
  assert.equal(report.network.inboundMessages, 1);
  assert.equal(report.sessions.patchToSnapshotByteRatio, 0.1);
  assert.equal(report.sessions.suppressedUpdates, 1);
  assert.equal(report.sessions.coalescedUpdates, 1);
  assert.equal(report.sessions.supersededEstimatedBytes, 500);
  assert.equal(report.sessions.backpressureEvents, 1);
  assert.equal(report.sessions.maximumSocketBufferedBytes, 2_500);
  assert.equal(report.sessions.largestFrameBytes, 1_200);
  assert.equal(report.codex.deltas, 1);
  assert.equal(report.rpcLatency.count, 256);
  assert.ok(report.rpcLatency.p95Ms >= 280);
  assert.equal(report.rpcLatency.maxMs, 300);
});

test("records a complete turn latency timeline", () => {
  const metrics = new PerformanceMetrics();
  metrics.recordTurnReceived({
    threadId: "thread.1",
    clientUserMessageId: "client.1",
    model: "gpt-5",
    effort: "high",
    summary: "auto",
  });
  metrics.recordTurnForwarded("client.1");
  metrics.recordTurnAccepted("client.1", "turn.1");
  metrics.recordCodexEvent("turn/started", {
    threadId: "thread.1",
    turn: { id: "turn.1" },
  });
  metrics.recordCodexEvent("item/reasoning/summaryTextDelta", {
    threadId: "thread.1",
    turnId: "turn.1",
    delta: "Inspecting state",
  });
  const completed = metrics.recordCodexEvent("turn/completed", {
    threadId: "thread.1",
    turn: { id: "turn.1" },
  });

  assert.ok(completed);
  assert.equal(completed.clientUserMessageId, "client.1");
  assert.equal(completed.turnId, "turn.1");
  assert.equal(completed.firstVisibleMethod, "item/reasoning/summaryTextDelta");
  assert.equal(completed.model, "gpt-5");
  assert.equal(completed.effort, "high");
  assert.equal(completed.summary, "auto");
  for (const key of [
    "receivedToForwardMs",
    "forwardToAcceptedMs",
    "acceptedToStartedMs",
    "startedToFirstEventMs",
    "startedToFirstVisibleMs",
    "totalToFirstVisibleMs",
    "totalDurationMs",
  ]) assert.ok(completed[key] >= 0, `${key} should be recorded`);
  assert.equal(metrics.report().turnLatency.recent.length, 1);
  assert.equal(metrics.report().turnLatency.firstVisible.count, 1);
});

test("does not treat an empty reasoning item as visible output", () => {
  const metrics = new PerformanceMetrics();
  metrics.recordTurnReceived({ threadId: "thread.2", clientUserMessageId: "client.2" });
  metrics.recordTurnForwarded("client.2");
  metrics.recordTurnAccepted("client.2", "turn.2");
  metrics.recordCodexEvent("turn/started", { threadId: "thread.2", turn: { id: "turn.2" } });
  metrics.recordCodexEvent("item/started", {
    threadId: "thread.2",
    turnId: "turn.2",
    item: { id: "reasoning.2", type: "reasoning", summary: [] },
  });
  metrics.recordCodexEvent("item/reasoning/textDelta", {
    threadId: "thread.2",
    turnId: "turn.2",
    delta: "",
  });
  metrics.recordCodexEvent("item/agentMessage/delta", {
    threadId: "thread.2",
    turnId: "turn.2",
    delta: "Visible answer",
  });
  const completed = metrics.recordCodexEvent("turn/completed", {
    threadId: "thread.2",
    turn: { id: "turn.2" },
  });

  assert.equal(completed.firstVisibleMethod, "item/agentMessage/delta");
  assert.ok(completed.startedToFirstEventMs !== null);
  assert.ok(completed.startedToFirstVisibleMs !== null);
});

test("keeps only the latest twenty completed turns", () => {
  const metrics = new PerformanceMetrics();
  for (let index = 0; index < 25; index += 1) {
    const threadId = `thread.${index}`;
    const clientId = `client.${index}`;
    const turnId = `turn.${index}`;
    metrics.recordTurnReceived({ threadId, clientUserMessageId: clientId });
    metrics.recordTurnForwarded(clientId);
    metrics.recordTurnAccepted(clientId, turnId);
    metrics.recordCodexEvent("turn/started", { threadId, turn: { id: turnId } });
    metrics.recordCodexEvent("item/agentMessage/delta", { threadId, turnId, delta: "ok" });
    metrics.recordCodexEvent("turn/completed", { threadId, turn: { id: turnId } });
  }

  const recent = metrics.report().turnLatency.recent;
  assert.equal(recent.length, 20);
  assert.equal(recent[0].turnId, "turn.24");
  assert.equal(recent[19].turnId, "turn.5");
});

test("rejected and duplicate requests do not leave stale trackers", () => {
  const metrics = new PerformanceMetrics();
  metrics.recordTurnReceived({ threadId: "thread.reject", clientUserMessageId: "client.reject" });
  metrics.recordTurnForwarded("client.reject");
  metrics.recordTurnRejected("client.reject");
  metrics.recordTurnRejected("client.reject");
  metrics.recordCodexEvent("turn/started", { threadId: "thread.reject", turn: { id: "turn.reject" } });
  metrics.recordCodexEvent("item/agentMessage/delta", {
    threadId: "thread.reject",
    turnId: "turn.reject",
    delta: "must not be tracked",
  });
  metrics.recordCodexEvent("turn/completed", { threadId: "thread.reject", turn: { id: "turn.reject" } });

  assert.equal(metrics.report().turnLatency.recent.length, 0);
});
