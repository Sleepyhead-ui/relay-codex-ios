export class ClientPresenceRegistry<Client extends object> {
  private readonly clients = new Map<Client, { active: boolean; revision: number }>();
  private activeCount = 0;

  open(client: Client): void {
    this.close(client);
    this.clients.set(client, { active: false, revision: -1 });
  }

  update(client: Client, active: boolean, revision: number): boolean {
    const current = this.clients.get(client);
    if (!current || !Number.isSafeInteger(revision) || revision < current.revision) return false;
    if (current.active !== active) this.activeCount += active ? 1 : -1;
    this.clients.set(client, { active, revision });
    return true;
  }

  close(client: Client): void {
    const current = this.clients.get(client);
    if (current?.active) this.activeCount -= 1;
    this.clients.delete(client);
  }

  get hasActiveClient(): boolean {
    return this.activeCount > 0;
  }
}
