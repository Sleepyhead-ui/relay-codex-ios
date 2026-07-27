import { beforeEach, describe, expect, it, vi } from "vitest";
import { BridgeRpc, isDurableRpc } from "./bridge";

describe("durable Bridge RPC", () => {
  const send = vi.fn(async (_message: any) => true);
  const storage = {
    value: "",
    getItem: vi.fn(() => storage.value || null),
    setItem: vi.fn((_key: string, value: string) => { storage.value = value; }),
  };

  beforeEach(() => {
    send.mockClear();
    storage.value = "";
    Object.defineProperty(globalThis, "window", {
      configurable: true,
      value: { relayDesktop: { send } },
    });
  });

  it("recognizes only mutating requests with a semantic message id", () => {
    expect(isDurableRpc("turn/start", { clientUserMessageId: "message.1" })).toBe(true);
    expect(isDurableRpc("turn/steer", { clientUserMessageId: "message.1" })).toBe(true);
    expect(isDurableRpc("turn/start", {})).toBe(false);
    expect(isDurableRpc("thread/list", { clientUserMessageId: "message.1" })).toBe(false);
  });

  it("retains and resends a durable request after reconnect", async () => {
    const rpc = new BridgeRpc(storage);
    rpc.setDeliveryScope("ws://host:8765", "profile.1");
    void rpc.rpc("turn/start", { threadId: "thread.1", clientUserMessageId: "message.1" }, 60_000);
    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    rpc.failAll("disconnected");
    expect(rpc.pendingDurableCount).toBe(1);
    await rpc.resumeDurable();
    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls[1]?.[0]).toMatchObject({ method: "turn/start", params: { clientUserMessageId: "message.1" } });
  });

  it("restores a durable request after a renderer restart", async () => {
    const first = new BridgeRpc(storage);
    first.setDeliveryScope("ws://host:8765", "profile.1");
    void first.rpc("turn/start", { threadId: "thread.1", clientUserMessageId: "message.1" }, 60_000);
    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(1));

    send.mockClear();
    const restored = new BridgeRpc(storage);
    restored.setDeliveryScope("ws://host:8765", "profile.1");
    const resuming = restored.resumeDurable();
    await respondToLatest(restored, "relay/delivery/status", { status: "unknown" });
    await respondToLatest(restored, "relay/thread/runtime", { isRunning: false });
    await resuming;
    expect(send.mock.calls.at(-1)?.[0]).toMatchObject({ method: "turn/start", params: { clientUserMessageId: "message.1" } });
  });

  it("does not resend a request into a different Codex profile", async () => {
    const first = new BridgeRpc(storage);
    first.setDeliveryScope("ws://host:8765", "profile.1");
    void first.rpc("turn/start", { threadId: "thread.1", clientUserMessageId: "message.1" }, 60_000);
    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(1));

    send.mockClear();
    const restored = new BridgeRpc(storage);
    restored.setDeliveryScope("ws://host:8765", "profile.2");
    await restored.resumeDurable();
    expect(send).not.toHaveBeenCalled();
  });

  it("keeps an uncertain Bridge result in the outbox for later reconciliation", async () => {
    const rpc = new BridgeRpc(storage);
    rpc.setDeliveryScope("ws://host:8765", "profile.1");
    const request = rpc.rpc("turn/start", { threadId: "thread.1", clientUserMessageId: "message.1" }, 60_000);
    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    const id = send.mock.calls[0]?.[0].id;
    rpc.handle({ type: "rpcResult", id, deliveryUncertain: true, error: { message: "Codex restarted" } });
    await expect(request).rejects.toThrow("Codex restarted");

    send.mockClear();
    const restored = new BridgeRpc(storage);
    restored.setDeliveryScope("ws://host:8765", "profile.1");
    const resuming = restored.resumeDurable();
    await respondToLatest(restored, "relay/delivery/status", { status: "completed", turnId: "turn.1" });
    await resuming;
    expect(send).toHaveBeenCalledTimes(1);
  });

  async function respondToLatest(rpc: BridgeRpc, method: string, result: Record<string, unknown>) {
    await vi.waitFor(() => expect(send.mock.calls.some((call) => call[0].method === method)).toBe(true));
    const request = [...send.mock.calls].reverse().find((call) => call[0].method === method)?.[0];
    rpc.handle({ type: "rpcResult", id: request.id, result });
  }
});
