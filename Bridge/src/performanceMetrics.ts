import type { JsonObject } from "./protocol.js";

interface TimingSnapshot extends JsonObject {
  count: number;
  averageMs: number;
  p50Ms: number;
  p95Ms: number;
  maxMs: number;
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

  recordCodexEvent(method: string): void {
    this.codexEvents += 1;
    if (method.endsWith("/delta") || method.toLowerCase().includes("delta")) this.codexDeltas += 1;
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
    };
  }
}

function percentile(sorted: number[], value: number): number {
  if (!sorted.length) return 0;
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * value))] ?? 0;
}

function round(value: number): number { return Math.round(value * 100) / 100; }
