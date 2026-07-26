type Pending = {
  resolve: (value: any) => void;
  reject: (error: Error) => void;
  timeout?: ReturnType<typeof setTimeout>;
  id: string;
  method: string;
  params: Record<string, unknown>;
  timeoutMs: number;
  durable: boolean;
};

export class BridgeRpc {
  private pending = new Map<string, Pending>();
  private messageListeners = new Set<(message: any) => void>();

  handle(message: any) {
    if (message?.type === "rpcResult" && typeof message.id === "string") {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      if (pending.timeout) clearTimeout(pending.timeout);
      this.pending.delete(message.id);
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
      const pending: Pending = { resolve, reject, id, method, params, timeoutMs, durable };
      this.pending.set(id, pending);
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
    for (const request of this.pending.values()) {
      if (!request.durable || request.timeout) continue;
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
      void window.relayDesktop.send({ type: "rpcCancel", id: request.id }).catch(() => {});
      request.reject(new Error(`${request.method} 请求超时`));
    }, request.timeoutMs);
  }
}

export function isDurableRpc(method: string, params: Record<string, unknown>) {
  return (method === "turn/start" || method === "turn/steer")
    && typeof params.clientUserMessageId === "string"
    && params.clientUserMessageId.length > 0;
}
