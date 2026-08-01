export interface SessionSubscriptionLease {
  subscriptionId?: string;
  stop: () => void;
}

export class SessionSubscriptionRegistry<Socket extends object> {
  private readonly sockets = new WeakMap<Socket, Map<string, SessionSubscriptionLease>>();

  open(socket: Socket): void {
    this.close(socket);
    this.sockets.set(socket, new Map());
  }

  replace(socket: Socket, threadId: string, lease: SessionSubscriptionLease): void {
    const subscriptions = this.sockets.get(socket);
    if (!subscriptions) throw new Error("The socket subscription registry is not open.");
    subscriptions.get(threadId)?.stop();
    subscriptions.set(threadId, lease);
  }

  unsubscribe(socket: Socket, threadId: string, subscriptionId?: string): boolean {
    const subscriptions = this.sockets.get(socket);
    const current = subscriptions?.get(threadId);
    if (!current || (subscriptionId && current.subscriptionId !== subscriptionId)) return false;
    current.stop();
    subscriptions?.delete(threadId);
    return true;
  }

  close(socket: Socket): void {
    const subscriptions = this.sockets.get(socket);
    if (!subscriptions) return;
    for (const subscription of subscriptions.values()) subscription.stop();
    this.sockets.delete(socket);
  }
}
