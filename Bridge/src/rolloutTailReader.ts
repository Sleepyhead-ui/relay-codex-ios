import { open } from "node:fs/promises";
import { StringDecoder } from "node:string_decoder";
import type { JsonObject } from "./protocol.js";
import { isObject } from "./protocol.js";

export interface ParsedRolloutTurn {
  known: boolean;
  isRunning: boolean;
  turnId?: string;
  startedAt?: number;
  completedAt?: number;
  items: JsonObject[];
}

type ItemParser = (payload: JsonObject, fallbackId?: string) => JsonObject | null;

const marker = Buffer.from('"type":"task_started"');
const scanChunkBytes = 1024 * 1024;
const readChunkBytes = 256 * 1024;

export class RolloutTailReader {
  private offset = 0;
  private remainder = "";
  private decoder = new StringDecoder("utf8");
  private turnId: string | undefined;
  private startedAt: number | undefined;
  private completedAt: number | undefined;
  private startTimestamp = 0;
  private completeTimestamp = 0;
  private items: JsonObject[] = [];
  private itemIndexes = new Map<string, number>();
  private toolIndexes = new Map<string, number>();
  private lastUserIndex: number | undefined;
  private responseIndex = 0;
  bytesRead = 0;

  constructor(private readonly path: string, private readonly parseItem: ItemParser) {}

  async read(fileSize: number): Promise<ParsedRolloutTurn> {
    if (this.offset === 0 || fileSize < this.offset) {
      this.resetParser();
      this.offset = await findLatestTurnOffset(this.path, fileSize);
    }
    if (fileSize > this.offset) await this.readAppendedBytes(fileSize);
    return this.current();
  }

  private async readAppendedBytes(targetSize: number): Promise<void> {
    const file = await open(this.path, "r");
    try {
      while (this.offset < targetSize) {
        const length = Math.min(readChunkBytes, targetSize - this.offset);
        const buffer = Buffer.allocUnsafe(length);
        const { bytesRead } = await file.read(buffer, 0, length, this.offset);
        if (bytesRead <= 0) break;
        this.offset += bytesRead;
        this.bytesRead += bytesRead;
        this.consumeText(this.decoder.write(buffer.subarray(0, bytesRead)));
      }
    } finally {
      await file.close();
    }
  }

  private consumeText(text: string): void {
    const lines = `${this.remainder}${text}`.split(/\r?\n/);
    this.remainder = lines.pop() ?? "";
    for (const line of lines) this.consumeLine(line);
  }

  private consumeLine(line: string): void {
    if (!line.trim()) return;
    let event: JsonObject;
    try { event = JSON.parse(line) as JsonObject; } catch { return; }
    const payload = isObject(event.payload) ? event.payload : {};
    const type = typeof payload.type === "string" ? payload.type : "";
    const timestamp = typeof event.timestamp === "string" ? Date.parse(event.timestamp) / 1000 : 0;

    if (type === "task_started") {
      this.resetTurn();
      this.turnId = typeof payload.turn_id === "string" ? payload.turn_id : undefined;
      this.startedAt = typeof payload.started_at === "number" ? payload.started_at : timestamp;
      this.startTimestamp = timestamp;
      return;
    }
    if (!this.turnId) return;

    if (["task_complete", "turn_aborted", "turn_interrupted", "turn_failed", "turn_completed", "task_aborted"].includes(type)) {
      const completedTurnId = typeof payload.turn_id === "string" ? payload.turn_id : undefined;
      if (!completedTurnId || completedTurnId === this.turnId) {
        this.completedAt = typeof payload.completed_at === "number" ? payload.completed_at : timestamp;
        this.completeTimestamp = timestamp;
      }
    } else if (type === "user_message" && typeof this.lastUserIndex === "number") {
      if (typeof payload.client_id === "string") this.items[this.lastUserIndex]!.clientId = payload.client_id;
    }

    if (event.type !== "response_item") return;
    this.responseIndex += 1;
    const item = this.parseItem(payload, `rollout.${this.turnId}.${this.responseIndex}`);
    if (item) {
      const id = String(item.id);
      const existingIndex = this.itemIndexes.get(id);
      if (typeof existingIndex === "number") this.items[existingIndex] = item;
      else {
        this.itemIndexes.set(id, this.items.length);
        this.items.push(item);
      }
      if (item.type === "userMessage") this.lastUserIndex = this.itemIndexes.get(id);
      const callId = typeof payload.call_id === "string" ? payload.call_id : undefined;
      if (callId && item.type === "dynamicToolCall") this.toolIndexes.set(callId, this.itemIndexes.get(id)!);
      return;
    }

    if ((type === "custom_tool_call_output" || type === "function_call_output") && typeof payload.call_id === "string") {
      const toolIndex = this.toolIndexes.get(payload.call_id);
      if (typeof toolIndex === "number") {
        this.items[toolIndex]!.status = "completed";
        this.items[toolIndex]!.result = payload.output ?? payload.result ?? null;
      }
    }
  }

  private current(): ParsedRolloutTurn {
    return {
      known: Boolean(this.turnId),
      isRunning: this.startTimestamp > this.completeTimestamp,
      ...(this.turnId ? { turnId: this.turnId } : {}),
      ...(this.startedAt ? { startedAt: this.startedAt } : {}),
      ...(this.completedAt ? { completedAt: this.completedAt } : {}),
      items: this.items.map((item) => ({ ...item })),
    };
  }

  private resetParser(): void {
    this.offset = 0;
    this.remainder = "";
    this.decoder = new StringDecoder("utf8");
    this.bytesRead = 0;
    this.resetTurn();
  }

  private resetTurn(): void {
    this.turnId = undefined;
    this.startedAt = undefined;
    this.completedAt = undefined;
    this.startTimestamp = 0;
    this.completeTimestamp = 0;
    this.items = [];
    this.itemIndexes = new Map();
    this.toolIndexes = new Map();
    this.lastUserIndex = undefined;
    this.responseIndex = 0;
  }
}

async function findLatestTurnOffset(path: string, fileSize: number): Promise<number> {
  if (fileSize <= 0) return 0;
  const file = await open(path, "r");
  try {
    let end = fileSize;
    let suffix = Buffer.alloc(0);
    while (end > 0) {
      const start = Math.max(0, end - scanChunkBytes);
      const length = end - start;
      const chunk = Buffer.allocUnsafe(length);
      const { bytesRead } = await file.read(chunk, 0, length, start);
      const value = Buffer.concat([chunk.subarray(0, bytesRead), suffix]);
      const index = value.lastIndexOf(marker);
      if (index >= 0) {
        const markerOffset = start + index;
        const prefixStart = Math.max(0, markerOffset - 64 * 1024);
        const prefix = Buffer.allocUnsafe(markerOffset - prefixStart);
        const prefixRead = await file.read(prefix, 0, prefix.length, prefixStart);
        const newline = prefix.subarray(0, prefixRead.bytesRead).lastIndexOf(0x0a);
        return newline >= 0 ? prefixStart + newline + 1 : 0;
      }
      suffix = chunk.subarray(0, Math.min(marker.length - 1, bytesRead));
      end = start;
    }
    return 0;
  } finally {
    await file.close();
  }
}
