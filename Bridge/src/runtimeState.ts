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
  diffStatistics?: JsonObject;
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
  diffStatistics?: JsonObject;
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
    const eventTurnId = typeof params.turnId === "string" ? params.turnId : undefined;
    if (existing?.activeTurnId && eventTurnId && existing.activeTurnId !== eventTurnId) return;
    if (message.method === "turn/plan/updated" && existing?.isRunning && Array.isArray(params.plan)) {
      const visible = params.plan.length > 0;
      const { upstreamRetrying: _retrying, upstreamError: _error, ...active } = existing;
      this.set(threadId, {
        ...(visible ? active : existing),
        plan: params.plan,
        ...(!existing.outputStartedAt && visible ? { outputStartedAt: this.now() } : {}),
        updatedAt: this.now(),
      });
      return;
    }

    if (message.method === "turn/diff/updated" && existing?.isRunning && typeof params.diff === "string") {
      const visible = params.diff.trim().length > 0;
      const { upstreamRetrying: _retrying, upstreamError: _error, ...active } = existing;
      this.set(threadId, {
        ...(visible ? active : existing),
        diffStatistics: parseDiffStatistics(params.diff),
        ...(!existing.outputStartedAt && visible ? { outputStartedAt: this.now() } : {}),
        updatedAt: this.now(),
      });
      return;
    }

    if (existing?.isRunning && !existing.outputStartedAt && isVisibleTaskActivity(message.method, params)) {
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
    const active: StoredThreadRuntime = {
      isRunning: true,
      ...(observed.turnId ? { activeTurnId: observed.turnId } : current.activeTurnId ? { activeTurnId: current.activeTurnId } : {}),
      ...(observed.startedAt ? { startedAt: observed.startedAt } : current.startedAt ? { startedAt: current.startedAt } : {}),
      ...(current.outputStartedAt ? { outputStartedAt: current.outputStartedAt } : {}),
      ...(current.plan ? { plan: current.plan } : {}),
      ...(current.diffStatistics ? { diffStatistics: current.diffStatistics } : {}),
      ...(current.upstreamRetrying ? { upstreamRetrying: true } : {}),
      ...(current.upstreamError ? { upstreamError: current.upstreamError } : {}),
      updatedAt: Math.max(current.updatedAt, observed.updatedAt),
    };
    this.set(String(threadId), active);
    return { known: true, ...active };
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
    || method.endsWith("Delta")
    || method === "turn/plan/updated"
    || method === "turn/diff/updated";
}

function isVisibleTaskActivity(method: string, params: JsonObject): boolean {
  if (method.startsWith("item/") && (method.endsWith("/delta") || method.endsWith("Delta"))) {
    return typeof params.delta === "string" && params.delta.trim().length > 0;
  }
  if (method !== "item/started" && method !== "item/completed") return false;
  if (!isObject(params.item)) return false;
  const item = params.item;
  switch (item.type) {
    case "agentMessage":
      return nonempty(item.text);
    case "reasoning":
      return nonemptyArray(item.summary) || nonemptyArray(item.content);
    case "commandExecution":
      return nonempty(item.command);
    case "fileChange":
      return Array.isArray(item.changes) && item.changes.length > 0;
    case "webSearch":
      return nonempty(item.query);
    case "plan":
      return nonempty(item.text);
    case "mcpToolCall":
    case "dynamicToolCall":
    case "collabAgentToolCall":
    case "subAgentActivity":
    case "imageView":
    case "imageGeneration":
      return true;
    default:
      return false;
  }
}

function nonempty(value: unknown): boolean {
  return typeof value === "string" && value.trim().length > 0;
}

function nonemptyArray(value: unknown): boolean {
  return Array.isArray(value) && value.some((entry) => nonempty(entry));
}

function parseDiffStatistics(source: string): JsonObject {
  let added = 0;
  let removed = 0;
  let oldPath: string | undefined;
  let currentPath: string | undefined;
  const order: string[] = [];
  const counts = new Map<string, { added: number; removed: number }>();

  const register = (path: string | undefined): void => {
    if (!path || counts.has(path)) return;
    order.push(path);
    counts.set(path, { added: 0, removed: 0 });
  };

  for (const line of source.split(/\r?\n/)) {
    if (line.startsWith("diff --git ")) {
      const paths = gitHeaderPaths(line.slice("diff --git ".length));
      oldPath = paths.old;
      currentPath = paths.new ?? paths.old;
      register(currentPath);
      continue;
    }
    if (line.startsWith("--- ")) {
      oldPath = normalizedDiffPath(line.slice(4));
      continue;
    }
    if (line.startsWith("+++ ")) {
      currentPath = normalizedDiffPath(line.slice(4)) ?? oldPath;
      register(currentPath);
      continue;
    }
    if (line.startsWith("diff ") || line.startsWith("index ") || line.startsWith("@@")) continue;

    if (line.startsWith("+")) {
      added += 1;
      if (currentPath) {
        const count = counts.get(currentPath) ?? { added: 0, removed: 0 };
        count.added += 1;
        counts.set(currentPath, count);
      }
    } else if (line.startsWith("-")) {
      removed += 1;
      if (currentPath) {
        const count = counts.get(currentPath) ?? { added: 0, removed: 0 };
        count.removed += 1;
        counts.set(currentPath, count);
      }
    }
  }

  return {
    added,
    removed,
    files: order.map((path) => ({ path, ...(counts.get(path) ?? { added: 0, removed: 0 }) })),
  };
}

function normalizedDiffPath(source: string): string | undefined {
  let path = source.split("\t", 1)[0]?.trim() ?? "";
  if (!path || path === "/dev/null") return undefined;
  if (path.startsWith("a/") || path.startsWith("b/")) path = path.slice(2);
  return path;
}

function gitHeaderPaths(source: string): { old: string | undefined; new: string | undefined } {
  const separator = source.lastIndexOf(" b/");
  if (separator < 0) return { old: normalizedDiffPath(source), new: undefined };
  return {
    old: normalizedDiffPath(source.slice(0, separator)),
    new: normalizedDiffPath(source.slice(separator + 1)),
  };
}
