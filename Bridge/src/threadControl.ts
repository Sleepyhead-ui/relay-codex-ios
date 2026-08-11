export type ThreadControlMode = "unowned" | "relay-write" | "external-read-only";

export interface ThreadControlStatus {
  mode: ThreadControlMode;
  reason?: "active-writer";
}

export interface WriterReleaseConditions {
  activeTurns: number;
  pendingClientRequests: number;
  pendingInternalRequests: number;
  pendingServerRequests: number;
  pendingDeliveries: number;
  dispatchingQueues: number;
  queuedPrompts: number;
  acquiringThreads: number;
  recoveringDeliveries: boolean;
  configurationReloading: boolean;
}

export class ThreadControlRegistry {
  private readonly ownedThreadIds = new Set<string>();
  private readonly pendingReleaseThreadIds = new Set<string>();

  isOwned(threadId: unknown): boolean {
    return typeof threadId === "string" && this.ownedThreadIds.has(threadId);
  }

  markOwned(threadId: string): boolean {
    if (!threadId || this.ownedThreadIds.has(threadId)) return false;
    this.ownedThreadIds.add(threadId);
    return true;
  }

  status(threadId: string, externalRunning = false): ThreadControlStatus {
    if (this.ownedThreadIds.has(threadId)) return { mode: "relay-write" };
    if (externalRunning) return { mode: "external-read-only", reason: "active-writer" };
    return { mode: "unowned" };
  }

  requestRelease(threadId: string): boolean {
    if (!this.ownedThreadIds.has(threadId)) return false;
    this.pendingReleaseThreadIds.add(threadId);
    return true;
  }

  get hasPendingRelease(): boolean {
    return this.pendingReleaseThreadIds.size > 0;
  }

  get ownedIds(): string[] {
    return [...this.ownedThreadIds];
  }

  get pendingReleaseIds(): string[] {
    return [...this.pendingReleaseThreadIds];
  }

  reset(): string[] {
    const released = [...this.ownedThreadIds];
    this.ownedThreadIds.clear();
    this.pendingReleaseThreadIds.clear();
    return released;
  }
}

export function canRestartForWriterRelease(conditions: WriterReleaseConditions): boolean {
  return conditions.activeTurns === 0
    && conditions.pendingClientRequests === 0
    && conditions.pendingInternalRequests === 0
    && conditions.pendingServerRequests === 0
    && conditions.pendingDeliveries === 0
    && conditions.dispatchingQueues === 0
    && conditions.queuedPrompts === 0
    && conditions.acquiringThreads === 0
    && !conditions.recoveringDeliveries
    && !conditions.configurationReloading;
}
