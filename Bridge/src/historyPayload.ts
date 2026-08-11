import { isObject, type JsonObject } from "./protocol.js";
import { boundSessionItem } from "./sessionPatch.js";

const maximumHistoryPageBytes = 1536 * 1024;
const maximumHistoryTurnBytes = 768 * 1024;
const minimumHistoryTurnBytes = 128 * 1024;
const historyTechnicalPreviewBytes = 24 * 1024;

/** Keeps history pages cheap to parse while preserving prompts and answers. */
export function boundHistoryPage(value: unknown): JsonObject {
  const page = isObject(value) ? value : {};
  const data = Array.isArray(page.data) ? page.data : [];
  if (data.length === 0) return page;
  const turnBudget = Math.max(
    minimumHistoryTurnBytes,
    Math.min(maximumHistoryTurnBytes, Math.floor(maximumHistoryPageBytes / data.length)),
  );
  return {
    ...page,
    data: data.map((turn) => boundHistoryTurn(turn, turnBudget)),
  };
}

/** Applies the same history budget to RPCs that embed a history page. */
export function boundThreadHistoryResult(value: unknown): unknown {
  if (!isObject(value)) return value;
  let result: JsonObject = value;
  if (isObject(value.initialTurnsPage)) {
    result = { ...result, initialTurnsPage: boundHistoryPage(value.initialTurnsPage) };
  }
  if (isObject(value.thread) && Array.isArray(value.thread.turns)) {
    result = {
      ...result,
      thread: {
        ...value.thread,
        turns: boundHistoryPage({ data: value.thread.turns }).data,
      },
    };
  }
  return result;
}

function boundHistoryTurn(value: unknown, maximumBytes: number): unknown {
  if (!isObject(value) || !Array.isArray(value.items)) return value;
  const items = value.items.map((item) => isObject(item)
    ? boundSessionItem(item, historyTechnicalPreviewBytes)
    : item);
  let turn: JsonObject = { ...value, items };
  let turnBytes = encodedBytes(turn);
  if (turnBytes <= maximumBytes) return turn;

  const compacted = [...items];
  for (let index = 0; index < compacted.length && turnBytes > maximumBytes; index += 1) {
    const item = compacted[index];
    if (!isObject(item) || !isTechnicalItem(item)) continue;
    const summary = summarizeTechnicalItem(item);
    turnBytes += encodedBytes(summary) - encodedBytes(item);
    compacted[index] = summary;
  }
  turn = { ...value, items: compacted, historyTruncated: true };
  turnBytes = encodedBytes(turn);
  if (turnBytes > maximumBytes) {
    const essentialIndexes = new Set(compacted.flatMap((item, index) =>
      isObject(item) && isEssentialMessage(item) ? [index] : []));
    const recentActivityIndexes = compacted
      .map((_, index) => index)
      .filter((index) => !essentialIndexes.has(index))
      .slice(-32);
    const retainedIndexes = new Set([...essentialIndexes, ...recentActivityIndexes]);
    const retainedItems = compacted.filter((_, index) => retainedIndexes.has(index));
    turn = {
      ...value,
      items: retainedItems,
      historyTruncated: true,
      historyOmittedItemCount: compacted.length - retainedItems.length,
    };
  }
  return turn;
}

function isTechnicalItem(item: JsonObject): boolean {
  const type = typeof item.type === "string" ? item.type : "";
  return ["commandExecution", "fileChange", "dynamicToolCall", "mcpToolCall", "webSearch"].includes(type);
}

function isEssentialMessage(item: JsonObject): boolean {
  if (item.type === "userMessage") return true;
  return item.type === "agentMessage" && item.phase !== "commentary";
}

function summarizeTechnicalItem(item: JsonObject): JsonObject {
  const bounded: JsonObject = { ...item, historyDetailOmitted: true };
  for (const key of ["aggregatedOutput", "output", "result", "contentItems", "arguments", "input"]) {
    if (bounded[key] !== undefined) delete bounded[key];
  }
  return bounded;
}

function encodedBytes(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value));
}
