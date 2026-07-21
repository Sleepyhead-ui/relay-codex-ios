import { access } from "node:fs/promises";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

export type GoalStatus = "active" | "paused" | "blocked" | "usage_limited" | "budget_limited" | "complete";

export interface ThreadGoal {
  threadId: string;
  id: string;
  objective: string;
  status: GoalStatus;
  tokenBudget: number | null;
  tokensUsed: number;
  timeUsedSeconds: number;
  createdAt: number;
  updatedAt: number;
}

interface GoalRow {
  thread_id: string;
  goal_id: string;
  objective: string;
  status: GoalStatus;
  token_budget: number | null;
  tokens_used: number;
  time_used_seconds: number;
  created_at_ms: number;
  updated_at_ms: number;
}

export class GoalStore {
  constructor(private readonly codexHome: string) {}

  async read(threadId: unknown): Promise<ThreadGoal | undefined> {
    if (typeof threadId !== "string" || !threadId.trim()) return undefined;
    const databasePath = await this.findDatabase();
    if (!databasePath) return undefined;

    let database: DatabaseSync | undefined;
    try {
      database = new DatabaseSync(databasePath, { readOnly: true });
      const row = database.prepare(`
        SELECT thread_id, goal_id, objective, status, token_budget, tokens_used,
               time_used_seconds, created_at_ms, updated_at_ms
        FROM thread_goals
        WHERE thread_id = ?
      `).get(threadId) as unknown as GoalRow | undefined;
      if (!row) return undefined;
      return {
        threadId: row.thread_id,
        id: row.goal_id,
        objective: row.objective,
        status: row.status,
        tokenBudget: row.token_budget,
        tokensUsed: row.tokens_used,
        timeUsedSeconds: row.time_used_seconds,
        createdAt: row.created_at_ms / 1000,
        updatedAt: row.updated_at_ms / 1000,
      };
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "SQLITE_CANTOPEN" || code === "SQLITE_ERROR") return undefined;
      throw error;
    } finally {
      database?.close();
    }
  }

  private async findDatabase(): Promise<string | undefined> {
    for (const candidate of [
      path.join(this.codexHome, "goals_1.sqlite"),
      path.join(this.codexHome, "sqlite", "goals_1.sqlite"),
    ]) {
      try {
        await access(candidate);
        return candidate;
      } catch {}
    }
    return undefined;
  }
}
