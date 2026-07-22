import { describe, expect, it } from "vitest";
import { BoundedTimingMonitor, DesktopPerformanceMetrics } from "./performanceMetrics";

describe("desktop performance metrics", () => {
  it("keeps only the newest bounded latency samples", () => {
    const timing = new BoundedTimingMonitor(256);
    for (let value = 1; value <= 300; value += 1) timing.record(value);
    const report = timing.snapshot();
    expect(report.count).toBe(256);
    expect(report.p95Ms).toBeGreaterThanOrEqual(280);
    expect(report.maxMs).toBe(300);
  });

  it("reports revision recovery and frame batching", () => {
    const metrics = new DesktopPerformanceMetrics();
    metrics.recordSessionSnapshot(9);
    metrics.recordSessionPatch(2);
    metrics.recordRevisionGap();
    metrics.recordRecovery();
    for (let index = 0; index < 4; index += 1) metrics.recordQueuedDelta();
    metrics.recordFrameFlush(3, 5);

    const report = metrics.report();
    expect(report.sessions).toMatchObject({ snapshots: 1, patches: 1, revisionGaps: 1, recoveries: 1 });
    expect(report.deltas).toMatchObject({ queued: 4, frameFlushes: 1, updatedItems: 3, maxItemsPerFrame: 3 });
    expect(report.deltas.flushLatency.p95Ms).toBe(5);
  });
});
