import assert from "node:assert/strict";
import test from "node:test";
import { SessionSourceOwnership } from "../dist/sessionSourceOwnership.js";

test("Relay-owned turns use app-server events until their matching terminal event", () => {
  const ownership = new SessionSourceOwnership();
  ownership.begin("thread.1");
  assert.equal(ownership.isRelayOwned("thread.1", "turn.pending"), true);
  ownership.bind("thread.1", "turn.1");
  assert.equal(ownership.isRelayOwned("thread.1", "turn.1"), true);
  assert.equal(ownership.isRelayOwned("thread.1", "turn.old"), false);
  assert.equal(ownership.finish("thread.1", "turn.old"), false);
  assert.equal(ownership.isRelayOwned("thread.1", "turn.1"), true);
  assert.equal(ownership.finish("thread.1", "turn.1"), true);
  assert.equal(ownership.isRelayOwned("thread.1", "turn.1"), false);
});
