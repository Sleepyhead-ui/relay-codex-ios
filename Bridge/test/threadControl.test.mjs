import assert from "node:assert/strict";
import test from "node:test";
import { canRestartForWriterRelease, ThreadControlRegistry } from "../dist/threadControl.js";

test("tracks Relay writer ownership separately from external activity", () => {
  const control = new ThreadControlRegistry();
  assert.deepEqual(control.status("thread.1"), { mode: "unowned" });
  assert.deepEqual(control.status("thread.1", true), { mode: "external-read-only", reason: "active-writer" });

  assert.equal(control.markOwned("thread.1"), true);
  assert.equal(control.markOwned("thread.1"), false);
  assert.deepEqual(control.status("thread.1", true), { mode: "relay-write" });
  assert.equal(control.requestRelease("thread.1"), true);
  assert.deepEqual(control.pendingReleaseIds, ["thread.1"]);
  assert.deepEqual(control.reset(), ["thread.1"]);
  assert.equal(control.hasPendingRelease, false);
});

test("writer release waits until every App Server consumer is idle", () => {
  const idle = {
    activeTurns: 0,
    pendingClientRequests: 0,
    pendingInternalRequests: 0,
    pendingServerRequests: 0,
    pendingDeliveries: 0,
    dispatchingQueues: 0,
    queuedPrompts: 0,
    acquiringThreads: 0,
    recoveringDeliveries: false,
    configurationReloading: false,
  };
  assert.equal(canRestartForWriterRelease(idle), true);
  for (const key of Object.keys(idle)) {
    const blocked = { ...idle, [key]: typeof idle[key] === "boolean" ? true : 1 };
    assert.equal(canRestartForWriterRelease(blocked), false, key);
  }
});
