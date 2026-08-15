import { isObject, type JsonObject } from "./protocol.js";
import type { SessionActivitySnapshot, SessionActivityTracker } from "./sessionActivity.js";

export interface ThreadRuntimeSnapshot extends JsonObject {
  known: boolean;
  isRunning: boolean;
  activeTurnId?: string;
  observedTurnId?: string;
  startedAt?: number;
  outputStartedAt?: number;
  plan?: unknown[];
  upstreamRetrying?: boolean;
  upstreamError?: string;
  updatedAt: number;
}

interface StoredThreadRuntime {
  isRunning: boolean;
  activeTurnId?: string;
  startedAt?: number;
  outputStartedAt?: number;
  plan?: unknown[];
  upstreamRetrying?: boolean;
  upstreamError?: string;
  updatedAt: number;
}

export class RuntimeStateTracker {
  private readonly threads = new Map<string, StoredThreadRuntime>();

  constructor(private readonly now: () => number = () => Date.now() / 1000) {}

  observeTurnStart(threadId: unknown, turn: unknown): void {
    if (typeof threadId !== "string" || !threadId) return;
    const turnObject = isObject(turn) ? turn : {};
    const activeTurnId = typeof turnObject.id === "string" ? turnObject.id : undefined;
    const startedAt = numberValue(turnObject.startedAt) ?? this.now();
    const state: StoredThreadRuntime = { isRunning: true, startedAt, updatedAt: this.now() };
    if (activeTurnId) state.activeTurnId = activeTurnId;
    this.set(threadId, state);
  }

  observeNotification(message: JsonObject): void {
    if (typeof message.method !== "string" || !isObject(message.params)) return;
    const params = message.params;
    const threadId = typeof params.threadId === "string" ? params.threadId : undefined;
    if (!threadId) return;

    if (message.method === "turn/started") {
      this.observeTurnStart(threadId, params.turn);
      return;
    }

    if (message.method === "error") {
      const turnId = typeof params.turnId === "string" ? params.turnId : undefined;
      const existing = this.threads.get(threadId);
      if (!existing || (turnId && existing.activeTurnId && existing.activeTurnId !== turnId)) return;
      const upstreamError = errorMessage(params.error) ?? errorMessage(params);
      if (params.willRetry === true) {
        this.set(threadId, {
          ...existing,
          isRunning: true,
          ...(turnId && !existing.activeTurnId ? { activeTurnId: turnId } : {}),
          upstreamRetrying: true,
          ...(upstreamError ? { upstreamError } : {}),
          updatedAt: this.now(),
        });
      } else if (params.willRetry === false) {
        this.set(threadId, {
          isRunning: false,
          ...(upstreamError ? { upstreamError } : {}),
          updatedAt: this.now(),
        });
      }
      return;
    }

    if (["turn/completed", "turn/aborted", "turn/interrupted", "turn/failed"].includes(message.method)) {
      const turn = isObject(params.turn) ? params.turn : {};
      const turnId = typeof turn.id === "string"
        ? turn.id
        : typeof params.turnId === "string" ? params.turnId : undefined;
      const existing = this.threads.get(threadId);
      if (!existing || !turnId || !existing.activeTurnId || existing.activeTurnId === turnId) {
        this.set(threadId, { isRunning: false, updatedAt: this.now() });
      }
      return;
    }

    const existing = this.threads.get(threadId);
    if (message.method === "turn/plan/updated" && existing?.isRunning && Array.isArray(params.plan)) {
      this.set(threadId, { ...existing, plan: params.plan, updatedAt: this.now() });
      return;
    }

    if (existing?.isRunning && !existing.outputStartedAt && isVisibleAssistantOutput(message.method, params)) {
      const item = isObject(params.item) ? params.item : {};
      const { upstreamRetrying: _retrying, upstreamError: _error, ...active } = existing;
      this.set(threadId, {
        ...active,
        outputStartedAt: numberValue(item.createdAt) ?? this.now(),
        updatedAt: this.now(),
      });
      return;
    }

    if (isProgressNotification(message.method)) {
      if (existing?.isRunning && existing.upstreamRetrying) {
        const { upstreamRetrying: _retrying, upstreamError: _error, ...active } = existing;
        this.set(threadId, { ...active, updatedAt: this.now() });
      }
    }
  }

  snapshot(threadId: unknown): ThreadRuntimeSnapshot {
    if (typeof threadId !== "string" || !threadId) {
      return { known: false, isRunning: false, updatedAt: this.now() };
    }
    const state = this.threads.get(threadId);
    if (!state) return { known: false, isRunning: false, updatedAt: this.now() };
    return { known: true, ...state };
  }

  async snapshotWithExternal(threadId: unknown, external: SessionActivityTracker): Promise<ThreadRuntimeSnapshot> {
    const observed = await external.snapshot(threadId);
    return this.snapshotWithObservation(threadId, observed);
  }

  snapshotWithObservation(threadId: unknown, observed: SessionActivitySnapshot | null): ThreadRuntimeSnapshot {
    const current = this.snapshot(threadId);
    if (!observed) return current;
    if (!observed.active) {
      const sameTurn = Boolean(
        current.activeTurnId
        && observed.turnId
        && current.activeTurnId === observed.turnId,
      );
      const activeFreshness = Math.max(current.updatedAt, current.startedAt ?? 0);
      if (current.isRunning && (!sameTurn || observed.updatedAt < activeFreshness)) return current;
      const completed: StoredThreadRuntime = {
        isRunning: false,
        updatedAt: Math.max(current.updatedAt, observed.updatedAt),
      };
      this.set(String(threadId), completed);
      return {
        known: true,
        isRunning: false,
        ...(observed.turnId ? { observedTurnId: observed.turnId } : {}),
        updatedAt: completed.updatedAt,
      };
    }
    if (!current.isRunning && current.known && observed.updatedAt < current.updatedAt) return current;
    if (
      current.isRunning
      && current.activeTurnId
      && observed.turnId
      && current.activeTurnId !== observed.turnId
      && observed.updatedAt < current.updatedAt
    ) return current;
    return {
      known: true,
      isRunning: true,
      ...(observed.turnId ? { activeTurnId: observed.turnId } : current.activeTurnId ? { activeTurnId: current.activeTurnId } : {}),
      ...(observed.startedAt ? { startedAt: observed.startedAt } : {}),
      ...(current.outputStartedAt ? { outputStartedAt: current.outputStartedAt } : {}),
      ...(current.plan ? { plan: current.plan } : {}),
      ...(current.upstreamRetrying ? { upstreamRetrying: true } : {}),
      ...(current.upstreamError ? { upstreamError: current.upstreamError } : {}),
      updatedAt: Math.max(current.updatedAt, observed.updatedAt),
    };
  }

  get activeCount(): number {
    let count = 0;
    for (const state of this.threads.values()) if (state.isRunning) count += 1;
    return count;
  }

  stopAll(error?: string): void {
    const updatedAt = this.now();
    for (const threadId of [...this.threads.keys()]) {
      this.set(threadId, {
        isRunning: false,
        ...(error ? { upstreamError: error } : {}),
        updatedAt,
      });
    }
  }

  private set(threadId: string, state: StoredThreadRuntime): void {
    this.threads.delete(threadId);
    this.threads.set(threadId, state);
    while (this.threads.size > 100) {
      const oldest = this.threads.keys().next().value as string | undefined;
      if (!oldest) break;
      this.threads.delete(oldest);
    }
  }
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function errorMessage(value: unknown): string | undefined {
  if (!isObject(value)) return undefined;
  return typeof value.message === "string" && value.message ? value.message : undefined;
}

function isProgressNotification(method: string): boolean {
  return method === "item/started"
    || method === "item/completed"
    || method.startsWith("item/") && method.endsWith("/delta")
    || method === "turn/plan/updated";
}

function isVisibleAssistantOutput(method: string, params: JsonObject): boolean {
  if (method === "item/agentMessage/delta") {
    return params.phase !== "commentary"
      && typeof params.delta === "string"
      && params.delta.trim().length > 0;
  }
  if (method !== "item/started" && method !== "item/completed") return false;
  if (!isObject(params.item) || params.item.type !== "agentMessage" || params.item.phase === "commentary") return false;
  return typeof params.item.text === "string" && params.item.text.trim().length > 0;
}
