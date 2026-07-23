import assert from "node:assert/strict";
import test from "node:test";
import {
  codexRestartDelayMs,
  codexStartupWatchdogMs,
  shouldReplaceUnreadyCodex,
  shouldScheduleCodexRestart,
} from "../dist/restartPolicy.js";

test("backs off Codex restarts and caps the delay", () => {
  const delays = Array.from({ length: 12 }, (_, index) => codexRestartDelayMs(index + 1));
  assert.equal(delays[0], 1_000);
  assert.equal(delays[1], 1_800);
  assert.equal(delays.at(-1), 30_000);
  assert.ok(delays.every((delay, index) => index === 0 || delay >= delays[index - 1]));
  assert.equal(codexRestartDelayMs(0), 1_000);
});

test("does not schedule duplicate, stale, or shutdown restarts", () => {
  const base = { shuttingDown: false, generation: 4, currentGeneration: 4, timerPending: false };
  assert.equal(shouldScheduleCodexRestart(base), true);
  assert.equal(shouldScheduleCodexRestart({ ...base, timerPending: true }), false);
  assert.equal(shouldScheduleCodexRestart({ ...base, generation: 3 }), false);
  assert.equal(shouldScheduleCodexRestart({ ...base, shuttingDown: true }), false);
});

test("startup watchdog replaces only the current unready generation", () => {
  const base = { shuttingDown: false, generation: 4, currentGeneration: 4, ready: false };
  assert.equal(codexStartupWatchdogMs, 30_000);
  assert.equal(shouldReplaceUnreadyCodex(base), true);
  assert.equal(shouldReplaceUnreadyCodex({ ...base, ready: true }), false);
  assert.equal(shouldReplaceUnreadyCodex({ ...base, currentGeneration: 5 }), false);
  assert.equal(shouldReplaceUnreadyCodex({ ...base, shuttingDown: true }), false);
});
