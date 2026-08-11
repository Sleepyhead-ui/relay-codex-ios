import { createInterface } from "node:readline";
import { appendFileSync } from "node:fs";

const threadId = "thread.active-writer";
const rolloutPath = process.env.FAKE_CODEX_ROLLOUT;
const methodLog = process.env.FAKE_CODEX_METHOD_LOG;
const allowResume = process.env.FAKE_CODEX_ALLOW_RESUME === "1";
if (!rolloutPath) throw new Error("Missing FAKE_CODEX_ROLLOUT.");

const input = createInterface({ input: process.stdin });
input.on("line", (line) => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (methodLog && typeof message.method === "string") appendFileSync(methodLog, `${message.method}\n`, "utf8");
  if (message.method === "initialize") return respond(message.id, { userAgent: "relay-active-writer-test" });
  if (message.method === "initialized") return;
  if (message.method === "thread/list") return respond(message.id, { data: [thread()] });
  if (message.method === "thread/resume") {
    if (allowResume) return respond(message.id, { thread: thread() });
    return fail(message.id, `thread-store conflict: thread ${threadId} already has an active writer`);
  }
  if (message.method === "thread/read") return respond(message.id, { thread: thread() });
  if (message.method === "thread/turns/list") {
    return respond(message.id, {
      data: [{
        id: "turn.active-writer",
        status: "inProgress",
        startedAt: 1_786_000_000,
        items: [{ id: "item.user", type: "userMessage", content: [{ type: "text", text: "keep working" }] }],
      }],
      nextCursor: "older.cursor",
    });
  }
  if (message.method === "model/list") return respond(message.id, { data: [] });
  respond(message.id, {});
});

function thread() {
  return {
    id: threadId,
    path: rolloutPath,
    cwd: process.cwd(),
    status: { type: "notLoaded" },
  };
}

function respond(id, result) {
  process.stdout.write(`${JSON.stringify({ id, result })}\n`);
}

function fail(id, message) {
  process.stdout.write(`${JSON.stringify({ id, error: { code: -32000, message } })}\n`);
}
