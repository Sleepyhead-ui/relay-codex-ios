type Pending = {
  resolve: (value: any) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
};

export class BridgeRpc {
  private pending = new Map<string, Pending>();
  private messageListeners = new Set<(message: any) => void>();

  handle(message: any) {
    if (message?.type === "rpcResult" && typeof message.id === "string") {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timeout);
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
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} 请求超时`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timeout });
    });
    try {
      await window.relayDesktop.send({ type: "rpc", id, method, params });
    } catch (error) {
      const pending = this.pending.get(id);
      if (pending) clearTimeout(pending.timeout);
      this.pending.delete(id);
      throw error;
    }
    return promise;
  }

  async respond(id: string | number, result: Record<string, unknown>) {
    await window.relayDesktop.send({ type: "serverResponse", id, result });
  }

  failAll(message: string) {
    for (const request of this.pending.values()) {
      clearTimeout(request.timeout);
      request.reject(new Error(message));
    }
    this.pending.clear();
  }
}
