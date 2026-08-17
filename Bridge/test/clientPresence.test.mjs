import assert from "node:assert/strict";
import test from "node:test";
import { ClientPresenceRegistry } from "../dist/clientPresence.js";

test("tracks foreground clients and removes disconnected clients", () => {
  const first = {};
  const second = {};
  const presence = new ClientPresenceRegistry();
  presence.open(first);
  presence.open(second);
  assert.equal(presence.hasActiveClient, false);

  assert.equal(presence.update(first, true, 1), true);
  assert.equal(presence.hasActiveClient, true);
  assert.equal(presence.update(second, true, 1), true);
  presence.close(first);
  assert.equal(presence.hasActiveClient, true);
  presence.close(second);
  assert.equal(presence.hasActiveClient, false);
});

test("ignores an out-of-order presence update", () => {
  const client = {};
  const presence = new ClientPresenceRegistry();
  presence.open(client);

  assert.equal(presence.update(client, false, 2), true);
  assert.equal(presence.update(client, true, 1), false);
  assert.equal(presence.hasActiveClient, false);
});
