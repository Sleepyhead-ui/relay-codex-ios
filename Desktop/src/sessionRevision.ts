export class SessionRevisionTracker {
  private revisions = new Map<string, number>();

  reset(threadId: string, revision: number) {
    this.revisions.set(threadId, normalizedRevision(revision));
  }

  acceptPatch(threadId: string, baseRevision: number, revision: number) {
    const current = this.revisions.get(threadId);
    if (current === undefined || current !== normalizedRevision(baseRevision)) return false;
    this.revisions.set(threadId, normalizedRevision(revision));
    return true;
  }

  revision(threadId: string) { return this.revisions.get(threadId); }
  clear() { this.revisions.clear(); }
}

function normalizedRevision(value: number) {
  return Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : 0;
}
