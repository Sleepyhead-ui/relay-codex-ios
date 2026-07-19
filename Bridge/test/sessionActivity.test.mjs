import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
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
    await writeFile(sessionPath, `${JSON.stringify({
      timestamp: "2026-07-19T16:16:26.622Z",
      type: "event_msg",
      payload: { type: "task_started", turn_id: turnId, started_at: 1784477786 },
    })}\n`, "utf8");

    const sessions = new SessionActivityTracker();
    sessions.observeThreadList({ data: [{ id: threadId, path: sessionPath }] });
    const runtime = new RuntimeStateTracker();
    const active = await runtime.snapshotWithExternal(threadId, sessions);

    assert.equal(active.known, true);
    assert.equal(active.isRunning, true);
    assert.equal(active.activeTurnId, turnId);
    assert.equal(active.startedAt, 1784477786);

    await writeFile(sessionPath, `${JSON.stringify({
      timestamp: "2026-07-19T16:20:00.000Z",
      type: "event_msg",
      payload: { type: "task_complete", turn_id: turnId, completed_at: 1784478000 },
    })}\n`, { encoding: "utf8", flag: "a" });
    const completed = await runtime.snapshotWithExternal(threadId, sessions);
    assert.equal(completed.known, false);
    assert.equal(completed.isRunning, false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
