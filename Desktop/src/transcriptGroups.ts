import type { TranscriptItem } from "./types";

export interface TranscriptGroupWindow {
  groups: Array<{ id: string; items: TranscriptItem[] }>;
  hasEarlierGroups: boolean;
}

type TranscriptMutation = {
  previous: TranscriptItem[];
  changedItemIds: string[];
};

const mutations = new WeakMap<TranscriptItem[], TranscriptMutation>();

export function markTranscriptUpserts(
  previous: TranscriptItem[],
  next: TranscriptItem[],
  changedItemIds: Iterable<string>,
) {
  if (next !== previous) mutations.set(next, { previous, changedItemIds: [...new Set(changedItemIds)] });
  return next;
}

export class TranscriptGroupIndex {
  private items: TranscriptItem[] = [];
  private groups: Array<{ id: string; items: TranscriptItem[] }> = [];
  private locations = new Map<string, { groupIndex: number; itemIndex: number; absoluteIndex: number }>();
  fullRebuildCount = 0;
  incrementalUpdateCount = 0;

  window(items: TranscriptItem[], limit: number): TranscriptGroupWindow {
    this.synchronize(items);
    const visibleLimit = Math.max(1, Math.trunc(limit));
    const start = Math.max(0, this.groups.length - visibleLimit);
    return {
      groups: start ? this.groups.slice(start) : this.groups,
      hasEarlierGroups: start > 0,
    };
  }

  private synchronize(next: TranscriptItem[]) {
    if (next === this.items) return;
    const mutation = mutations.get(next);
    if (!mutation || mutation.previous !== this.items || !this.applyUpserts(next, mutation.changedItemIds)) {
      this.rebuild(next);
      return;
    }
    this.items = next;
    this.incrementalUpdateCount += 1;
  }

  private applyUpserts(next: TranscriptItem[], changedItemIds: string[]) {
    if (next.length < this.items.length) return false;
    const changed = new Set(changedItemIds);
    const appendedIds = new Set(next.slice(this.items.length).map((item) => item.id));
    for (const id of appendedIds) changed.add(id);

    for (const id of changed) {
      const location = this.locations.get(id);
      if (!location) {
        const nextIndex = next.findIndex((item, index) => index >= this.items.length && item.id === id);
        if (nextIndex < 0) return false;
        this.append(next[nextIndex]!, nextIndex);
        continue;
      }
      const nextItem = next[location.absoluteIndex];
      if (!nextItem || nextItem.id !== id || groupKey(nextItem) !== this.groups[location.groupIndex]?.id) return false;
      const group = this.groups[location.groupIndex]!;
      const updatedItems = [...group.items];
      updatedItems[location.itemIndex] = nextItem;
      this.groups[location.groupIndex] = { ...group, items: updatedItems };
    }
    return this.locations.size === next.length;
  }

  private append(item: TranscriptItem, absoluteIndex: number) {
    const key = groupKey(item);
    const lastIndex = this.groups.length - 1;
    if (lastIndex >= 0 && this.groups[lastIndex]!.id === key) {
      const group = this.groups[lastIndex]!;
      const items = [...group.items, item];
      this.groups[lastIndex] = { ...group, items };
      this.locations.set(item.id, { groupIndex: lastIndex, itemIndex: items.length - 1, absoluteIndex });
    } else {
      this.groups.push({ id: key, items: [item] });
      this.locations.set(item.id, { groupIndex: this.groups.length - 1, itemIndex: 0, absoluteIndex });
    }
    if (absoluteIndex !== this.locations.size - 1) this.rebuild(this.items);
  }

  private rebuild(items: TranscriptItem[]) {
    this.items = items;
    this.groups = [];
    this.locations.clear();
    for (let absoluteIndex = 0; absoluteIndex < items.length; absoluteIndex += 1) {
      const item = items[absoluteIndex]!;
      const key = groupKey(item);
      const lastIndex = this.groups.length - 1;
      if (lastIndex >= 0 && this.groups[lastIndex]!.id === key) {
        const group = this.groups[lastIndex]!;
        group.items.push(item);
        this.locations.set(item.id, { groupIndex: lastIndex, itemIndex: group.items.length - 1, absoluteIndex });
      } else {
        this.groups.push({ id: key, items: [item] });
        this.locations.set(item.id, { groupIndex: this.groups.length - 1, itemIndex: 0, absoluteIndex });
      }
    }
    this.fullRebuildCount += 1;
  }
}

function groupKey(item: TranscriptItem) {
  return item.turnId ? `turn.${item.turnId}` : `item.${item.id}`;
}

export function windowTranscriptGroups(items: TranscriptItem[], limit: number) {
  return new TranscriptGroupIndex().window(items, limit);
}
