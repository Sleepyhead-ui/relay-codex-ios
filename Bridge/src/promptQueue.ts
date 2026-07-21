import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import type { JsonObject } from "./protocol.js";
import { isObject } from "./protocol.js";

export interface QueuedPrompt extends JsonObject {
  id: string;
  profileId: string;
  threadId: string;
  clientUserMessageId: string;
  text: string;
  input: unknown[];
  createdAt: number;
  model?: string;
  effort?: string;
  sandboxPolicy?: unknown;
}

export class PromptQueue {
  private items: QueuedPrompt[] = [];
  private persistChain: Promise<void> = Promise.resolve();

  private constructor(private readonly storagePath: string) {}

  static async create(storagePath = path.join(homedir(), ".relay", "prompt-queue.json")): Promise<PromptQueue> {
    const queue = new PromptQueue(storagePath);
    await queue.load();
    return queue;
  }

  list(profileId?: string, threadId?: string): QueuedPrompt[] {
    return this.items.filter((item) => (!profileId || item.profileId === profileId) && (!threadId || item.threadId === threadId)).map((item) => ({ ...item, input: [...item.input] }));
  }

  peek(profileId: string, threadId: string): QueuedPrompt | undefined {
    const item = this.items.find((candidate) => candidate.profileId === profileId && candidate.threadId === threadId);
    return item ? { ...item, input: [...item.input] } : undefined;
  }

  async enqueue(params: JsonObject): Promise<QueuedPrompt> {
    const threadId = requiredString(params, "threadId");
    const profileId = requiredString(params, "profileId");
    if (this.items.filter((item) => item.profileId === profileId && item.threadId === threadId).length >= 20) {
      throw new Error("A task can queue at most 20 follow-up messages.");
    }
    if (this.items.length >= 100) throw new Error("Relay can queue at most 100 follow-up messages.");
    const rawInput = params.input;
    if (!Array.isArray(rawInput) || rawInput.length === 0) throw new Error("Queued prompt input is required.");
    const item: QueuedPrompt = {
      id: randomUUID(),
      profileId,
      threadId,
      clientUserMessageId: typeof params.clientUserMessageId === "string" && params.clientUserMessageId
        ? params.clientUserMessageId
        : randomUUID(),
      text: typeof params.text === "string" ? params.text : "",
      input: rawInput,
      createdAt: Date.now() / 1000,
      ...(typeof params.model === "string" && params.model ? { model: params.model } : {}),
      ...(typeof params.effort === "string" && params.effort ? { effort: params.effort } : {}),
      ...(isObject(params.sandboxPolicy) ? { sandboxPolicy: params.sandboxPolicy } : {}),
    };
    this.items.push(item);
    await this.persist();
    return { ...item, input: [...item.input] };
  }

  async remove(id: string): Promise<boolean> {
    const previousLength = this.items.length;
    this.items = this.items.filter((item) => item.id !== id);
    if (this.items.length === previousLength) return false;
    await this.persist();
    return true;
  }

  private async load(): Promise<void> {
    try {
      const parsed: unknown = JSON.parse(await readFile(this.storagePath, "utf8"));
      if (!Array.isArray(parsed)) return;
      this.items = parsed.flatMap((value) => {
        if (!isObject(value) || typeof value.id !== "string" || typeof value.profileId !== "string" || typeof value.threadId !== "string"
            || typeof value.clientUserMessageId !== "string" || !Array.isArray(value.input)) return [];
        return [{
          id: value.id,
          profileId: value.profileId,
          threadId: value.threadId,
          clientUserMessageId: value.clientUserMessageId,
          text: typeof value.text === "string" ? value.text : "",
          input: value.input,
          createdAt: typeof value.createdAt === "number" ? value.createdAt : 0,
          ...(typeof value.model === "string" ? { model: value.model } : {}),
          ...(typeof value.effort === "string" ? { effort: value.effort } : {}),
          ...(isObject(value.sandboxPolicy) ? { sandboxPolicy: value.sandboxPolicy } : {}),
        }];
      }).slice(0, 100);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }

  private async persist(): Promise<void> {
    const snapshot = `${JSON.stringify(this.items, null, 2)}\n`;
    const operation = this.persistChain.then(async () => {
      await mkdir(path.dirname(this.storagePath), { recursive: true });
      const temporary = `${this.storagePath}.${process.pid}.${randomUUID()}.tmp`;
      await writeFile(temporary, snapshot, { encoding: "utf8", mode: 0o600 });
      await rename(temporary, this.storagePath);
    });
    this.persistChain = operation.catch(() => {});
    await operation;
  }
}

function requiredString(params: JsonObject, key: string): string {
  const value = params[key];
  if (typeof value !== "string" || !value) throw new Error(`Missing ${key}.`);
  return value;
}
