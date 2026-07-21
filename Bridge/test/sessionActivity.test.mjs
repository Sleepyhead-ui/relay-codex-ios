import assert from "node:assert/strict";
import test from "node:test";
import { appendFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { RuntimeStateTracker } from "../dist/runtimeState.js";
import { SessionActivityTracker } from "../dist/sessionActivity.js";

test("infers an active desktop turn from the rollout file after bridge restart", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-session-activity-"));
  const sessionPath = path.join(directory, "rollout.jsonl");
  const threadId = "thread.desktop";
  const turnId = "turn.desktop";
  try {
    await writeFile(sessionPath, [
      {
        timestamp: "2026-07-19T16:16:26.622Z",
        type: "event_msg",
        payload: { type: "task_started", turn_id: turnId, started_at: 1784477786 },
      },
      {
        timestamp: "2026-07-19T16:16:27.000Z",
        type: "response_item",
        payload: { type: "message", role: "user", content: [{ type: "input_text", text: "Inspect this task" }] },
      },
      {
        timestamp: "2026-07-19T16:16:27.001Z",
        type: "event_msg",
        payload: { type: "user_message", client_id: "client.user.1", message: "Inspect this task" },
      },
      {
        timestamp: "2026-07-19T16:16:30.000Z",
        type: "response_item",
        payload: { type: "reasoning", id: "reasoning.1", summary: [{ type: "summary_text", text: "Inspecting state" }] },
      },
      {
        timestamp: "2026-07-19T16:16:31.000Z",
        type: "response_item",
        payload: { type: "message", id: "message.1", role: "assistant", phase: "commentary", content: [{ type: "output_text", text: "Still working" }] },
      },
      {
        timestamp: "2026-07-19T16:16:32.000Z",
        type: "response_item",
        payload: {
          type: "custom_tool_call",
          id: "tool.1",
          call_id: "call.1",
          name: "exec",
          input: 'const result = await tools.shell_command({ command: "Get-ChildItem -Force" });',
          status: "completed",
        },
      },
      {
        timestamp: "2026-07-19T16:16:33.000Z",
        type: "response_item",
        payload: { type: "custom_tool_call_output", call_id: "call.1", output: "Exit code: 0" },
      },
    ].map((entry) => JSON.stringify(entry)).join("\n") + "\n", "utf8");

    const sessions = new SessionActivityTracker();
    sessions.observeThreadList({ data: [{ id: threadId, path: sessionPath }] });
    const runtime = new RuntimeStateTracker();
    const active = await runtime.snapshotWithExternal(threadId, sessions);

    assert.equal(active.known, true);
    assert.equal(active.isRunning, true);
    assert.equal(active.activeTurnId, turnId);
    assert.equal(active.startedAt, 1784477786);
    const turn = await sessions.turnSnapshot(threadId);
    assert.equal(turn.items.length, 4);
    assert.deepEqual(turn.items.map((item) => item.type), ["userMessage", "reasoning", "agentMessage", "dynamicToolCall"]);
    assert.equal(turn.items[0].clientId, "client.user.1");
    assert.equal(turn.items[0].content[0].text, "Inspect this task");
    assert.equal(turn.items[3].tool, "exec");
    assert.match(turn.items[3].arguments, /Get-ChildItem -Force/);
    assert.equal(turn.items[3].result, "Exit code: 0");
    assert.equal(turn.items[3].status, "completed");

    await writeFile(sessionPath, `${JSON.stringify({
      timestamp: "2026-07-19T16:20:00.000Z",
      type: "event_msg",
      payload: { type: "task_complete", turn_id: turnId, completed_at: 1784478000 },
    })}\n`, { encoding: "utf8", flag: "a" });
    const completed = await runtime.snapshotWithExternal(threadId, sessions);
    assert.equal(completed.known, true);
    assert.equal(completed.isRunning, false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("treats an interrupted rollout turn as terminal", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-session-interrupted-"));
  const sessionPath = path.join(directory, "rollout.jsonl");
  const threadId = "thread.interrupted";
  const turnId = "turn.interrupted";
  try {
    await writeFile(sessionPath, [
      {
        timestamp: "2026-07-20T01:00:00.000Z",
        type: "event_msg",
        payload: { type: "task_started", turn_id: turnId },
      },
      {
        timestamp: "2026-07-20T01:01:00.000Z",
        type: "event_msg",
        payload: { type: "turn_aborted", turn_id: turnId, reason: "interrupted" },
      },
    ].map((entry) => JSON.stringify(entry)).join("\n") + "\n", "utf8");

    const sessions = new SessionActivityTracker();
    sessions.observeThreadList({ data: [{ id: threadId, path: sessionPath }] });
    const snapshot = await sessions.turnSnapshot(threadId);
    assert.equal(snapshot.known, true);
    assert.equal(snapshot.isRunning, false);
    assert.equal(snapshot.turnId, turnId);
    assert.equal(snapshot.completedAt, Date.parse("2026-07-20T01:01:00.000Z") / 1000);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("pushes an updated snapshot when the rollout file changes", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-session-watch-"));
  const sessionPath = path.join(directory, "rollout.jsonl");
  const threadId = "thread.watch";
  try {
    await writeFile(sessionPath, `${JSON.stringify({
      timestamp: "2026-07-20T02:00:00.000Z",
      type: "event_msg",
      payload: { type: "task_started", turn_id: "turn.watch" },
    })}\n`, "utf8");
    const sessions = new SessionActivityTracker();
    sessions.observeThreadList({ data: [{ id: threadId, path: sessionPath }] });
    const update = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("session update timed out")), 2_000);
      const stop = sessions.subscribe(threadId, (snapshot) => {
        if (!snapshot.items?.length) return;
        clearTimeout(timeout);
        stop();
        resolve(snapshot);
      });
    });
    await appendFile(sessionPath, `${JSON.stringify({
      timestamp: "2026-07-20T02:00:01.000Z",
      type: "response_item",
      payload: { type: "message", id: "message.watch", role: "assistant", phase: "commentary", content: [{ type: "output_text", text: "Immediate progress" }] },
    })}\n`, "utf8");
    const snapshot = await update;
    assert.equal(snapshot.items[0].text, "Immediate progress");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
