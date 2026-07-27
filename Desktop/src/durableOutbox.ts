export interface DurableStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface DurableRpcRecord {
  id: string;
  endpoint: string;
  profileId: string;
  method: string;
  params: Record<string, unknown>;
  timeoutMs: number;
  createdAt: number;
}

const storageKey = "relay.desktop.durableOutbox.v1";
const maximumAgeMs = 7 * 24 * 60 * 60_000;
const maximumRecords = 200;

export class DurableRpcOutbox {
  private records = new Map<string, DurableRpcRecord>();

  constructor(private readonly storage?: DurableStorage, private readonly now: () => number = Date.now) {
    this.load();
  }

  put(record: DurableRpcRecord) {
    this.records.set(record.id, record);
    this.persist();
  }

  remove(id: string) {
    if (!this.records.delete(id)) return;
    this.persist();
  }

  scoped(endpoint: string, profileId: string) {
    this.prune();
    return [...this.records.values()]
      .filter((record) => record.endpoint === endpoint && record.profileId === profileId)
      .sort((left, right) => left.createdAt - right.createdAt);
  }

  private load() {
    if (!this.storage) return;
    try {
      const decoded = JSON.parse(this.storage.getItem(storageKey) || "[]");
      if (!Array.isArray(decoded)) return;
      for (const value of decoded) {
        if (!isRecord(value)) continue;
        this.records.set(value.id, value);
      }
      this.prune();
    } catch {
      this.records.clear();
    }
  }

  private prune() {
    const oldest = this.now() - maximumAgeMs;
    const retained = [...this.records.values()]
      .filter((record) => record.createdAt >= oldest)
      .sort((left, right) => right.createdAt - left.createdAt)
      .slice(0, maximumRecords);
    this.records = new Map(retained.map((record) => [record.id, record]));
  }

  private persist() {
    if (!this.storage) return;
    this.prune();
    this.storage.setItem(storageKey, JSON.stringify([...this.records.values()]));
  }
}

function isRecord(value: unknown): value is DurableRpcRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<DurableRpcRecord>;
  return typeof record.id === "string"
    && typeof record.endpoint === "string"
    && typeof record.profileId === "string"
    && typeof record.method === "string"
    && Boolean(record.params && typeof record.params === "object")
    && typeof record.timeoutMs === "number"
    && typeof record.createdAt === "number";
}
