import { stat, readFile } from "node:fs/promises";
import type { JsonObject } from "./protocol.js";
import { isObject } from "./protocol.js";

interface SessionState {
  path: string;
  updatedAt: number;
  signature?: string;
  cachedSnapshot?: SessionTurnSnapshot;
}

export interface SessionActivitySnapshot {
  active: boolean;
  turnId?: string;
  startedAt?: number;
  updatedAt: number;
}

export interface SessionTurnSnapshot extends JsonObject {
  known: boolean;
  isRunning: boolean;
  updatedAt: number;
  turnId?: string;
  startedAt?: number;
  completedAt?: number;
  items?: JsonObject[];
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
    const turn = await this.turnSnapshot(threadId);
    if (!turn.known) return null;
    return {
      active: turn.isRunning,
      ...(turn.turnId ? { turnId: turn.turnId } : {}),
      ...(turn.startedAt ? { startedAt: turn.startedAt } : {}),
      updatedAt: turn.updatedAt,
    };
  }

  async turnSnapshot(threadId: unknown): Promise<SessionTurnSnapshot> {
    if (typeof threadId !== "string" || !threadId) {
      return { known: false, isRunning: false, updatedAt: Date.now() / 1000 };
    }
    const session = this.sessions.get(threadId);
    if (!session) return { known: false, isRunning: false, updatedAt: Date.now() / 1000 };

    let fileStat;
    try {
      fileStat = await stat(session.path);
    } catch {
      return { known: false, isRunning: false, updatedAt: Date.now() / 1000 };
    }

    const signature = `${fileStat.size}:${fileStat.mtimeMs}`;
    if (session.signature === signature && session.cachedSnapshot) {
      return { ...session.cachedSnapshot, updatedAt: Math.max(fileStat.mtimeMs / 1000, session.updatedAt) };
    }

    try {
      const contents = await readFile(session.path, "utf8");
      const markerIndex = contents.lastIndexOf('"type":"task_started"');
      if (markerIndex < 0) {
        return { known: false, isRunning: false, updatedAt: fileStat.mtimeMs / 1000 };
      }
      const lineStart = contents.lastIndexOf("\n", markerIndex) + 1;
      let turnId: string | undefined;
      let startedAt: number | undefined;
      let completedAt: number | undefined;
      let startTimestamp = 0;
      let completeTimestamp = 0;
      const items: JsonObject[] = [];
      const itemIndexes = new Map<string, number>();
      const toolIndexes = new Map<string, number>();
      let lastUserIndex: number | undefined;

      for (const line of contents.slice(lineStart).split(/\r?\n/)) {
        if (!line.trim()) continue;
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
          turnId = typeof payload.turn_id === "string" ? payload.turn_id : turnId;
          startedAt = typeof payload.started_at === "number" ? payload.started_at : timestamp;
          startTimestamp = timestamp;
        } else if (["task_complete", "turn_aborted", "turn_interrupted", "turn_failed", "turn_completed", "task_aborted"].includes(type)) {
          const completedTurnId = typeof payload.turn_id === "string" ? payload.turn_id : undefined;
          if (!turnId || !completedTurnId || completedTurnId === turnId) {
            completedAt = typeof payload.completed_at === "number" ? payload.completed_at : timestamp;
            completeTimestamp = timestamp;
          }
        } else if (type === "user_message" && typeof lastUserIndex === "number") {
          if (typeof payload.client_id === "string") items[lastUserIndex]!.clientId = payload.client_id;
        }

        if (event.type !== "response_item" || !isObject(event.payload)) continue;
        const item = responseItem(event.payload);
        if (item) {
          const id = String(item.id);
          const existingIndex = itemIndexes.get(id);
          if (typeof existingIndex === "number") items[existingIndex] = item;
          else {
            itemIndexes.set(id, items.length);
            items.push(item);
          }
          if (item.type === "userMessage") lastUserIndex = itemIndexes.get(id);
          const callId = typeof event.payload.call_id === "string" ? event.payload.call_id : undefined;
          if (callId && item.type === "dynamicToolCall") toolIndexes.set(callId, itemIndexes.get(id)!);
          continue;
        }

        if ((type === "custom_tool_call_output" || type === "function_call_output")
            && typeof payload.call_id === "string") {
          const toolIndex = toolIndexes.get(payload.call_id);
          if (typeof toolIndex === "number") {
            items[toolIndex]!.status = "completed";
            items[toolIndex]!.result = payload.output ?? payload.result ?? null;
          }
        }
      }

      const active = startTimestamp > completeTimestamp;
      const snapshot: SessionTurnSnapshot = {
        known: Boolean(turnId),
        isRunning: active,
        ...(turnId ? { turnId } : {}),
        ...(startedAt ? { startedAt } : {}),
        ...(completedAt ? { completedAt } : {}),
        items,
        updatedAt: Math.max(fileStat.mtimeMs / 1000, session.updatedAt),
      };
      session.signature = signature;
      session.cachedSnapshot = snapshot;
      return snapshot;
    } catch {
      return { known: false, isRunning: false, updatedAt: Date.now() / 1000 };
    }
  }

  private observeThread(value: unknown): void {
    if (!isObject(value)) return;
    const id = typeof value.id === "string" ? value.id : undefined;
    const path = typeof value.path === "string" ? value.path : undefined;
    if (!id || !path) return;
    const previous = this.sessions.get(id);
    if (previous?.path === path) {
      previous.updatedAt = Date.now() / 1000;
    } else {
      this.sessions.set(id, { path, updatedAt: Date.now() / 1000 });
    }
  }
}

function responseItem(payload: JsonObject): JsonObject | null {
  const type = typeof payload.type === "string" ? payload.type : "";
  const id = typeof payload.id === "string" ? payload.id : undefined;
  if (!id) return null;

  if (type === "message") {
    const role = typeof payload.role === "string" ? payload.role : "assistant";
    const content = Array.isArray(payload.content) ? payload.content : [];
    const text = content.flatMap((part) => {
      if (!isObject(part)) return [];
      return typeof part.text === "string" ? [part.text] : [];
    }).join("\n");
    if (role === "user") {
      return { id, type: "userMessage", content: [{ type: "text", text }] };
    }
    return {
      id,
      type: "agentMessage",
      text,
      phase: typeof payload.phase === "string" ? payload.phase : "commentary",
    };
  }

  if (type === "reasoning") {
    const summary = Array.isArray(payload.summary)
      ? payload.summary.flatMap((part) => isObject(part) && typeof part.text === "string" ? [part.text] : [])
      : [];
    return { id, type: "reasoning", summary, content: [] };
  }

  if (type === "custom_tool_call" || type === "function_call") {
    return {
      id,
      type: "dynamicToolCall",
      tool: typeof payload.name === "string" ? payload.name : "tool",
      namespace: "",
      arguments: payload.input ?? payload.arguments ?? null,
      status: typeof payload.status === "string" ? payload.status : "inProgress",
      ...(typeof payload.call_id === "string" ? { callId: payload.call_id } : {}),
    };
  }

  return null;
}
