import assert from "node:assert/strict";
import test from "node:test";
import { queuedPromptWaitSatisfied } from "../dist/queueDispatchPolicy.js";

const prompt = { waitForTurnId: "turn.active", createdAt: 200 };

test("keeps a queued prompt editable while its active turn is still running", () => {
  assert.equal(queuedPromptWaitSatisfied(prompt, {
    known: true,
    isRunning: true,
    turnId: "turn.active",
    startedAt: 100,
  }), false);
});

test("releases a queued prompt only after its active turn is confirmed terminal", () => {
  assert.equal(queuedPromptWaitSatisfied(prompt, {
    known: true,
    isRunning: false,
    turnId: "turn.active",
    startedAt: 100,
  }), true);
  assert.equal(queuedPromptWaitSatisfied(prompt, {
    known: false,
    isRunning: false,
  }), false);
});

test("accepts a matching terminal event or a later observed turn", () => {
  assert.equal(queuedPromptWaitSatisfied(prompt, {
    known: false,
    isRunning: false,
  }, "turn.active"), true);
  assert.equal(queuedPromptWaitSatisfied(prompt, {
    known: true,
    isRunning: false,
    turnId: "turn.later",
    startedAt: 220,
  }), true);
});
