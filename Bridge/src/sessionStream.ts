import type { JsonObject } from "./protocol.js";
import type { SessionTurnSnapshot } from "./sessionActivity.js";
import { boundSessionSnapshot, SessionPatchCursor } from "./sessionPatch.js";

export interface SessionStreamTransport {
  bufferedAmount(): number;
  send(message: JsonObject): number;
}

export interface SessionStreamMetrics {
  recordBackpressure(bufferedAmount: number): void;
  recordCoalescedSessionUpdate(estimatedBytes: number): void;
  recordSessionFrame(frameBytes: number, bufferedAmount: number): void;
  recordSuppressedSessionUpdate(): void;
}

const defaultHighWaterBytes = 256 * 1024;
const defaultRetryDelayMs = 20;

/** Sends only revisions derived from the last state actually put on the wire. */
export class SessionStream {
  private readonly cursor: SessionPatchCursor | undefined;
  private initialized = false;
  private disposed = false;
  private pending: SessionTurnSnapshot | undefined;
  private flushScheduled = false;
  private retryTimer: NodeJS.Timeout | undefined;

  constructor(
    private readonly threadId: string,
    readonly subscriptionId: string | undefined,
    incremental: boolean,
    private readonly transport: SessionStreamTransport,
    private readonly metrics: SessionStreamMetrics,
    private readonly highWaterBytes = defaultHighWaterBytes,
    private readonly retryDelayMs = defaultRetryDelayMs,
  ) {
    this.cursor = incremental ? new SessionPatchCursor() : undefined;
  }

  initialize(snapshot: SessionTurnSnapshot): SessionTurnSnapshot {
    const bounded = boundSessionSnapshot(snapshot);
    const result = this.cursor ? this.cursor.reset(bounded) : bounded;
    this.initialized = true;
    this.scheduleFlush();
    return result;
  }

  enqueue(snapshot: SessionTurnSnapshot): void {
    if (this.disposed) return;
    if (this.pending) {
      this.metrics.recordCoalescedSessionUpdate(estimateSnapshotBytes(this.pending));
    }
    this.pending = snapshot;
    if (this.initialized) this.scheduleFlush();
  }

  dispose(): void {
    this.disposed = true;
    this.pending = undefined;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = undefined;
  }

  private scheduleFlush(): void {
    if (this.disposed || this.flushScheduled || this.retryTimer || !this.pending) return;
    this.flushScheduled = true;
    queueMicrotask(() => {
      this.flushScheduled = false;
      this.flush();
    });
  }

  private flush(): void {
    if (this.disposed || !this.initialized || !this.pending) return;
    const bufferedBefore = this.transport.bufferedAmount();
    if (bufferedBefore > this.highWaterBytes) {
      this.metrics.recordBackpressure(bufferedBefore);
      this.retryTimer = setTimeout(() => {
        this.retryTimer = undefined;
        this.flush();
      }, this.retryDelayMs);
      this.retryTimer.unref?.();
      return;
    }

    const snapshot = this.pending;
    this.pending = undefined;
    const update = this.cursor?.update(snapshot);
    if (this.cursor && !update) {
      this.metrics.recordSuppressedSessionUpdate();
      this.scheduleFlush();
      return;
    }
    const lease = this.subscriptionId ? { subscriptionId: this.subscriptionId } : {};
    const message: JsonObject = update?.type === "sessionPatch"
      ? { type: "sessionPatch", source: "rollout", threadId: this.threadId, patch: update.patch, ...lease }
      : update?.type === "sessionSnapshot"
        ? { type: "sessionSnapshot", source: "rollout", threadId: this.threadId, snapshot: update.snapshot, ...lease }
        : { type: "sessionSnapshot", source: "rollout", threadId: this.threadId, snapshot: boundSessionSnapshot(snapshot), ...lease };
    const frameBytes = this.transport.send(message);
    this.metrics.recordSessionFrame(frameBytes, this.transport.bufferedAmount());
    this.scheduleFlush();
  }
}

function estimateSnapshotBytes(snapshot: SessionTurnSnapshot): number {
  const items = snapshot.items?.length ?? 0;
  return Math.max(128, items * 96);
}
