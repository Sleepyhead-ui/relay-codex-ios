import { describe, expect, it } from "vitest";
import { DurableRpcOutbox, type DurableStorage } from "./durableOutbox";

class MemoryStorage implements DurableStorage {
  values = new Map<string, string>();
  getItem(key: string) { return this.values.get(key) ?? null; }
  setItem(key: string, value: string) { this.values.set(key, value); }
}

describe("durable RPC outbox", () => {
  it("survives a renderer restart and isolates records by endpoint and profile", () => {
    const storage = new MemoryStorage();
    const first = new DurableRpcOutbox(storage, () => 1_000);
    first.put({
      id: "request.1",
      endpoint: "ws://host-a:8765",
      profileId: "profile-a",
      method: "turn/start",
      params: { threadId: "thread.1", clientUserMessageId: "message.1" },
      timeoutMs: 120_000,
      createdAt: 1_000,
    });

    const restored = new DurableRpcOutbox(storage, () => 1_001);
    expect(restored.scoped("ws://host-a:8765", "profile-a").map((record) => record.id)).toEqual(["request.1"]);
    expect(restored.scoped("ws://host-b:8765", "profile-a")).toEqual([]);
    expect(restored.scoped("ws://host-a:8765", "profile-b")).toEqual([]);
  });

  it("removes completed deliveries from persistent storage", () => {
    const storage = new MemoryStorage();
    const outbox = new DurableRpcOutbox(storage, () => 1_000);
    outbox.put({
      id: "request.1",
      endpoint: "ws://host:8765",
      profileId: "profile",
      method: "turn/start",
      params: {},
      timeoutMs: 120_000,
      createdAt: 1_000,
    });
    outbox.remove("request.1");

    expect(new DurableRpcOutbox(storage, () => 1_001).scoped("ws://host:8765", "profile")).toEqual([]);
  });
});
