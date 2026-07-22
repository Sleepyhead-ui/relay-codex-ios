import assert from "node:assert/strict";
import test from "node:test";
import { SessionPatchCursor } from "../dist/sessionPatch.js";

function snapshot(overrides = {}) {
  return {
    known: true,
    isRunning: true,
    updatedAt: 100,
    turnId: "turn.1",
    startedAt: 90,
    items: [{ id: "item.1", type: "agentMessage", text: "first" }],
    ...overrides,
  };
}

test("initializes with a full snapshot and ignores an identical update", () => {
  const cursor = new SessionPatchCursor();
  assert.equal(cursor.reset(snapshot()).revision, 0);
  assert.equal(cursor.update(snapshot()), null);
});

test("emits only changed and added items", () => {
  const cursor = new SessionPatchCursor();
  const unchanged = Array.from({ length: 20 }, (_, index) => ({
    id: `unchanged.${index}`,
    type: "agentMessage",
    text: `A sufficiently long unchanged message ${index}`,
  }));
  cursor.reset(snapshot({ items: [snapshot().items[0], ...unchanged] }));
  const update = cursor.update(snapshot({
    updatedAt: 101,
    items: [
      { id: "item.1", type: "agentMessage", text: "first expanded" },
      ...unchanged,
      { id: "item.2", type: "reasoning", summary: ["next"] },
    ],
  }));
  assert.equal(update.type, "sessionPatch");
  assert.equal(update.patch.baseRevision, 0);
  assert.equal(update.patch.revision, 1);
  assert.deepEqual(update.patch.upsertItems.map((item) => item.id), ["item.1", "item.2"]);
  assert.deepEqual(update.patch.removedItemIds, []);
});

test("reports removed items", () => {
  const cursor = new SessionPatchCursor();
  cursor.reset(snapshot({ items: [
    { id: "item.1", type: "agentMessage", text: "first" },
    { id: "item.2", type: "agentMessage", text: "second" },
  ] }));
  const update = cursor.update(snapshot({ updatedAt: 102 }));
  assert.equal(update.type, "sessionPatch");
  assert.deepEqual(update.patch.removedItemIds, ["item.2"]);
});

test("uses a full snapshot when a new turn starts", () => {
  const cursor = new SessionPatchCursor();
  cursor.reset(snapshot());
  const update = cursor.update(snapshot({ turnId: "turn.2", updatedAt: 110, items: [] }));
  assert.equal(update.type, "sessionSnapshot");
  assert.equal(update.snapshot.turnId, "turn.2");
  assert.equal(update.snapshot.revision, 1);
});

test("uses a full snapshot when a patch is not smaller", () => {
  const cursor = new SessionPatchCursor();
  cursor.reset(snapshot({ items: [] }));
  const update = cursor.update(snapshot({ updatedAt: 101, completedAt: 101, isRunning: false, items: [] }));
  assert.equal(update.type, "sessionSnapshot");
  assert.equal(update.snapshot.revision, 1);
});

test("keeps a one-item update small for a large turn", () => {
  const cursor = new SessionPatchCursor();
  const items = Array.from({ length: 1_000 }, (_, index) => ({
    id: `item.${index}`,
    type: "agentMessage",
    text: `progress ${index} ${"x".repeat(80)}`,
  }));
  cursor.reset(snapshot({ items }));
  const changed = items.map((item, index) => index === 999 ? { ...item, text: `${item.text} updated` } : item);
  const full = snapshot({ updatedAt: 200, items: changed });
  const update = cursor.update(full);
  assert.equal(update.type, "sessionPatch");
  assert.equal(update.patch.upsertItems.length, 1);
  assert.ok(JSON.stringify(update.patch).length < JSON.stringify(full).length / 100);
});

test("keeps revisions contiguous across one hundred high-frequency updates", () => {
  const cursor = new SessionPatchCursor();
  let items = Array.from({ length: 1_000 }, (_, index) => ({
    id: `item.${index}`,
    type: "agentMessage",
    text: `message ${index} ${"x".repeat(80)}`,
  }));
  cursor.reset(snapshot({ items }));
  let revision = 0;
  for (let index = 0; index < 100; index += 1) {
    items = items.map((item, itemIndex) => itemIndex === index ? { ...item, text: `${item.text}.${index}` } : item);
    const update = cursor.update(snapshot({ updatedAt: 101 + index, items }));
    assert.equal(update.type, "sessionPatch");
    assert.equal(update.patch.baseRevision, revision);
    revision += 1;
    assert.equal(update.patch.revision, revision);
    assert.deepEqual(update.patch.upsertItems.map((item) => item.id), [`item.${index}`]);
  }
});

test("preserves a ten megabyte command output in the selected wire update", () => {
  const cursor = new SessionPatchCursor();
  const command = { id: "command.1", type: "commandExecution", aggregatedOutput: "" };
  cursor.reset(snapshot({ items: [command] }));
  const output = "x".repeat(10_000_000);
  const update = cursor.update(snapshot({
    updatedAt: 200,
    items: [{ ...command, aggregatedOutput: output }],
  }));
  assert.ok(update);
  const item = update.type === "sessionPatch" ? update.patch.upsertItems[0] : update.snapshot.items[0];
  assert.equal(item.aggregatedOutput.length, output.length);
  assert.equal(item.aggregatedOutput, output);
});
