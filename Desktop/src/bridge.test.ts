import { beforeEach, describe, expect, it, vi } from "vitest";
import { BridgeRpc, isDurableRpc } from "./bridge";

describe("durable Bridge RPC", () => {
  const send = vi.fn(async (_message: any) => true);

  beforeEach(() => {
    send.mockClear();
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
    const rpc = new BridgeRpc();
    void rpc.rpc("turn/start", { threadId: "thread.1", clientUserMessageId: "message.1" }, 60_000);
    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    rpc.failAll("disconnected");
    expect(rpc.pendingDurableCount).toBe(1);
    await rpc.resumeDurable();
    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls[1]?.[0]).toMatchObject({ method: "turn/start", params: { clientUserMessageId: "message.1" } });
  });
});
