import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { GoalStore } from "../dist/goalStore.js";

test("reads structured goal state from the active Codex home", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-goals-"));
  const database = new DatabaseSync(path.join(root, "goals_1.sqlite"));
  database.exec(`
    CREATE TABLE thread_goals (
      thread_id TEXT PRIMARY KEY NOT NULL,
      goal_id TEXT NOT NULL,
      objective TEXT NOT NULL,
      status TEXT NOT NULL,
      token_budget INTEGER,
      tokens_used INTEGER NOT NULL,
      time_used_seconds INTEGER NOT NULL,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    );
    INSERT INTO thread_goals VALUES (
      'thread-1', 'goal-1', '完成稳定性与发布', 'active', NULL,
      1200, 4156, 1784636198000, 1784641901000
    );
  `);
  database.close();

  assert.deepEqual(await new GoalStore(root).read("thread-1"), {
    threadId: "thread-1",
    id: "goal-1",
    objective: "完成稳定性与发布",
    status: "active",
    tokenBudget: null,
    tokensUsed: 1200,
    timeUsedSeconds: 4156,
    createdAt: 1784636198,
    updatedAt: 1784641901,
  });
});

test("supports the legacy sqlite subdirectory and missing goals", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-goals-fallback-"));
  const directory = path.join(root, "sqlite");
  await mkdir(directory, { recursive: true });
  const database = new DatabaseSync(path.join(directory, "goals_1.sqlite"));
  database.exec("CREATE TABLE thread_goals (thread_id TEXT PRIMARY KEY, goal_id TEXT, objective TEXT, status TEXT, token_budget INTEGER, tokens_used INTEGER, time_used_seconds INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER)");
  database.close();

  assert.equal(await new GoalStore(root).read("missing"), undefined);
  assert.equal(await new GoalStore(path.join(root, "absent")).read("missing"), undefined);
});
