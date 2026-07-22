export interface TimingMetrics {
  count: number;
  averageMs: number;
  p50Ms: number;
  p95Ms: number;
  maxMs: number;
}

export class BoundedTimingMonitor {
  private samples: number[] = [];
  private total = 0;
  private maximum = 0;

  constructor(private readonly limit = 256) {}

  record(milliseconds: number) {
    if (!Number.isFinite(milliseconds) || milliseconds < 0) return;
    this.samples.push(milliseconds);
    this.total += milliseconds;
    this.maximum = Math.max(this.maximum, milliseconds);
    if (this.samples.length > Math.max(1, this.limit)) {
      this.total -= this.samples.shift() ?? 0;
      this.maximum = this.samples.length ? Math.max(...this.samples) : 0;
    }
  }

  snapshot(): TimingMetrics {
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

export interface DesktopPerformanceReport {
  sessions: {
    snapshots: number;
    patches: number;
    revisionGaps: number;
    recoveries: number;
    snapshotApplyLatency: TimingMetrics;
    patchApplyLatency: TimingMetrics;
  };
  deltas: {
    queued: number;
    frameFlushes: number;
    updatedItems: number;
    maxItemsPerFrame: number;
    flushLatency: TimingMetrics;
  };
}

export class DesktopPerformanceMetrics {
  private snapshots = 0;
  private patches = 0;
  private revisionGaps = 0;
  private recoveries = 0;
  private queuedDeltas = 0;
  private frameFlushes = 0;
  private updatedItems = 0;
  private maxItemsPerFrame = 0;
  private readonly snapshotApplyLatency = new BoundedTimingMonitor();
  private readonly patchApplyLatency = new BoundedTimingMonitor();
  private readonly flushLatency = new BoundedTimingMonitor();

  recordSessionSnapshot(milliseconds: number) {
    this.snapshots += 1;
    this.snapshotApplyLatency.record(milliseconds);
  }

  recordSessionPatch(milliseconds: number) {
    this.patches += 1;
    this.patchApplyLatency.record(milliseconds);
  }

  recordRevisionGap() { this.revisionGaps += 1; }
  recordRecovery() { this.recoveries += 1; }
  recordQueuedDelta() { this.queuedDeltas += 1; }

  recordFrameFlush(items: number, milliseconds: number) {
    this.frameFlushes += 1;
    this.updatedItems += Math.max(0, items);
    this.maxItemsPerFrame = Math.max(this.maxItemsPerFrame, items);
    this.flushLatency.record(milliseconds);
  }

  report(): DesktopPerformanceReport {
    return {
      sessions: {
        snapshots: this.snapshots,
        patches: this.patches,
        revisionGaps: this.revisionGaps,
        recoveries: this.recoveries,
        snapshotApplyLatency: this.snapshotApplyLatency.snapshot(),
        patchApplyLatency: this.patchApplyLatency.snapshot(),
      },
      deltas: {
        queued: this.queuedDeltas,
        frameFlushes: this.frameFlushes,
        updatedItems: this.updatedItems,
        maxItemsPerFrame: this.maxItemsPerFrame,
        flushLatency: this.flushLatency.snapshot(),
      },
    };
  }
}

function percentile(sorted: number[], fraction: number) {
  if (!sorted.length) return 0;
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * fraction))] ?? 0;
}

function round(value: number) { return Math.round(value * 100) / 100; }
