import assert from "node:assert/strict";
import test from "node:test";
import { awaitFinalAnswer, finalAnswerText } from "../dist/completionPreview.js";

test("selects the newest final assistant answer", () => {
  assert.equal(finalAnswerText([
    { type: "agentMessage", phase: "commentary", text: "working" },
    { type: "agentMessage", phase: "final_answer", text: "first" },
    { type: "agentMessage", phase: "final_answer", text: "latest" },
  ]), "latest");
});

test("waits for the shared rollout to receive the final answer", async () => {
  const snapshots = [
    { turnId: "turn.1", items: [{ type: "agentMessage", phase: "commentary", text: "working" }] },
    { turnId: "turn.1", items: [{ type: "agentMessage", phase: "final_answer", text: "completed summary" }] },
  ];
  let reads = 0;
  const answer = await awaitFinalAnswer({
    turnId: "turn.1",
    loadSnapshot: async () => snapshots[Math.min(reads++, snapshots.length - 1)],
    retryDelaysMs: [0, 1],
    wait: async () => {},
  });

  assert.equal(answer, "completed summary");
  assert.equal(reads, 2);
});

test("does not use the final answer from a different turn", async () => {
  const answer = await awaitFinalAnswer({
    turnId: "turn.1",
    loadSnapshot: async () => ({
      turnId: "turn.2",
      items: [{ type: "agentMessage", phase: "final_answer", text: "wrong turn" }],
    }),
    retryDelaysMs: [0],
  });
  assert.equal(answer, undefined);
});
