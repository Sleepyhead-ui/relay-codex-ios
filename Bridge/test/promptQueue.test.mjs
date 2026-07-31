import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { PromptQueue } from "../dist/promptQueue.js";

test("persists queued prompts and preserves their order across restarts", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-prompt-queue-"));
  const storage = path.join(directory, "queue.json");
  try {
    const queue = await PromptQueue.create(storage);
    const first = await queue.enqueue({ profileId: "profile.1", threadId: "thread.1", text: "first", input: [{ type: "text", text: "first" }] });
    const second = await queue.enqueue({ profileId: "profile.1", threadId: "thread.1", text: "second", input: [{ type: "text", text: "second" }] });
    const restored = await PromptQueue.create(storage);
    assert.deepEqual(restored.list("profile.1", "thread.1").map((item) => item.text), ["first", "second"]);
    assert.equal(restored.peek("profile.1", "thread.1")?.id, first.id);
    assert.equal(await restored.remove(first.id), true);
    assert.equal(restored.peek("profile.1", "thread.1")?.id, second.id);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("keeps queues for different tasks independent", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-prompt-threads-"));
  try {
    const queue = await PromptQueue.create(path.join(directory, "queue.json"));
    await queue.enqueue({ profileId: "profile.1", threadId: "thread.1", input: [{ type: "text", text: "one" }] });
    await queue.enqueue({ profileId: "profile.2", threadId: "thread.2", input: [{ type: "text", text: "two" }] });
    assert.equal(queue.list("profile.1", "thread.1").length, 1);
    assert.equal(queue.list("profile.2", "thread.2").length, 1);
    assert.equal(queue.list("profile.1", "thread.2").length, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("serializes concurrent persistence without losing prompts", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-prompt-concurrent-"));
  const storage = path.join(directory, "queue.json");
  try {
    const queue = await PromptQueue.create(storage);
    await Promise.all([
      queue.enqueue({ profileId: "profile.1", threadId: "thread.1", text: "first", input: [{ type: "text", text: "first" }] }),
      queue.enqueue({ profileId: "profile.1", threadId: "thread.1", text: "second", input: [{ type: "text", text: "second" }] }),
    ]);
    const restored = await PromptQueue.create(storage);
    assert.deepEqual(restored.list("profile.1", "thread.1").map((item) => item.text), ["first", "second"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("edits a queued prompt in place without changing its order or identity", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-prompt-edit-"));
  const storage = path.join(directory, "queue.json");
  try {
    const queue = await PromptQueue.create(storage);
    const first = await queue.enqueue({ profileId: "profile.1", threadId: "thread.1", text: "before", input: [{ type: "text", text: "before" }] });
    const second = await queue.enqueue({ profileId: "profile.1", threadId: "thread.1", text: "second", input: [{ type: "text", text: "second" }] });
    const updated = await queue.update("profile.1", first.id, {
      text: "after",
      input: [{ type: "text", text: "after" }, { type: "mention", name: "notes.txt", path: "C:\\notes.txt" }],
    });
    assert.equal(updated?.id, first.id);
    assert.equal(updated?.createdAt, first.createdAt);
    assert.deepEqual(queue.list("profile.1", "thread.1").map((item) => item.id), [first.id, second.id]);
    assert.equal(queue.peek("profile.1", "thread.1")?.text, "after");
    assert.equal((await PromptQueue.create(storage)).peek("profile.1", "thread.1")?.input.length, 2);
    assert.equal(await queue.update("profile.2", first.id, { text: "blocked", input: [{ type: "text", text: "blocked" }] }), undefined);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("persists the active turn a prompt must wait for", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-prompt-wait-turn-"));
  const storage = path.join(directory, "queue.json");
  try {
    const queue = await PromptQueue.create(storage);
    const queued = await queue.enqueue({
      profileId: "profile.1",
      threadId: "thread.1",
      waitForTurnId: "turn.active",
      text: "next",
      input: [{ type: "text", text: "next" }],
    });
    assert.equal(queued.waitForTurnId, "turn.active");
    assert.equal((await PromptQueue.create(storage)).peek("profile.1", "thread.1")?.waitForTurnId, "turn.active");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
