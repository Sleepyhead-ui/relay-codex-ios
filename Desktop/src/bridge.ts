import { DurableRpcOutbox, type DurableStorage } from "./durableOutbox";

type Pending = {
  resolve: (value: any) => void;
  reject: (error: Error) => void;
  timeout?: ReturnType<typeof setTimeout>;
  recoveryTimer?: ReturnType<typeof setTimeout>;
  id: string;
  method: string;
  params: Record<string, unknown>;
  timeoutMs: number;
  durable: boolean;
  endpoint?: string;
  profileId?: string;
  restored?: boolean;
};

export class BridgeRpc {
  private pending = new Map<string, Pending>();
  private messageListeners = new Set<(message: any) => void>();
  private readonly outbox: DurableRpcOutbox;
  private endpoint = "";
  private profileId = "";

  constructor(storage: DurableStorage | undefined = globalThis.localStorage) {
    this.outbox = new DurableRpcOutbox(storage);
  }

  setDeliveryScope(endpoint: string, profileId: string) {
    this.endpoint = endpoint;
    this.profileId = profileId;
  }

  handle(message: any) {
    if (message?.type === "rpcResult" && typeof message.id === "string") {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      if (pending.timeout) clearTimeout(pending.timeout);
      if (pending.recoveryTimer) clearTimeout(pending.recoveryTimer);
      this.pending.delete(message.id);
      if (pending.durable && message.deliveryUncertain !== true) this.outbox.remove(message.id);
      if (message.error) pending.reject(new Error(message.error.message || "Bridge 请求失败"));
      else pending.resolve(message.result ?? {});
      return;
    }
    for (const listener of this.messageListeners) listener(message);
  }

  onMessage(listener: (message: any) => void) {
    this.messageListeners.add(listener);
    return () => this.messageListeners.delete(listener);
  }

  async rpc(method: string, params: Record<string, unknown> = {}, timeoutMs = 45_000) {
    const id = crypto.randomUUID();
    const promise = new Promise<any>((resolve, reject) => {
      const durable = isDurableRpc(method, params);
      const pending: Pending = {
        resolve,
        reject,
        id,
        method,
        params,
        timeoutMs,
        durable,
        ...(durable ? { endpoint: this.endpoint, profileId: this.profileId } : {}),
      };
      this.pending.set(id, pending);
      if (durable) this.persist(pending);
      this.armTimeout(pending);
    });
    try {
      await window.relayDesktop.send({ type: "rpc", id, method, params });
    } catch (error) {
      const pending = this.pending.get(id);
      if (pending?.timeout) clearTimeout(pending.timeout);
      this.pending.delete(id);
      throw error;
    }
    return promise;
  }

  async respond(id: string | number, result: Record<string, unknown>) {
    await window.relayDesktop.send({ type: "serverResponse", id, result });
  }

  failAll(message: string) {
    for (const [id, request] of this.pending) {
      if (request.timeout) clearTimeout(request.timeout);
      request.timeout = undefined;
      if (request.durable) continue;
      request.reject(new Error(message));
      this.pending.delete(id);
    }
  }

  async resumeDurable() {
    this.restoreDurable();
    for (const request of this.pending.values()) {
      if (!request.durable || request.timeout || request.recoveryTimer
        || request.endpoint !== this.endpoint || request.profileId !== this.profileId) continue;
      if (request.restored) {
        const action = await this.recoveryAction(request);
        if (action === "complete" || action === "discard" || action === "wait") continue;
        request.restored = false;
      }
      this.armTimeout(request);
      try {
        await window.relayDesktop.send({
          type: "rpc",
          id: request.id,
          method: request.method,
          params: request.params,
        });
      } catch (error) {
        if (request.timeout) clearTimeout(request.timeout);
        request.timeout = undefined;
        throw error;
      }
    }
  }

  get pendingDurableCount() {
    let count = 0;
    for (const request of this.pending.values()) if (request.durable) count += 1;
    return count;
  }

  private armTimeout(request: Pending) {
    if (request.timeout) clearTimeout(request.timeout);
    request.timeout = setTimeout(() => {
      this.pending.delete(request.id);
      if (!request.durable) this.outbox.remove(request.id);
      void window.relayDesktop.send({ type: "rpcCancel", id: request.id }).catch(() => {});
      request.reject(new Error(`${request.method} 请求超时`));
    }, request.timeoutMs);
  }

  private persist(request: Pending) {
    this.outbox.put({
      id: request.id,
      endpoint: request.endpoint ?? this.endpoint,
      profileId: request.profileId ?? this.profileId,
      method: request.method,
      params: request.params,
      timeoutMs: request.timeoutMs,
      createdAt: Date.now(),
    });
  }

  private restoreDurable() {
    if (!this.endpoint || !this.profileId) return;
    for (const record of this.outbox.scoped(this.endpoint, this.profileId)) {
      if (this.pending.has(record.id)) continue;
      this.pending.set(record.id, {
        id: record.id,
        method: record.method,
        params: record.params,
        timeoutMs: record.timeoutMs,
        durable: true,
        endpoint: record.endpoint,
        profileId: record.profileId,
        restored: true,
        resolve: () => {},
        reject: () => {},
      });
    }
  }

  private async recoveryAction(request: Pending): Promise<"send" | "complete" | "discard" | "wait"> {
    const threadId = typeof request.params.threadId === "string" ? request.params.threadId : "";
    const clientUserMessageId = typeof request.params.clientUserMessageId === "string" ? request.params.clientUserMessageId : "";
    if (!threadId || !clientUserMessageId) return "discard";
    const status = await this.rpc("relay/delivery/status", { threadId, clientUserMessageId }, 12_000);
    if (status.status === "completed") {
      this.pending.delete(request.id);
      this.outbox.remove(request.id);
      if (status.error) {
        request.reject(new Error(status.error.message || "消息投递失败"));
        return "discard";
      }
      const turnId = status.turnId || status.result?.turn?.id || status.result?.turnId;
      request.resolve(status.result || (request.method === "turn/start"
        ? { ...(turnId ? { turn: { id: turnId }, turnId } : {}) }
        : { ...(turnId ? { turnId } : {}) }));
      return "complete";
    }
    if (status.status === "pending") return "send";

    const runtime = await this.rpc("relay/thread/runtime", { threadId }, 12_000);
    const expectedTurnId = typeof request.params.expectedTurnId === "string" ? request.params.expectedTurnId : undefined;
    if (!expectedTurnId && runtime.isRunning === true) {
      this.scheduleRecovery(request);
      return "wait";
    }
    if (expectedTurnId && (runtime.isRunning !== true
      || (runtime.activeTurnId && runtime.activeTurnId !== expectedTurnId))) {
      this.pending.delete(request.id);
      this.outbox.remove(request.id);
      request.reject(new Error("原任务已经结束，未自动重发这条引导。"));
      return "discard";
    }
    return "send";
  }

  private scheduleRecovery(request: Pending) {
    if (request.recoveryTimer) return;
    request.recoveryTimer = setTimeout(() => {
      request.recoveryTimer = undefined;
      void this.resumeDurable().catch(() => {});
    }, 2_000);
  }
}

export function isDurableRpc(method: string, params: Record<string, unknown>) {
  return (method === "turn/start" || method === "turn/steer")
    && typeof params.clientUserMessageId === "string"
    && params.clientUserMessageId.length > 0;
}
