import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { DeliveryRegistry } from "../dist/deliveryRegistry.js";
import { RequestLifecycle } from "../dist/requestLifecycle.js";

test("coalesces duplicate durable deliveries and replays the result", async () => {
  const registry = await DeliveryRegistry.create(null);
  const firstSocket = {};
  const secondSocket = {};
  const params = { threadId: "thread.1", clientUserMessageId: "message.1", input: [] };

  const first = await registry.register("default", "turn/start", params, { socket: firstSocket, clientId: "rpc.1" });
  assert.equal(first?.kind, "new");
  const duplicate = await registry.register("default", "turn/start", params, { socket: secondSocket, clientId: "rpc.2" });
  assert.equal(duplicate?.kind, "pending");

  const waiters = await registry.complete(first.key, { result: { turn: { id: "turn.1" } } });
  assert.deepEqual(waiters.map((waiter) => waiter.clientId), ["rpc.1", "rpc.2"]);
  const replay = await registry.register("default", "turn/start", params, { socket: secondSocket, clientId: "rpc.3" });
  assert.equal(replay?.kind, "completed");
  assert.equal(replay.response.result.turn.id, "turn.1");
  assert.deepEqual(await registry.complete(first.key, { result: { turn: { id: "turn.1" } } }), []);
});

test("keeps a durable delivery alive after its socket disconnects", async () => {
  const registry = await DeliveryRegistry.create(null);
  const socket = {};
  const params = { threadId: "thread.1", clientUserMessageId: "message.2", input: [] };
  const delivery = await registry.register("default", "turn/steer", params, { socket, clientId: "rpc.1" });
  assert.equal(delivery?.kind, "new");
  registry.removeWaiter(socket);
  assert.equal(registry.status("default", "message.2").status, "pending");
  assert.deepEqual(await registry.complete(delivery.key, { result: { turnId: "turn.1" } }), []);
  assert.equal(registry.status("default", "message.2").status, "completed");
});

test("abandons an uncertain request so a restarted bridge can reconcile session history", async () => {
  const registry = await DeliveryRegistry.create(null);
  const socket = {};
  const params = { threadId: "thread.1", clientUserMessageId: "message.restart", input: [] };
  const delivery = await registry.register("default", "turn/start", params, { socket, clientId: "rpc.1" });
  assert.equal(delivery?.kind, "new");

  assert.deepEqual(await registry.abandon(delivery.key), [{ socket, clientId: "rpc.1" }]);
  assert.equal(registry.status("default", "message.restart").status, "unknown");
  assert.equal((await registry.register("default", "turn/start", params, { socket, clientId: "rpc.2" }))?.kind, "new");
});

test("rejects reusing a message id for a different thread or method", async () => {
  const registry = await DeliveryRegistry.create(null);
  const waiter = { socket: {}, clientId: "rpc.1" };
  await registry.register("default", "turn/start", { threadId: "thread.1", clientUserMessageId: "message.3" }, waiter);
  assert.equal((await registry.register("default", "turn/start", { threadId: "thread.2", clientUserMessageId: "message.3" }, waiter))?.kind, "conflict");
  assert.equal((await registry.register("default", "turn/steer", { threadId: "thread.1", clientUserMessageId: "message.3" }, waiter))?.kind, "conflict");
});

test("reconnects to one in-flight Codex request without forwarding a duplicate", async () => {
  const registry = await DeliveryRegistry.create(null);
  const lifecycle = new RequestLifecycle(() => {});
  const firstSocket = {};
  const secondSocket = {};
  const params = { threadId: "thread.1", clientUserMessageId: "message.4", input: [{ type: "text", text: "run" }] };
  const first = await registry.register("default", "turn/start", params, { socket: firstSocket, clientId: "rpc.1" });
  assert.equal(first?.kind, "new");
  lifecycle.add("bridge.1", {
    socket: firstSocket,
    clientId: "rpc.1",
    method: "turn/start",
    params,
    deliveryKey: first.key,
  }, 10_000);
  await registry.bindBridgeRequest(first.key, "bridge.1");

  registry.removeWaiter(firstSocket);
  assert.deepEqual(lifecycle.removeSocket(firstSocket, (request) => Boolean(request.deliveryKey)), []);
  const duplicate = await registry.register("default", "turn/start", params, { socket: secondSocket, clientId: "rpc.2" });
  assert.equal(duplicate?.kind, "pending");
  assert.equal(lifecycle.size, 1);

  const pending = lifecycle.take("bridge.1");
  assert.equal(pending?.deliveryKey, first.key);
  const waiters = await registry.complete(first.key, { result: { turn: { id: "turn.4" } } });
  assert.deepEqual(waiters, [{ socket: secondSocket, clientId: "rpc.2" }]);
});

test("restores pending and completed deliveries after a bridge process restart", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-delivery-registry-"));
  const storage = path.join(directory, "deliveries.json");
  try {
    const first = await DeliveryRegistry.create(storage);
    const pendingParams = { threadId: "thread.pending", clientUserMessageId: "message.pending", input: [{ type: "text", text: "run once" }] };
    const completedParams = { threadId: "thread.completed", clientUserMessageId: "message.completed", input: [{ type: "text", text: "done" }] };
    const pending = await first.register("profile.a", "turn/start", pendingParams, { socket: {}, clientId: "rpc.pending" });
    const completed = await first.register("profile.a", "turn/start", completedParams, { socket: {}, clientId: "rpc.completed" });
    await first.bindBridgeRequest(pending.key, "bridge.pending");
    await first.complete(completed.key, { result: { turn: { id: "turn.completed" } } });

    const restored = await DeliveryRegistry.create(storage);
    assert.deepEqual(restored.recoverable("profile.a").map((item) => item.clientUserMessageId), ["message.pending"]);
    assert.equal(restored.recoverable("profile.a")[0].params.input[0].text, "run once");
    assert.equal(restored.status("profile.a", "message.completed").status, "completed");
    const replay = await restored.register("profile.a", "turn/start", completedParams, { socket: {}, clientId: "rpc.replay" });
    assert.equal(replay?.kind, "completed");
    assert.equal(replay.response.result.turn.id, "turn.completed");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("keeps identical message ids isolated by Codex profile", async () => {
  const registry = await DeliveryRegistry.create(null);
  const params = { threadId: "thread.1", clientUserMessageId: "message.shared", input: [] };
  assert.equal((await registry.register("profile.a", "turn/start", params, { socket: {}, clientId: "rpc.a" }))?.kind, "new");
  assert.equal((await registry.register("profile.b", "turn/start", params, { socket: {}, clientId: "rpc.b" }))?.kind, "new");
  assert.equal(registry.recoverable("profile.a").length, 1);
  assert.equal(registry.recoverable("profile.b").length, 1);
  assert.equal(registry.pendingCountFor("profile.a"), 1);
  assert.equal(registry.pendingCountFor("profile.b"), 1);
});
