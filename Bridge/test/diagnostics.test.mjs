import test from "node:test";
import assert from "node:assert/strict";
import { DiagnosticsLog } from "../dist/diagnostics.js";

function state(overrides = {}) {
  return {
    codexReady: true,
    clients: 1,
    activeTurns: 0,
    pendingRpcCount: 0,
    pendingApprovalCount: 0,
    queuedPromptCount: 0,
    codexRestartAttempt: 0,
    uptimeSeconds: 90,
    desktopSync: {},
    socket: {},
    rpc: {},
    codexProfile: {},
    performance: {},
    ...overrides,
  };
}

test("keeps a bounded newest-first diagnostic timeline", () => {
  const log = new DiagnosticsLog(2);
  log.record("info", "socket", "one");
  log.record("warning", "rpc", "two");
  log.record("error", "codex", "three");
  const report = log.report(state());
  assert.deepEqual(report.events.map((event) => event.message), ["three", "two"]);
});

test("reports degraded state for disconnected clients and pending work", () => {
  const report = new DiagnosticsLog().report(state({ clients: 0, pendingRpcCount: 2, pendingApprovalCount: 1 }));
  assert.equal(report.summary, "warning");
  assert.equal(report.checks.find((check) => check.id === "rpc").level, "warning");
  assert.equal(report.metrics.pendingApprovalCount, 1);
});

test("reports an error when Codex is unavailable without a restart attempt", () => {
  const report = new DiagnosticsLog().report(state({ codexReady: false }));
  assert.equal(report.summary, "error");
  assert.equal(report.checks.find((check) => check.id === "codex").level, "error");
});
