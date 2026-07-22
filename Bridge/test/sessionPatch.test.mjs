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
