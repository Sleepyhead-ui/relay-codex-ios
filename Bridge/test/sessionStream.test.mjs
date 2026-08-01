import assert from "node:assert/strict";
import test from "node:test";
import { SessionStream } from "../dist/sessionStream.js";

function snapshot(text, updatedAt) {
  const unchanged = Array.from({ length: 20 }, (_, index) => ({
    id: `unchanged.${index}`,
    type: "agentMessage",
    text: `unchanged progress ${index} ${"x".repeat(80)}`,
  }));
  return {
    known: true,
    isRunning: true,
    updatedAt,
    turnId: "turn.1",
    startedAt: 1,
    items: [{ id: "progress.1", type: "agentMessage", text }, ...unchanged],
  };
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

test("coalesces a slow connection without creating revision gaps", async () => {
  let bufferedAmount = 101;
  const frames = [];
  const observed = { backpressure: 0, coalesced: 0, suppressed: 0, largest: 0 };
  const stream = new SessionStream(
    "thread.1",
    "lease.1",
    true,
    {
      bufferedAmount: () => bufferedAmount,
      send: (message) => {
        frames.push(message);
        return Buffer.byteLength(JSON.stringify(message));
      },
    },
    {
      recordBackpressure: () => { observed.backpressure += 1; },
      recordCoalescedSessionUpdate: () => { observed.coalesced += 1; },
      recordSessionFrame: (bytes) => { observed.largest = Math.max(observed.largest, bytes); },
      recordSuppressedSessionUpdate: () => { observed.suppressed += 1; },
    },
    100,
    2,
  );

  const initial = stream.initialize(snapshot("initial", 1));
  assert.equal(initial.revision, 0);
  stream.enqueue(snapshot("first", 2));
  await delay(4);
  stream.enqueue(snapshot("second", 3));
  stream.enqueue(snapshot("latest", 4));
  bufferedAmount = 0;
  await delay(8);

  assert.ok(observed.backpressure > 0);
  assert.equal(observed.coalesced, 2);
  assert.equal(frames.length, 1);
  assert.equal(frames[0].subscriptionId, "lease.1");
  assert.equal(frames[0].patch.baseRevision, 0);
  assert.equal(frames[0].patch.revision, 1);
  assert.equal(frames[0].patch.upsertItems[0].text, "latest");

  stream.enqueue(snapshot("after", 5));
  await delay(1);
  assert.equal(frames.length, 2);
  assert.equal(frames[1].patch.baseRevision, 1);
  assert.equal(frames[1].patch.revision, 2);
  stream.dispose();
});
