import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

export type SidebarOrganization = "byProject" | "singleList";
export type SidebarSort = "priority" | "recent";

export interface SidebarPreferences {
  organization: SidebarOrganization;
  sort: SidebarSort;
}

export interface ClientPreferences {
  sidebar: SidebarPreferences;
}

const defaults: ClientPreferences = {
  sidebar: { organization: "byProject", sort: "priority" },
};

export class ClientPreferencesStore {
  private pendingWrite = Promise.resolve();

  private constructor(
    private readonly filePath: string,
    private value: ClientPreferences,
  ) {}

  static async create(filePath = path.join(process.env.RELAY_HOME?.trim() || path.join(process.env.USERPROFILE || process.env.HOME || ".", ".relay"), "client-preferences.json")): Promise<ClientPreferencesStore> {
    let value = defaults;
    try {
      const parsed = JSON.parse(await readFile(filePath, "utf8")) as unknown;
      value = normalize(parsed);
    } catch {}
    return new ClientPreferencesStore(filePath, value);
  }

  get(): ClientPreferences {
    return clone(this.value);
  }

  async update(patch: unknown): Promise<ClientPreferences> {
    const object = isRecord(patch) ? patch : {};
    const sidebar = isRecord(object.sidebar) ? object.sidebar : {};
    this.value = normalize({
      ...this.value,
      sidebar: { ...this.value.sidebar, ...sidebar },
    });
    const next = this.get();
    this.pendingWrite = this.pendingWrite
      .catch(() => {})
      .then(() => this.persist(next));
    await this.pendingWrite;
    return clone(next);
  }

  private async persist(value: ClientPreferences): Promise<void> {
    await mkdir(path.dirname(this.filePath), { recursive: true });
    const temporary = `${this.filePath}.tmp.${process.pid}`;
    await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    await rename(temporary, this.filePath);
  }
}

function normalize(value: unknown): ClientPreferences {
  const object = isRecord(value) ? value : {};
  const sidebar = isRecord(object.sidebar) ? object.sidebar : {};
  return {
    sidebar: {
      organization: sidebar.organization === "singleList" ? "singleList" : "byProject",
      sort: sidebar.sort === "recent" ? "recent" : "priority",
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function clone(value: ClientPreferences): ClientPreferences {
  return { sidebar: { ...value.sidebar } };
}
