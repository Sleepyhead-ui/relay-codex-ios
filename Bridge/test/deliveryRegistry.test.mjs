import test from "node:test";
import assert from "node:assert/strict";
import { DeliveryRegistry } from "../dist/deliveryRegistry.js";
import { RequestLifecycle } from "../dist/requestLifecycle.js";

test("coalesces duplicate durable deliveries and replays the result", () => {
  const registry = new DeliveryRegistry();
  const firstSocket = {};
  const secondSocket = {};
  const params = { threadId: "thread.1", clientUserMessageId: "message.1", input: [] };

  const first = registry.register("default", "turn/start", params, { socket: firstSocket, clientId: "rpc.1" });
  assert.equal(first?.kind, "new");
  const duplicate = registry.register("default", "turn/start", params, { socket: secondSocket, clientId: "rpc.2" });
  assert.equal(duplicate?.kind, "pending");

  const waiters = registry.complete(first.key, { result: { turn: { id: "turn.1" } } });
  assert.deepEqual(waiters.map((waiter) => waiter.clientId), ["rpc.1", "rpc.2"]);
  const replay = registry.register("default", "turn/start", params, { socket: secondSocket, clientId: "rpc.3" });
  assert.equal(replay?.kind, "completed");
  assert.equal(replay.response.result.turn.id, "turn.1");
  assert.deepEqual(registry.complete(first.key, { result: { turn: { id: "turn.1" } } }), []);
});

test("keeps a durable delivery alive after its socket disconnects", () => {
  const registry = new DeliveryRegistry();
  const socket = {};
  const params = { threadId: "thread.1", clientUserMessageId: "message.2", input: [] };
  const delivery = registry.register("default", "turn/steer", params, { socket, clientId: "rpc.1" });
  assert.equal(delivery?.kind, "new");
  registry.removeWaiter(socket);
  assert.equal(registry.status("default", "message.2").status, "pending");
  assert.deepEqual(registry.complete(delivery.key, { result: { turnId: "turn.1" } }), []);
  assert.equal(registry.status("default", "message.2").status, "completed");
});

test("rejects reusing a message id for a different thread or method", () => {
  const registry = new DeliveryRegistry();
  const waiter = { socket: {}, clientId: "rpc.1" };
  registry.register("default", "turn/start", { threadId: "thread.1", clientUserMessageId: "message.3" }, waiter);
  assert.equal(registry.register("default", "turn/start", { threadId: "thread.2", clientUserMessageId: "message.3" }, waiter)?.kind, "conflict");
  assert.equal(registry.register("default", "turn/steer", { threadId: "thread.1", clientUserMessageId: "message.3" }, waiter)?.kind, "conflict");
});

test("reconnects to one in-flight Codex request without forwarding a duplicate", () => {
  const registry = new DeliveryRegistry();
  const lifecycle = new RequestLifecycle(() => {});
  const firstSocket = {};
  const secondSocket = {};
  const params = { threadId: "thread.1", clientUserMessageId: "message.4", input: [{ type: "text", text: "run" }] };
  const first = registry.register("default", "turn/start", params, { socket: firstSocket, clientId: "rpc.1" });
  assert.equal(first?.kind, "new");
  lifecycle.add("bridge.1", {
    socket: firstSocket,
    clientId: "rpc.1",
    method: "turn/start",
    params,
    deliveryKey: first.key,
  }, 10_000);
  registry.bindBridgeRequest(first.key, "bridge.1");

  registry.removeWaiter(firstSocket);
  assert.deepEqual(lifecycle.removeSocket(firstSocket, (request) => Boolean(request.deliveryKey)), []);
  const duplicate = registry.register("default", "turn/start", params, { socket: secondSocket, clientId: "rpc.2" });
  assert.equal(duplicate?.kind, "pending");
  assert.equal(lifecycle.size, 1);

  const pending = lifecycle.take("bridge.1");
  assert.equal(pending?.deliveryKey, first.key);
  const waiters = registry.complete(first.key, { result: { turn: { id: "turn.4" } } });
  assert.deepEqual(waiters, [{ socket: secondSocket, clientId: "rpc.2" }]);
});
