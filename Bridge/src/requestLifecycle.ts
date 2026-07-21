export interface PendingRequest<TSocket, TParams> {
  socket: TSocket;
  clientId: string;
  method: string;
  params: TParams;
}

interface StoredRequest<TSocket, TParams> {
  request: PendingRequest<TSocket, TParams>;
  timeout: NodeJS.Timeout;
}

export class RequestLifecycle<TSocket, TParams> {
  private readonly requests = new Map<string, StoredRequest<TSocket, TParams>>();

  constructor(
    private readonly onTimeout: (bridgeId: string, request: PendingRequest<TSocket, TParams>) => void,
  ) {}

  add(bridgeId: string, request: PendingRequest<TSocket, TParams>, timeoutMs: number): void {
    this.delete(bridgeId);
    const timeout = setTimeout(() => {
      const expired = this.take(bridgeId);
      if (expired) this.onTimeout(bridgeId, expired);
    }, timeoutMs);
    timeout.unref();
    this.requests.set(bridgeId, { request, timeout });
  }

  take(bridgeId: string): PendingRequest<TSocket, TParams> | undefined {
    const stored = this.requests.get(bridgeId);
    if (!stored) return undefined;
    clearTimeout(stored.timeout);
    this.requests.delete(bridgeId);
    return stored.request;
  }

  cancelClient(socket: TSocket, clientId: string): [string, PendingRequest<TSocket, TParams>] | undefined {
    for (const [bridgeId, stored] of this.requests) {
      if (stored.request.socket === socket && stored.request.clientId === clientId) {
        return [bridgeId, this.take(bridgeId)!];
      }
    }
    return undefined;
  }

  removeSocket(socket: TSocket): Array<[string, PendingRequest<TSocket, TParams>]> {
    const removed: Array<[string, PendingRequest<TSocket, TParams>]> = [];
    for (const [bridgeId, stored] of this.requests) {
      if (stored.request.socket !== socket) continue;
      const request = this.take(bridgeId);
      if (request) removed.push([bridgeId, request]);
    }
    return removed;
  }

  clear(): Array<[string, PendingRequest<TSocket, TParams>]> {
    const removed: Array<[string, PendingRequest<TSocket, TParams>]> = [];
    for (const bridgeId of [...this.requests.keys()]) {
      const request = this.take(bridgeId);
      if (request) removed.push([bridgeId, request]);
    }
    return removed;
  }

  delete(bridgeId: string): boolean {
    return this.take(bridgeId) !== undefined;
  }

  get size(): number {
    return this.requests.size;
  }
}
