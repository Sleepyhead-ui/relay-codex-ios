import assert from "node:assert/strict";
import test from "node:test";
import { PerformanceMetrics } from "../dist/performanceMetrics.js";

test("reports bounded latency percentiles and session compression", () => {
  const metrics = new PerformanceMetrics();
  metrics.recordInbound(100);
  metrics.recordOutbound({ type: "sessionSnapshot" }, 1_000);
  metrics.recordOutbound({ type: "sessionPatch" }, 100);
  metrics.recordSuppressedSessionUpdate();
  metrics.recordCodexEvent("item/agentMessage/delta");
  for (let value = 1; value <= 300; value += 1) metrics.recordRpcLatency(value);

  const report = metrics.report();
  assert.equal(report.network.inboundMessages, 1);
  assert.equal(report.sessions.patchToSnapshotByteRatio, 0.1);
  assert.equal(report.sessions.suppressedUpdates, 1);
  assert.equal(report.codex.deltas, 1);
  assert.equal(report.rpcLatency.count, 256);
  assert.ok(report.rpcLatency.p95Ms >= 280);
  assert.equal(report.rpcLatency.maxMs, 300);
});
