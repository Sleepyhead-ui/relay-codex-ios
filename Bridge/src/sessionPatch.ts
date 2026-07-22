import type { JsonObject } from "./protocol.js";
import type { SessionTurnSnapshot } from "./sessionActivity.js";

export interface SessionPatch extends JsonObject {
  baseRevision: number;
  revision: number;
  known: boolean;
  isRunning: boolean;
  updatedAt: number;
  turnId?: string;
  startedAt?: number;
  completedAt?: number;
  stale?: boolean;
  upsertItems: JsonObject[];
  removedItemIds: string[];
}

export type SessionCursorUpdate =
  | { type: "sessionPatch"; patch: SessionPatch }
  | { type: "sessionSnapshot"; snapshot: SessionTurnSnapshot }
  | null;

/** Maintains the wire-level state for one socket/thread subscription. */
export class SessionPatchCursor {
  private revision = 0;
  private snapshot: SessionTurnSnapshot | undefined;
  private itemSignatures = new Map<string, string>();

  reset(snapshot: SessionTurnSnapshot): SessionTurnSnapshot {
    this.revision = 0;
    this.snapshot = snapshot;
    this.itemSignatures = signatures(snapshot.items);
    return { ...snapshot, revision: this.revision };
  }

  update(next: SessionTurnSnapshot): SessionCursorUpdate {
    if (!this.snapshot) return { type: "sessionSnapshot", snapshot: this.reset(next) };

    const previous = this.snapshot;
    if (previous.turnId !== next.turnId || previous.known !== next.known) {
      this.revision += 1;
      this.snapshot = next;
      this.itemSignatures = signatures(next.items);
      return { type: "sessionSnapshot", snapshot: { ...next, revision: this.revision } };
    }

    const nextSignatures = signatures(next.items);
    const upsertItems = (next.items ?? []).filter((item) => {
      const id = itemId(item);
      return id !== undefined && this.itemSignatures.get(id) !== nextSignatures.get(id);
    });
    const removedItemIds = [...this.itemSignatures.keys()].filter((id) => !nextSignatures.has(id));
    const metadataChanged = snapshotMetadataSignature(previous) !== snapshotMetadataSignature(next);
    if (!metadataChanged && upsertItems.length === 0 && removedItemIds.length === 0) return null;

    const baseRevision = this.revision;
    this.revision += 1;
    const patch: SessionPatch = {
      baseRevision,
      revision: this.revision,
      known: next.known,
      isRunning: next.isRunning,
      updatedAt: next.updatedAt,
      upsertItems,
      removedItemIds,
      ...(next.turnId ? { turnId: next.turnId } : {}),
      ...(next.startedAt !== undefined ? { startedAt: next.startedAt } : {}),
      ...(next.completedAt !== undefined ? { completedAt: next.completedAt } : {}),
      ...(next.stale !== undefined ? { stale: next.stale } : {}),
    };

    this.snapshot = next;
    this.itemSignatures = nextSignatures;
    const fullSnapshot = { ...next, revision: this.revision };
    if (JSON.stringify(patch).length >= JSON.stringify(fullSnapshot).length) {
      return { type: "sessionSnapshot", snapshot: fullSnapshot };
    }
    return { type: "sessionPatch", patch };
  }
}

function signatures(items: JsonObject[] | undefined): Map<string, string> {
  const result = new Map<string, string>();
  for (const item of items ?? []) {
    const id = itemId(item);
    if (id !== undefined) result.set(id, JSON.stringify(item));
  }
  return result;
}

function itemId(item: JsonObject): string | undefined {
  return typeof item.id === "string" && item.id ? item.id : undefined;
}

function snapshotMetadataSignature(snapshot: SessionTurnSnapshot): string {
  return JSON.stringify({
    known: snapshot.known,
    isRunning: snapshot.isRunning,
    turnId: snapshot.turnId,
    startedAt: snapshot.startedAt,
    completedAt: snapshot.completedAt,
    stale: snapshot.stale,
  });
}
