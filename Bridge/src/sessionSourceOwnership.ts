export class SessionSourceOwnership {
  private readonly turns = new Map<string, string | null>();

  begin(threadId: unknown): void {
    if (typeof threadId === "string" && threadId) this.turns.set(threadId, null);
  }

  bind(threadId: unknown, turnId: unknown): void {
    if (typeof threadId !== "string" || !threadId || typeof turnId !== "string" || !turnId) return;
    this.turns.set(threadId, turnId);
  }

  isRelayOwned(threadId: string, turnId?: string): boolean {
    if (!this.turns.has(threadId)) return false;
    const expected = this.turns.get(threadId);
    return expected === null || !turnId || expected === turnId;
  }

  finish(threadId: unknown, turnId?: unknown): boolean {
    if (typeof threadId !== "string" || !threadId || !this.turns.has(threadId)) return false;
    const expected = this.turns.get(threadId);
    if (expected && typeof turnId === "string" && turnId && expected !== turnId) return false;
    this.turns.delete(threadId);
    return true;
  }

  clear(): void { this.turns.clear(); }
}
