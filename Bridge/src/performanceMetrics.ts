import type { JsonObject } from "./protocol.js";

interface TimingSnapshot extends JsonObject {
  count: number;
  averageMs: number;
  p50Ms: number;
  p95Ms: number;
  maxMs: number;
}

interface ActiveTurnTiming {
  clientUserMessageId: string;
  threadId: string;
  turnId?: string;
  model?: string;
  effort?: string;
  summary?: string;
  receivedAt: string;
  receivedMs: number;
  forwardedMs?: number;
  acceptedMs?: number;
  startedMs?: number;
  firstEventMs?: number;
  firstVisibleMs?: number;
  firstVisibleMethod?: string;
}

export interface TurnLatencySnapshot extends JsonObject {
  clientUserMessageId: string;
  threadId: string;
  turnId: string | null;
  model: string | null;
  effort: string | null;
  summary: string | null;
  receivedAt: string;
  completedAt: string;
  receivedToForwardMs: number | null;
  forwardToAcceptedMs: number | null;
  acceptedToStartedMs: number | null;
  startedToFirstEventMs: number | null;
  startedToFirstVisibleMs: number | null;
  totalToFirstVisibleMs: number | null;
  totalDurationMs: number;
  firstVisibleMethod: string | null;
}

class BoundedTiming {
  private readonly samples: number[] = [];
  private total = 0;
  private maximum = 0;

  constructor(private readonly limit = 256) {}

  record(milliseconds: number): void {
    if (!Number.isFinite(milliseconds) || milliseconds < 0) return;
    this.samples.push(milliseconds);
    this.total += milliseconds;
    this.maximum = Math.max(this.maximum, milliseconds);
    if (this.samples.length > this.limit) {
      this.total -= this.samples.shift() ?? 0;
      this.maximum = this.samples.length ? Math.max(...this.samples) : 0;
    }
  }

  snapshot(): TimingSnapshot {
    const sorted = [...this.samples].sort((left, right) => left - right);
    return {
      count: sorted.length,
      averageMs: round(sorted.length ? this.total / sorted.length : 0),
      p50Ms: round(percentile(sorted, 0.5)),
      p95Ms: round(percentile(sorted, 0.95)),
      maxMs: round(this.maximum),
    };
  }
}

export class PerformanceMetrics {
  private inboundMessages = 0;
  private inboundBytes = 0;
  private outboundMessages = 0;
  private outboundBytes = 0;
  private sessionSnapshots = 0;
  private sessionSnapshotBytes = 0;
  private sessionPatches = 0;
  private sessionPatchBytes = 0;
  private suppressedSessionUpdates = 0;
  private codexEvents = 0;
  private codexDeltas = 0;
  private readonly rpcLatency = new BoundedTiming();
  private readonly firstVisibleLatency = new BoundedTiming();
  private readonly activeTurnsByClientId = new Map<string, ActiveTurnTiming>();
  private readonly activeTurnClientByThreadId = new Map<string, string>();
  private readonly activeTurnClientByTurnId = new Map<string, string>();
  private readonly recentTurnLatencies: TurnLatencySnapshot[] = [];

  recordInbound(bytes: number): void {
    this.inboundMessages += 1;
    this.inboundBytes += Math.max(0, bytes);
  }

  recordOutbound(message: JsonObject, bytes: number): void {
    this.outboundMessages += 1;
    this.outboundBytes += Math.max(0, bytes);
    if (message.type === "sessionSnapshot") {
      this.sessionSnapshots += 1;
      this.sessionSnapshotBytes += Math.max(0, bytes);
    } else if (message.type === "sessionPatch") {
      this.sessionPatches += 1;
      this.sessionPatchBytes += Math.max(0, bytes);
    }
  }

  recordSuppressedSessionUpdate(): void { this.suppressedSessionUpdates += 1; }
  recordRpcLatency(milliseconds: number): void { this.rpcLatency.record(milliseconds); }

  recordTurnReceived(
    params: JsonObject,
    receivedMs = performance.now(),
    receivedAt = new Date().toISOString(),
  ): void {
    const clientUserMessageId = stringValue(params.clientUserMessageId);
    const threadId = stringValue(params.threadId);
    if (!clientUserMessageId || !threadId) return;
    const timing: ActiveTurnTiming = {
      clientUserMessageId,
      threadId,
      ...(stringValue(params.model) ? { model: stringValue(params.model)! } : {}),
      ...(stringValue(params.effort) ? { effort: stringValue(params.effort)! } : {}),
      ...(stringValue(params.summary) ? { summary: stringValue(params.summary)! } : {}),
      receivedAt,
      receivedMs,
    };
    this.activeTurnsByClientId.set(clientUserMessageId, timing);
    this.activeTurnClientByThreadId.set(threadId, clientUserMessageId);
  }

  recordTurnForwarded(clientUserMessageId: string | undefined): void {
    const timing = clientUserMessageId ? this.activeTurnsByClientId.get(clientUserMessageId) : undefined;
    if (timing && timing.forwardedMs === undefined) timing.forwardedMs = performance.now();
  }

  recordTurnAccepted(clientUserMessageId: string | undefined, turnId: string | undefined): void {
    const timing = clientUserMessageId ? this.activeTurnsByClientId.get(clientUserMessageId) : undefined;
    if (!timing) return;
    if (timing.acceptedMs === undefined) timing.acceptedMs = performance.now();
    if (turnId) this.bindTurn(timing, turnId);
  }

  recordTurnRejected(clientUserMessageId: string | undefined): void {
    if (!clientUserMessageId) return;
    const timing = this.activeTurnsByClientId.get(clientUserMessageId);
    if (!timing) return;
    this.removeActiveTurn(timing);
  }

  recordCodexEvent(method: string, params: JsonObject = {}): TurnLatencySnapshot | undefined {
    this.codexEvents += 1;
    if (method.endsWith("/delta") || method.toLowerCase().includes("delta")) this.codexDeltas += 1;
    const threadId = stringValue(params.threadId);
    const turn = objectValue(params.turn);
    const turnId = stringValue(params.turnId) ?? stringValue(turn?.id);
    let clientUserMessageId = turnId ? this.activeTurnClientByTurnId.get(turnId) : undefined;
    if (!clientUserMessageId && threadId) clientUserMessageId = this.activeTurnClientByThreadId.get(threadId);
    const timing = clientUserMessageId ? this.activeTurnsByClientId.get(clientUserMessageId) : undefined;
    if (!timing) return undefined;
    if (turnId && !timing.turnId) this.bindTurn(timing, turnId);
    const now = performance.now();
    if (method === "turn/started" && timing.startedMs === undefined) timing.startedMs = now;
    if (method !== "turn/started" && timing.firstEventMs === undefined) timing.firstEventMs = now;
    if (timing.firstVisibleMs === undefined && isVisibleTurnEvent(method, params)) {
      timing.firstVisibleMs = now;
      timing.firstVisibleMethod = method;
    }
    if (!isTerminalTurnEvent(method)) return undefined;
    const snapshot = this.completeTurn(timing, now);
    this.recentTurnLatencies.unshift(snapshot);
    if (this.recentTurnLatencies.length > 20) this.recentTurnLatencies.length = 20;
    if (snapshot.totalToFirstVisibleMs !== null) this.firstVisibleLatency.record(snapshot.totalToFirstVisibleMs);
    this.removeActiveTurn(timing);
    return snapshot;
  }

  report(): JsonObject {
    const fullBytes = this.sessionSnapshotBytes;
    const patchBytes = this.sessionPatchBytes;
    return {
      network: {
        inboundMessages: this.inboundMessages,
        inboundBytes: this.inboundBytes,
        outboundMessages: this.outboundMessages,
        outboundBytes: this.outboundBytes,
      },
      sessions: {
        snapshots: this.sessionSnapshots,
        snapshotBytes: fullBytes,
        patches: this.sessionPatches,
        patchBytes,
        suppressedUpdates: this.suppressedSessionUpdates,
        patchToSnapshotByteRatio: round(fullBytes > 0 ? patchBytes / fullBytes : 0),
      },
      codex: { events: this.codexEvents, deltas: this.codexDeltas },
      rpcLatency: this.rpcLatency.snapshot(),
      turnLatency: {
        firstVisible: this.firstVisibleLatency.snapshot(),
        recent: this.recentTurnLatencies,
      },
    };
  }

  private bindTurn(timing: ActiveTurnTiming, turnId: string): void {
    timing.turnId = turnId;
    this.activeTurnClientByTurnId.set(turnId, timing.clientUserMessageId);
  }

  private completeTurn(timing: ActiveTurnTiming, completedMs: number): TurnLatencySnapshot {
    return {
      clientUserMessageId: timing.clientUserMessageId,
      threadId: timing.threadId,
      turnId: timing.turnId ?? null,
      model: timing.model ?? null,
      effort: timing.effort ?? null,
      summary: timing.summary ?? null,
      receivedAt: timing.receivedAt,
      completedAt: new Date().toISOString(),
      receivedToForwardMs: duration(timing.receivedMs, timing.forwardedMs),
      forwardToAcceptedMs: duration(timing.forwardedMs, timing.acceptedMs),
      acceptedToStartedMs: duration(timing.acceptedMs, timing.startedMs),
      startedToFirstEventMs: duration(timing.startedMs, timing.firstEventMs),
      startedToFirstVisibleMs: duration(timing.startedMs, timing.firstVisibleMs),
      totalToFirstVisibleMs: duration(timing.receivedMs, timing.firstVisibleMs),
      totalDurationMs: round(completedMs - timing.receivedMs),
      firstVisibleMethod: timing.firstVisibleMethod ?? null,
    };
  }

  private removeActiveTurn(timing: ActiveTurnTiming): void {
    this.activeTurnsByClientId.delete(timing.clientUserMessageId);
    if (this.activeTurnClientByThreadId.get(timing.threadId) === timing.clientUserMessageId) {
      this.activeTurnClientByThreadId.delete(timing.threadId);
    }
    if (timing.turnId && this.activeTurnClientByTurnId.get(timing.turnId) === timing.clientUserMessageId) {
      this.activeTurnClientByTurnId.delete(timing.turnId);
    }
  }
}

function isVisibleTurnEvent(method: string, params: JsonObject): boolean {
  if (method.toLowerCase().endsWith("delta")) return Boolean(stringValue(params.delta));
  if (method === "turn/plan/updated") return true;
  if (method !== "item/started" && method !== "item/completed") return false;
  const item = objectValue(params.item);
  const type = stringValue(item?.type);
  if (!type || type === "userMessage" || type === "reasoning") return false;
  if (type === "agentMessage") return Boolean(stringValue(item?.text));
  return true;
}

function isTerminalTurnEvent(method: string): boolean {
  return ["turn/completed", "turn/aborted", "turn/interrupted", "turn/failed"].includes(method);
}

function duration(start: number | undefined, end: number | undefined): number | null {
  return start === undefined || end === undefined ? null : round(Math.max(0, end - start));
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function objectValue(value: unknown): JsonObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as JsonObject : undefined;
}

function percentile(sorted: number[], value: number): number {
  if (!sorted.length) return 0;
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * value))] ?? 0;
}

function round(value: number): number { return Math.round(value * 100) / 100; }
