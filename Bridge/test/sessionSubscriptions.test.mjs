import assert from "node:assert/strict";
import test from "node:test";
import { SessionSubscriptionRegistry } from "../dist/sessionSubscriptions.js";

test("a stale unsubscribe cannot remove a newer subscription for the same thread", () => {
  const socket = {};
  const registry = new SessionSubscriptionRegistry();
  const stopped = [];
  registry.open(socket);
  registry.replace(socket, "thread.a", { subscriptionId: "lease.a.1", stop: () => stopped.push("a.1") });
  registry.replace(socket, "thread.a", { subscriptionId: "lease.a.2", stop: () => stopped.push("a.2") });

  assert.deepEqual(stopped, ["a.1"]);
  assert.equal(registry.unsubscribe(socket, "thread.a", "lease.a.1"), false);
  assert.deepEqual(stopped, ["a.1"]);
  assert.equal(registry.unsubscribe(socket, "thread.a", "lease.a.2"), true);
  assert.deepEqual(stopped, ["a.1", "a.2"]);
});

test("fast A to B to A switching preserves the newest A lease", () => {
  const socket = {};
  const registry = new SessionSubscriptionRegistry();
  const stopped = [];
  registry.open(socket);
  registry.replace(socket, "thread.a", { subscriptionId: "a.old", stop: () => stopped.push("a.old") });
  registry.replace(socket, "thread.b", { subscriptionId: "b", stop: () => stopped.push("b") });
  registry.replace(socket, "thread.a", { subscriptionId: "a.new", stop: () => stopped.push("a.new") });

  assert.equal(registry.unsubscribe(socket, "thread.a", "a.old"), false);
  assert.equal(registry.unsubscribe(socket, "thread.b", "b"), true);
  assert.equal(registry.unsubscribe(socket, "thread.a", "a.new"), true);
  assert.deepEqual(stopped, ["a.old", "b", "a.new"]);
});
