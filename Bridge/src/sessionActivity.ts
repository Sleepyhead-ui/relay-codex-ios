import { stat, readFile } from "node:fs/promises";
import type { JsonObject } from "./protocol.js";
import { isObject } from "./protocol.js";

interface SessionState {
  path: string;
  updatedAt: number;
}

export interface SessionActivitySnapshot {
  active: boolean;
  turnId?: string;
  startedAt?: number;
  updatedAt: number;
}

/**
 * The desktop Codex app and Relay's app-server are separate processes. When
 * Relay starts in the middle of a desktop turn, app-server can report that
 * turn as interrupted even while the desktop session is still running. The
 * rollout file is the shared source of truth in that situation.
 */
export class SessionActivityTracker {
  private readonly sessions = new Map<string, SessionState>();

  observeThreadList(result: unknown): void {
    const object = isObject(result) ? result : {};
    const data = Array.isArray(object.data) ? object.data : [];
    for (const thread of data) this.observeThread(thread);
  }

  observeThreadResume(result: unknown): void {
    const object = isObject(result) ? result : {};
    this.observeThread(object.thread);
  }

  async snapshot(threadId: unknown): Promise<SessionActivitySnapshot | null> {
    if (typeof threadId !== "string" || !threadId) return null;
    const session = this.sessions.get(threadId);
    if (!session) return null;

    let fileStat;
    try {
      fileStat = await stat(session.path);
    } catch {
      return null;
    }

    try {
      const contents = await readFile(session.path, "utf8");
      let latestStarted: { timestamp: number; turnId?: string; startedAt?: number } | undefined;
      let latestCompleted = 0;
      for (const line of contents.split(/\r?\n/)) {
        if (!line.includes('"type":"event_msg"')) continue;
        let event: JsonObject;
        try {
          event = JSON.parse(line) as JsonObject;
        } catch {
          continue;
        }
        const payload = isObject(event.payload) ? event.payload : {};
        const type = typeof payload.type === "string" ? payload.type : "";
        const timestamp = typeof event.timestamp === "string"
          ? Date.parse(event.timestamp) / 1000
          : 0;
        if (type === "task_started") {
          latestStarted = {
            timestamp,
            ...(typeof payload.turn_id === "string" ? { turnId: payload.turn_id } : {}),
            startedAt: typeof payload.started_at === "number" ? payload.started_at : timestamp,
          };
        } else if (type === "task_complete") {
          latestCompleted = timestamp;
        }
      }

      const active = Boolean(latestStarted && latestStarted.timestamp > latestCompleted);
      return {
        active,
        ...(active && latestStarted?.turnId ? { turnId: latestStarted.turnId } : {}),
        ...(active && latestStarted?.startedAt ? { startedAt: latestStarted.startedAt } : {}),
        updatedAt: Math.max(fileStat.mtimeMs / 1000, session.updatedAt),
      };
    } catch {
      return null;
    }
  }

  private observeThread(value: unknown): void {
    if (!isObject(value)) return;
    const id = typeof value.id === "string" ? value.id : undefined;
    const path = typeof value.path === "string" ? value.path : undefined;
    if (!id || !path) return;
    this.sessions.set(id, { path, updatedAt: Date.now() / 1000 });
  }
}
