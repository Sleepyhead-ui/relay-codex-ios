import { watch, type FSWatcher } from "node:fs";
import { stat } from "node:fs/promises";
import type { JsonObject } from "./protocol.js";
import { isObject } from "./protocol.js";
import { RolloutTailReader } from "./rolloutTailReader.js";

interface SessionState {
  path: string;
  updatedAt: number;
  appServerActive?: boolean;
  signature?: string;
  cachedSnapshot?: SessionTurnSnapshot;
  reader?: RolloutTailReader;
}

interface SessionWatch {
  path: string;
  watcher: FSWatcher;
  listeners: Set<(snapshot: SessionTurnSnapshot) => void>;
  debounce: NodeJS.Timeout | undefined;
  staleTimeout: NodeJS.Timeout | undefined;
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
  stale?: boolean;
  items?: JsonObject[];
}

const staleExternalSessionSeconds = 5 * 60;

/**
 * The desktop Codex app and Relay's app-server are separate processes. When
 * Relay starts in the middle of a desktop turn, app-server can report that
 * turn as interrupted even while the desktop session is still running. The
 * rollout file is the shared source of truth in that situation.
 */
export class SessionActivityTracker {
  private readonly sessions = new Map<string, SessionState>();
  private readonly watches = new Map<string, SessionWatch>();

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
      return this.normalizeSnapshot(session, session.cachedSnapshot, fileStat.mtimeMs / 1000);
    }

    try {
      session.reader ??= new RolloutTailReader(session.path, responseItem);
      const parsed = await session.reader.read(fileStat.size);
      const snapshot: SessionTurnSnapshot = {
        ...parsed,
        updatedAt: Math.max(fileStat.mtimeMs / 1000, session.updatedAt),
      };
      session.signature = signature;
      session.cachedSnapshot = snapshot;
      return this.normalizeSnapshot(session, snapshot, fileStat.mtimeMs / 1000);
    } catch {
      return { known: false, isRunning: false, updatedAt: Date.now() / 1000 };
    }
  }

  subscribe(threadId: unknown, listener: (snapshot: SessionTurnSnapshot) => void): () => void {
    if (typeof threadId !== "string" || !threadId) throw new Error("A thread id is required.");
    const session = this.sessions.get(threadId);
    if (!session) throw new Error("The thread session file is not available yet.");
    let state = this.watches.get(threadId);
    if (!state || state.path !== session.path) {
      if (state) {
        if (state.debounce) clearTimeout(state.debounce);
        state.watcher.close();
      }
      const listeners = state?.listeners ?? new Set<(snapshot: SessionTurnSnapshot) => void>();
      const watcher = watch(session.path, { persistent: false }, () => this.scheduleSnapshot(threadId));
      watcher.on("error", () => this.closeWatch(threadId));
      state = { path: session.path, watcher, listeners, debounce: undefined, staleTimeout: undefined };
      this.watches.set(threadId, state);
    }
    state.listeners.add(listener);
    this.scheduleStaleCheck(threadId);
    return () => {
      const current = this.watches.get(threadId);
      if (!current) return;
      current.listeners.delete(listener);
      if (current.listeners.size === 0) this.closeWatch(threadId);
    };
  }

  dispose(): void {
    for (const threadId of [...this.watches.keys()]) this.closeWatch(threadId);
  }

  private observeThread(value: unknown): void {
    if (!isObject(value)) return;
    const id = typeof value.id === "string" ? value.id : undefined;
    const path = typeof value.path === "string" ? value.path : undefined;
    if (!id || !path) return;
    const status = typeof value.status === "string"
      ? value.status
      : isObject(value.status) && typeof value.status.type === "string" ? value.status.type : undefined;
    const appServerActive = status ? isActiveStatus(status) : undefined;
    const previous = this.sessions.get(id);
    if (previous?.path === path) {
      previous.updatedAt = Date.now() / 1000;
      if (appServerActive !== undefined) previous.appServerActive = appServerActive;
    } else {
      const state: SessionState = { path, updatedAt: Date.now() / 1000 };
      if (appServerActive !== undefined) state.appServerActive = appServerActive;
      this.sessions.set(id, state);
    }
    this.scheduleStaleCheck(id);
  }

  private scheduleSnapshot(threadId: string): void {
    const state = this.watches.get(threadId);
    if (!state) return;
    if (state.debounce) clearTimeout(state.debounce);
    state.debounce = setTimeout(() => {
      const current = this.watches.get(threadId);
      if (!current) return;
      current.debounce = undefined;
      void this.turnSnapshot(threadId).then((snapshot) => {
        const latest = this.watches.get(threadId);
        if (!latest) return;
        for (const listener of latest.listeners) listener(snapshot);
        this.scheduleStaleCheck(threadId);
      }).catch(() => {});
    }, 45);
  }

  private closeWatch(threadId: string): void {
    const state = this.watches.get(threadId);
    if (!state) return;
    if (state.debounce) clearTimeout(state.debounce);
    if (state.staleTimeout) clearTimeout(state.staleTimeout);
    state.watcher.close();
    this.watches.delete(threadId);
  }

  private normalizeSnapshot(session: SessionState, snapshot: SessionTurnSnapshot, fileUpdatedAt: number): SessionTurnSnapshot {
    const stale = snapshot.isRunning
      && session.appServerActive === false
      && Date.now() / 1000 - fileUpdatedAt >= staleExternalSessionSeconds;
    return {
      ...snapshot,
      isRunning: stale ? false : snapshot.isRunning,
      ...(stale ? { stale: true, completedAt: snapshot.completedAt ?? fileUpdatedAt } : {}),
      updatedAt: Math.max(fileUpdatedAt, session.updatedAt),
    };
  }

  private scheduleStaleCheck(threadId: string): void {
    const session = this.sessions.get(threadId);
    const state = this.watches.get(threadId);
    if (!session || !state) return;
    if (state.staleTimeout) {
      clearTimeout(state.staleTimeout);
      state.staleTimeout = undefined;
    }
    if (session.appServerActive !== false) return;
    void stat(session.path).then((fileStat) => {
      const current = this.watches.get(threadId);
      if (!current || this.sessions.get(threadId)?.appServerActive !== false) return;
      const staleAt = fileStat.mtimeMs + staleExternalSessionSeconds * 1000;
      current.staleTimeout = setTimeout(() => {
        const latest = this.watches.get(threadId);
        if (!latest) return;
        latest.staleTimeout = undefined;
        void this.turnSnapshot(threadId).then((snapshot) => {
          const subscribed = this.watches.get(threadId);
          if (!subscribed) return;
          for (const listener of subscribed.listeners) listener(snapshot);
          if (snapshot.isRunning) this.scheduleStaleCheck(threadId);
        }).catch(() => {});
      }, Math.max(50, staleAt - Date.now() + 50));
    }).catch(() => {});
  }
}

function isActiveStatus(status: string): boolean {
  return /active|running|progress|started|processing|pending|queued/i.test(status);
}

function responseItem(payload: JsonObject, fallbackId?: string): JsonObject | null {
  const type = typeof payload.type === "string" ? payload.type : "";
  const payloadId = typeof payload.id === "string" ? payload.id : undefined;

  if (type === "message") {
    const role = typeof payload.role === "string" ? payload.role : "assistant";
    const id = payloadId ?? (role === "user" ? fallbackId : undefined);
    if (!id) return null;
    const content = Array.isArray(payload.content) ? payload.content : [];
    const text = content.flatMap((part) => {
      if (!isObject(part)) return [];
      return typeof part.text === "string" ? [part.text] : [];
    }).join("\n");
    if (role === "user") {
      if (isInternalEnvironmentContext(text)) return null;
      return { id, type: "userMessage", content: [{ type: "text", text }] };
    }
    if (role !== "assistant") return null;
    return {
      id,
      type: "agentMessage",
      text,
      phase: typeof payload.phase === "string" ? payload.phase : "commentary",
    };
  }

  const id = payloadId;
  if (!id) return null;

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

function isInternalEnvironmentContext(text: string): boolean {
  return /^\s*<environment_context\b[^>]*>[\s\S]*<\/environment_context>\s*$/i.test(text);
}
