import test from "node:test";
import assert from "node:assert/strict";
import { isAuthorized, parseClientMessage } from "../dist/protocol.js";

test("accepts an exact bearer token", () => {
  assert.equal(isAuthorized("Bearer secret-token", "secret-token"), true);
  assert.equal(isAuthorized("Bearer wrong-token", "secret-token"), false);
  assert.equal(isAuthorized(undefined, "secret-token"), false);
});

test("parses rpc requests", () => {
  const message = parseClientMessage(JSON.stringify({
    type: "rpc",
    id: "mobile-1",
    method: "thread/list",
    params: { limit: 20 },
  }));
  assert.deepEqual(message, {
    type: "rpc",
    id: "mobile-1",
    method: "thread/list",
    params: { limit: 20 },
  });
});

test("rejects malformed messages", () => {
  assert.throws(() => parseClientMessage('{"type":"rpc"}'), /Invalid rpc/);
  assert.throws(() => parseClientMessage('{"type":"unknown"}'), /Unsupported/);
});

test("parses rpc cancellation messages", () => {
  assert.deepEqual(parseClientMessage('{"type":"rpcCancel","id":"mobile-1"}'), {
    type: "rpcCancel",
    id: "mobile-1",
  });
});
