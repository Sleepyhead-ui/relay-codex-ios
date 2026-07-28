import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import type { JsonObject } from "./protocol.js";
import { isObject } from "./protocol.js";

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
  params: JsonObject;
  state: "pending" | "completed";
  bridgeId?: string;
  forwardedAt?: number;
  response?: DeliveryResponse;
  waiters: DeliveryWaiter<TSocket>[];
  updatedAt: number;
}

export interface RecoverableDelivery {
  key: string;
  profileId: string;
  method: string;
  clientUserMessageId: string;
  threadId: string;
  params: JsonObject;
  forwardedAt?: number;
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
  private persistChain: Promise<void> = Promise.resolve();

  private constructor(
    private readonly storagePath: string | undefined,
    private readonly limit = 500,
    private readonly completedTtlMs = 30 * 60_000,
    private readonly now: () => number = Date.now,
  ) {}

  static async create<TSocket>(
    storagePath: string | null | undefined = path.join(homedir(), ".relay", "delivery-registry.json"),
    limit = 500,
    completedTtlMs = 30 * 60_000,
    now: () => number = Date.now,
  ): Promise<DeliveryRegistry<TSocket>> {
    const registry = new DeliveryRegistry<TSocket>(storagePath ?? undefined, limit, completedTtlMs, now);
    await registry.load();
    return registry;
  }

  async register(
    profileId: string,
    method: string,
    params: JsonObject,
    waiter: DeliveryWaiter<TSocket>,
  ): Promise<DeliveryRegistration<TSocket> | undefined> {
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
      params: cloneObject(params),
      state: "pending",
      waiters: [waiter],
      updatedAt: this.now(),
    };
    this.records.set(key, record);
    this.prune();
    await this.persist();
    return { kind: "new", key };
  }

  async bindBridgeRequest(key: string, bridgeId: string): Promise<void> {
    const record = this.records.get(key);
    if (!record || record.state !== "pending") return;
    record.bridgeId = bridgeId;
    record.forwardedAt = this.now();
    record.updatedAt = this.now();
    await this.persist();
  }

  async complete(key: string, response: DeliveryResponse): Promise<DeliveryWaiter<TSocket>[]> {
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
    await this.persist();
    return waiters;
  }

  async abandon(key: string): Promise<DeliveryWaiter<TSocket>[]> {
    const record = this.records.get(key);
    if (!record || record.state !== "pending") return [];
    this.records.delete(key);
    await this.persist();
    return record.waiters;
  }

  async suspend(key: string): Promise<DeliveryWaiter<TSocket>[]> {
    const record = this.records.get(key);
    if (!record || record.state !== "pending") return [];
    delete record.bridgeId;
    record.updatedAt = this.now();
    const waiters = record.waiters;
    record.waiters = [];
    await this.persist();
    return waiters;
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

  pendingCountFor(profileId: string): number {
    let count = 0;
    for (const record of this.records.values()) {
      if (record.state === "pending" && record.profileId === profileId) count += 1;
    }
    return count;
  }

  recoverable(profileId?: string): RecoverableDelivery[] {
    this.prune();
    return [...this.records.values()].flatMap((record) => {
      if (record.state !== "pending" || (profileId && record.profileId !== profileId)) return [];
      return [{
        key: record.key,
        profileId: record.profileId,
        method: record.method,
        clientUserMessageId: record.clientUserMessageId,
        threadId: record.threadId,
        params: cloneObject(record.params),
        ...(record.forwardedAt ? { forwardedAt: record.forwardedAt } : {}),
        updatedAt: record.updatedAt,
      }];
    });
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

  private async load(): Promise<void> {
    if (!this.storagePath) return;
    try {
      const parsed: unknown = JSON.parse(await readFile(this.storagePath, "utf8"));
      if (!Array.isArray(parsed)) return;
      for (const value of parsed) {
        if (!isObject(value) || typeof value.profileId !== "string" || typeof value.method !== "string"
            || typeof value.clientUserMessageId !== "string" || typeof value.threadId !== "string"
            || !isObject(value.params) || (value.state !== "pending" && value.state !== "completed")) continue;
        const key = deliveryKey(value.profileId, value.clientUserMessageId);
        const response = isObject(value.response) ? value.response as DeliveryResponse : undefined;
        this.records.set(key, {
          key,
          profileId: value.profileId,
          method: value.method,
          clientUserMessageId: value.clientUserMessageId,
          threadId: value.threadId,
          params: cloneObject(value.params),
          state: value.state,
          ...(typeof value.forwardedAt === "number" ? { forwardedAt: value.forwardedAt } : {}),
          ...(response ? { response } : {}),
          waiters: [],
          updatedAt: typeof value.updatedAt === "number" ? value.updatedAt : this.now(),
        });
      }
      this.prune();
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }

  private async persist(): Promise<void> {
    if (!this.storagePath) return;
    const snapshot = `${JSON.stringify([...this.records.values()].map((record) => ({
      profileId: record.profileId,
      method: record.method,
      clientUserMessageId: record.clientUserMessageId,
      threadId: record.threadId,
      params: record.params,
      state: record.state,
      ...(record.forwardedAt ? { forwardedAt: record.forwardedAt } : {}),
      ...(record.response ? { response: record.response } : {}),
      updatedAt: record.updatedAt,
    })), null, 2)}\n`;
    const operation = this.persistChain.then(async () => {
      await mkdir(path.dirname(this.storagePath!), { recursive: true });
      const temporary = `${this.storagePath}.${process.pid}.${randomUUID()}.tmp`;
      await writeFile(temporary, snapshot, { encoding: "utf8", mode: 0o600 });
      await rename(temporary, this.storagePath!);
    });
    this.persistChain = operation.catch(() => {});
    await operation;
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

function cloneObject(value: JsonObject): JsonObject {
  return JSON.parse(JSON.stringify(value)) as JsonObject;
}
