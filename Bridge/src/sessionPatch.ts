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

export const maxSessionSnapshotBytes = 768 * 1024;
export const maxTechnicalTextBytes = 192 * 1024;

/** Maintains the wire-level state for one socket/thread subscription. */
export class SessionPatchCursor {
  private revision = 0;
  private snapshot: SessionTurnSnapshot | undefined;
  private itemSignatures = new Map<string, string>();

  reset(snapshot: SessionTurnSnapshot): SessionTurnSnapshot {
    snapshot = boundSessionSnapshot(snapshot);
    this.revision = 0;
    this.snapshot = snapshot;
    this.itemSignatures = signatures(snapshot.items);
    return { ...snapshot, revision: this.revision };
  }

  update(next: SessionTurnSnapshot): SessionCursorUpdate {
    next = boundSessionSnapshot(next);
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

/**
 * Session updates are transcript previews, not file-transfer payloads. Keep
 * them comfortably below the WebSocket frame ceiling while retaining the
 * beginning and end of command output, where errors and summaries live.
 */
export function boundSessionSnapshot(
  snapshot: SessionTurnSnapshot,
  maxSnapshotBytes = maxSessionSnapshotBytes,
): SessionTurnSnapshot {
  const sourceItems = snapshot.items ?? [];
  const items = sourceItems.map(boundSessionItem);
  let result: SessionTurnSnapshot = { ...snapshot, items };
  if (encodedBytes(result) <= maxSnapshotBytes) return result;

  const { items: _sourceItems, ...metadata } = snapshot;
  const base: SessionTurnSnapshot = {
    ...metadata,
    items: [],
    itemsTruncated: true,
    omittedItemCount: sourceItems.length,
  };
  let availableBytes = Math.max(0, maxSnapshotBytes - encodedBytes(base));
  let firstRetainedIndex = items.length;
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const itemBytes = encodedBytes(items[index]!) + (firstRetainedIndex < items.length ? 1 : 0);
    if (itemBytes > availableBytes) break;
    availableBytes -= itemBytes;
    firstRetainedIndex = index;
  }
  const retained = items.slice(firstRetainedIndex);

  result = {
    ...metadata,
    items: retained,
    itemsTruncated: true,
    omittedItemCount: sourceItems.length - retained.length,
  };
  return result;
}

function boundSessionItem(item: JsonObject): JsonObject {
  let changed = false;
  const bounded: JsonObject = { ...item };
  for (const key of ["aggregatedOutput", "output", "result"]) {
    const value = item[key];
    if (typeof value !== "string" || Buffer.byteLength(value) <= maxTechnicalTextBytes) continue;
    const preview = headTail(value, maxTechnicalTextBytes);
    bounded[key] = preview.text;
    bounded[`${key}Truncated`] = true;
    bounded[`${key}OriginalBytes`] = preview.originalBytes;
    bounded[`${key}OmittedBytes`] = preview.omittedBytes;
    changed = true;
  }
  return changed ? bounded : item;
}

function headTail(value: string, maximumBytes: number): {
  text: string;
  originalBytes: number;
  omittedBytes: number;
} {
  const bytes = Buffer.from(value, "utf8");
  const noticeReserve = 96;
  const contentBudget = Math.max(0, maximumBytes - noticeReserve);
  const headBytes = Math.floor(contentBudget * 0.35);
  const tailBytes = contentBudget - headBytes;
  const omittedBytes = Math.max(0, bytes.length - headBytes - tailBytes);
  const notice = `\n... Relay omitted ${omittedBytes} bytes from this transcript preview ...\n`;
  const head = bytes.subarray(0, headBytes).toString("utf8").replace(/\uFFFD$/u, "");
  const tail = bytes.subarray(bytes.length - tailBytes).toString("utf8").replace(/^\uFFFD+/u, "");
  return { text: `${head}${notice}${tail}`, originalBytes: bytes.length, omittedBytes };
}

function encodedBytes(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value));
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
