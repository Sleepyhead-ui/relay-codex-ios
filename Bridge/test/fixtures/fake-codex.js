import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";

const rolloutPath = requiredEnvironment("FAKE_CODEX_ROLLOUT");
const counterPath = requiredEnvironment("FAKE_CODEX_COUNTER");
const pidPath = requiredEnvironment("FAKE_CODEX_PID");
const threadId = "thread.delivery-recovery";

writeFileSync(pidPath, String(process.pid), "utf8");

const input = createInterface({ input: process.stdin });
input.on("line", (line) => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.method === "initialize") {
    respond(message.id, { userAgent: "relay-fake-codex" });
    return;
  }
  if (message.method === "initialized") return;
  if (message.method === "thread/list") {
    respond(message.id, { data: [thread()] });
    return;
  }
  if (message.method === "thread/read" || message.method === "thread/resume") {
    respond(message.id, { thread: thread() });
    return;
  }
  if (message.method === "model/list") {
    respond(message.id, { data: [{ model: "fake", supportedReasoningEfforts: ["medium"] }] });
    return;
  }
  if (message.method === "turn/start" || message.method === "turn/steer") {
    recordDelivery(message);
    return;
  }
  if (message.method === "$/cancelRequest") return;
  respond(message.id, {});
});

function thread() {
  return { id: threadId, path: rolloutPath, status: { type: "idle" } };
}

function recordDelivery(message) {
  const params = message.params ?? {};
  const clientId = params.clientUserMessageId;
  const count = readCount() + 1;
  writeFileSync(counterPath, String(count), "utf8");
  const turnId = `turn.${clientId}`;
  const timestamp = new Date().toISOString();
  appendFileSync(rolloutPath, [
    { timestamp, type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
    { timestamp, type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: String(clientId) }] } },
    { timestamp, type: "event_msg", payload: { type: "user_message", client_id: clientId, message: String(clientId) } },
  ].map((entry) => JSON.stringify(entry)).join("\n") + "\n", "utf8");

  // The harness kills Bridge or this process while the request is in flight.
  // A delayed response keeps that fault window deterministic.
  setTimeout(() => {
    if (message.method === "turn/start") respond(message.id, { turn: { id: turnId } });
    else respond(message.id, { turnId });
  }, 60_000).unref();
}

function respond(id, result) {
  process.stdout.write(`${JSON.stringify({ id, result })}\n`);
}

function readCount() {
  try { return Number.parseInt(readFileSync(counterPath, "utf8"), 10) || 0; } catch { return 0; }
}

function requiredEnvironment(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}
