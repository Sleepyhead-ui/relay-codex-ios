import assert from "node:assert/strict";
import test from "node:test";
import {
  isPaginatedThreadsUnsupported,
  legacyThreadTurnsCursor,
  paginateLegacyThreadTurns,
} from "../dist/threadTurnsCompatibility.js";

test("recognizes the current unsupported paginated thread error", () => {
  assert.equal(isPaginatedThreadsUnsupported(new Error("paginated_threads is not supported yet")), true);
  assert.equal(isPaginatedThreadsUnsupported(new Error("thread not found")), false);
});

test("pages turns from the thread/read fallback in the same order as thread/turns/list", () => {
  const turns = Array.from({ length: 5 }, (_, index) => ({ id: `turn.${index + 1}` }));
  const first = paginateLegacyThreadTurns(
    { thread: { turns } },
    { limit: 2, sortDirection: "desc" },
  );
  assert.deepEqual(first.data.map((turn) => turn.id), ["turn.5", "turn.4"]);
  assert.equal(first.nextCursor, legacyThreadTurnsCursor(2));

  const second = paginateLegacyThreadTurns(
    { thread: { turns } },
    { limit: 2, sortDirection: "desc", cursor: first.nextCursor },
  );
  assert.deepEqual(second.data.map((turn) => turn.id), ["turn.3", "turn.2"]);
  assert.equal(second.nextCursor, legacyThreadTurnsCursor(4));

  const last = paginateLegacyThreadTurns(
    { thread: { turns } },
    { limit: 2, sortDirection: "desc", cursor: second.nextCursor },
  );
  assert.deepEqual(last.data.map((turn) => turn.id), ["turn.1"]);
  assert.equal(last.nextCursor, undefined);
});
