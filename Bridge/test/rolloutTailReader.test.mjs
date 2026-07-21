import assert from "node:assert/strict";
import test from "node:test";
import { appendFile, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { RolloutTailReader } from "../dist/rolloutTailReader.js";

function event(payload, type = "event_msg") {
  return `${JSON.stringify({ timestamp: new Date().toISOString(), type, payload })}\n`;
}

function parseItem(payload, fallbackId) {
  if (payload.type !== "message") return null;
  return { id: payload.id || fallbackId, type: "agentMessage", text: payload.text || "", phase: payload.phase };
}

test("starts near the latest turn instead of reading a large rollout from the beginning", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-tail-reader-"));
  const file = path.join(directory, "rollout.jsonl");
  try {
    const oldTurn = event({ type: "task_started", turn_id: "old.turn" });
    const largeHistory = `${oldTurn}${'{"type":"history"}\n'.repeat(180_000)}`;
    const latest = event({ type: "task_started", turn_id: "latest.turn" })
      + event({ type: "message", id: "latest.message", text: "latest" }, "response_item");
    await writeFile(file, largeHistory + latest, "utf8");
    const reader = new RolloutTailReader(file, parseItem);
    const snapshot = await reader.read((await stat(file)).size);
    assert.equal(snapshot.turnId, "latest.turn");
    assert.deepEqual(snapshot.items.map((item) => item.text), ["latest"]);
    assert.ok(reader.bytesRead < 16 * 1024, `expected a small tail read, got ${reader.bytesRead} bytes`);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("reads only appended bytes and resets when a new turn starts", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-tail-append-"));
  const file = path.join(directory, "rollout.jsonl");
  try {
    await writeFile(file, event({ type: "task_started", turn_id: "turn.1" }), "utf8");
    const reader = new RolloutTailReader(file, parseItem);
    await reader.read((await stat(file)).size);
    const initialBytes = reader.bytesRead;
    const firstItem = event({ type: "message", id: "message.1", text: "first" }, "response_item");
    await appendFile(file, firstItem, "utf8");
    const first = await reader.read((await stat(file)).size);
    assert.equal(reader.bytesRead - initialBytes, Buffer.byteLength(firstItem));
    assert.deepEqual(first.items.map((item) => item.text), ["first"]);

    const nextTurn = event({ type: "task_started", turn_id: "turn.2" })
      + event({ type: "message", id: "message.2", text: "second" }, "response_item");
    await appendFile(file, nextTurn, "utf8");
    const second = await reader.read((await stat(file)).size);
    assert.equal(second.turnId, "turn.2");
    assert.deepEqual(second.items.map((item) => item.text), ["second"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("replaces the internal compaction summary with a context marker", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-tail-compaction-"));
  const file = path.join(directory, "rollout.jsonl");
  try {
    const summary = "## Current State\n\nInternal continuation details";
    const contents = event({ type: "task_started", turn_id: "turn.compaction" })
      + event({ type: "message", id: "summary.1", text: summary, phase: "final_answer" }, "response_item")
      + event({ message: `Internal preamble\n${summary}` }, "compacted");
    await writeFile(file, contents, "utf8");

    const reader = new RolloutTailReader(file, parseItem);
    const snapshot = await reader.read((await stat(file)).size);

    assert.deepEqual(snapshot.items.map((item) => item.type), ["contextCompaction"]);
    assert.equal(snapshot.items.some((item) => item.text?.includes("Current State")), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
