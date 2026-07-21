import test from "node:test";
import assert from "node:assert/strict";
import { RequestLifecycle } from "../dist/requestLifecycle.js";

test("expires a request and removes it from the lifecycle", async () => {
  const expired = [];
  const lifecycle = new RequestLifecycle((id, request) => expired.push([id, request]));
  const socket = {};
  lifecycle.add("bridge.1", { socket, clientId: "client.1", method: "thread/list", params: {} }, 15);
  await new Promise((resolve) => setTimeout(resolve, 35));
  assert.equal(lifecycle.size, 0);
  assert.equal(expired.length, 1);
  assert.equal(expired[0][0], "bridge.1");
});

test("removes all requests belonging to a disconnected socket", () => {
  const lifecycle = new RequestLifecycle(() => {});
  const left = {};
  const right = {};
  lifecycle.add("bridge.1", { socket: left, clientId: "client.1", method: "turn/start", params: {} }, 10_000);
  lifecycle.add("bridge.2", { socket: right, clientId: "client.2", method: "thread/list", params: {} }, 10_000);
  const removed = lifecycle.removeSocket(left);
  assert.deepEqual(removed.map(([id]) => id), ["bridge.1"]);
  assert.equal(lifecycle.size, 1);
  assert.equal(lifecycle.take("bridge.2")?.clientId, "client.2");
});

test("cancels a request using the client-visible id", () => {
  const lifecycle = new RequestLifecycle(() => {});
  const socket = {};
  lifecycle.add("bridge.7", { socket, clientId: "mobile.7", method: "turn/steer", params: {} }, 10_000);
  assert.equal(lifecycle.cancelClient(socket, "mobile.7")?.[0], "bridge.7");
  assert.equal(lifecycle.size, 0);
});
