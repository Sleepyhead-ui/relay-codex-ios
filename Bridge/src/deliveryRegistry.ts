import type { JsonObject } from "./protocol.js";

export interface DeliveryWaiter<TSocket> {
  socket: TSocket;
  clientId: string;
}

export interface DeliveryResponse {
  result?: unknown;
  error?: unknown;
}

interface DeliveryRecord<TSocket> {
  key: string;
  profileId: string;
  method: string;
  clientUserMessageId: string;
  threadId: string;
  state: "pending" | "completed";
  bridgeId?: string;
  response?: DeliveryResponse;
  waiters: DeliveryWaiter<TSocket>[];
  updatedAt: number;
}

export type DeliveryRegistration<TSocket> =
  | { kind: "new"; key: string }
  | { kind: "pending"; key: string }
  | { kind: "completed"; key: string; response: DeliveryResponse }
  | { kind: "conflict"; key: string };

export interface DeliveryStatus extends JsonObject {
  known: boolean;
  status: "unknown" | "pending" | "completed";
  method?: string;
  threadId?: string;
  clientUserMessageId?: string;
  result?: unknown;
  error?: unknown;
  updatedAt: number;
}

export class DeliveryRegistry<TSocket> {
  private readonly records = new Map<string, DeliveryRecord<TSocket>>();

  constructor(
    private readonly limit = 500,
    private readonly completedTtlMs = 30 * 60_000,
    private readonly now: () => number = Date.now,
  ) {}

  register(
    profileId: string,
    method: string,
    params: JsonObject,
    waiter: DeliveryWaiter<TSocket>,
  ): DeliveryRegistration<TSocket> | undefined {
    const clientUserMessageId = stringValue(params.clientUserMessageId);
    const threadId = stringValue(params.threadId);
    if (!clientUserMessageId || !threadId || !isDurableDeliveryMethod(method)) return undefined;
    this.prune();
    const key = deliveryKey(profileId, clientUserMessageId);
    const existing = this.records.get(key);
    if (existing) {
      if (existing.method !== method || existing.threadId !== threadId) return { kind: "conflict", key };
      existing.updatedAt = this.now();
      this.touch(key, existing);
      if (existing.state === "completed" && existing.response) {
        return { kind: "completed", key, response: existing.response };
      }
      this.addWaiter(existing, waiter);
      return { kind: "pending", key };
    }
    const record: DeliveryRecord<TSocket> = {
      key,
      profileId,
      method,
      clientUserMessageId,
      threadId,
      state: "pending",
      waiters: [waiter],
      updatedAt: this.now(),
    };
    this.records.set(key, record);
    this.prune();
    return { kind: "new", key };
  }

  bindBridgeRequest(key: string, bridgeId: string): void {
    const record = this.records.get(key);
    if (!record || record.state !== "pending") return;
    record.bridgeId = bridgeId;
    record.updatedAt = this.now();
  }

  complete(key: string, response: DeliveryResponse): DeliveryWaiter<TSocket>[] {
    const record = this.records.get(key);
    if (!record) return [];
    record.state = "completed";
    record.response = response;
    delete record.bridgeId;
    record.updatedAt = this.now();
    const waiters = record.waiters;
    record.waiters = [];
    this.touch(key, record);
    this.prune();
    return waiters;
  }

  abandon(key: string): DeliveryWaiter<TSocket>[] {
    const record = this.records.get(key);
    if (!record || record.state !== "pending") return [];
    this.records.delete(key);
    return record.waiters;
  }

  removeWaiter(socket: TSocket, clientId?: string): void {
    for (const record of this.records.values()) {
      record.waiters = record.waiters.filter((waiter) => waiter.socket !== socket || (clientId !== undefined && waiter.clientId !== clientId));
    }
  }

  status(profileId: string, clientUserMessageId: unknown): DeliveryStatus {
    const id = stringValue(clientUserMessageId);
    if (!id) return { known: false, status: "unknown", updatedAt: this.now() / 1000 };
    this.prune();
    const record = this.records.get(deliveryKey(profileId, id));
    if (!record) return { known: false, status: "unknown", clientUserMessageId: id, updatedAt: this.now() / 1000 };
    return {
      known: true,
      status: record.state,
      method: record.method,
      threadId: record.threadId,
      clientUserMessageId: record.clientUserMessageId,
      ...(record.response?.result !== undefined ? { result: record.response.result } : {}),
      ...(record.response?.error !== undefined ? { error: record.response.error } : {}),
      updatedAt: record.updatedAt / 1000,
    };
  }

  get pendingCount(): number {
    let count = 0;
    for (const record of this.records.values()) if (record.state === "pending") count += 1;
    return count;
  }

  private addWaiter(record: DeliveryRecord<TSocket>, waiter: DeliveryWaiter<TSocket>): void {
    if (record.waiters.some((candidate) => candidate.socket === waiter.socket && candidate.clientId === waiter.clientId)) return;
    record.waiters.push(waiter);
  }

  private touch(key: string, record: DeliveryRecord<TSocket>): void {
    this.records.delete(key);
    this.records.set(key, record);
  }

  private prune(): void {
    const oldestAllowed = this.now() - this.completedTtlMs;
    for (const [key, record] of this.records) {
      if (record.state === "completed" && record.updatedAt < oldestAllowed) this.records.delete(key);
    }
    if (this.records.size <= this.limit) return;
    for (const [key, record] of this.records) {
      if (this.records.size <= this.limit) break;
      if (record.state === "completed") this.records.delete(key);
    }
  }
}

export function isDurableDeliveryMethod(method: string): boolean {
  return method === "turn/start" || method === "turn/steer";
}

function deliveryKey(profileId: string, clientUserMessageId: string): string {
  return `${profileId}\u0000${clientUserMessageId}`;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value ? value : undefined;
}
