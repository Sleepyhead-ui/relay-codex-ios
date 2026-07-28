import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { DiagnosticsLog } from "../dist/diagnostics.js";

function state(overrides = {}) {
  return {
    codexReady: true,
    clients: 1,
    activeTurns: 0,
    activeTransferCount: 0,
    pendingRpcCount: 0,
    pendingApprovalCount: 0,
    queuedPromptCount: 0,
    pendingDeliveryCount: 0,
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
  const report = new DiagnosticsLog().report(state({ clients: 0, pendingRpcCount: 2, pendingApprovalCount: 1, activeTransferCount: 1 }));
  assert.equal(report.summary, "warning");
  assert.equal(report.checks.find((check) => check.id === "rpc").level, "warning");
  assert.equal(report.metrics.pendingApprovalCount, 1);
  assert.equal(report.checks.find((check) => check.id === "transfer").level, "warning");
});

test("reports an error when Codex is unavailable without a restart attempt", () => {
  const report = new DiagnosticsLog().report(state({ codexReady: false }));
  assert.equal(report.summary, "error");
  assert.equal(report.checks.find((check) => check.id === "codex").level, "error");
});

test("restores diagnostic history after a Bridge restart", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-diagnostics-"));
  const storage = path.join(directory, "diagnostics.json");
  try {
    const first = new DiagnosticsLog(10, storage);
    first.record("warning", "codex", "Codex restarted");
    first.record("error", "socket", "Client disconnected");
    await first.flush();

    const restored = new DiagnosticsLog(10, storage);
    await restored.restore();
    const report = restored.report(state());
    assert.deepEqual(report.events.map((event) => event.message), ["Client disconnected", "Codex restarted"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("truncates restored diagnostic history to the configured limit", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-diagnostics-limit-"));
  const storage = path.join(directory, "diagnostics.json");
  try {
    const first = new DiagnosticsLog(2, storage);
    first.record("info", "test", "one");
    first.record("info", "test", "two");
    first.record("info", "test", "three");
    await first.flush();

    const restored = new DiagnosticsLog(2, storage);
    await restored.restore();
    assert.deepEqual(restored.report(state()).events.map((event) => event.message), ["three", "two"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
