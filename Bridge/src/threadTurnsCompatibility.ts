import type { JsonObject } from "./protocol.js";

const legacyCursorPrefix = "relay-legacy-thread-turns:";

export function isPaginatedThreadsUnsupported(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error ?? "");
  return /paginated[_ ]?threads[\s\S]*(?:not\s+supported|unsupported)|(?:not\s+supported|unsupported)[\s\S]*paginated[_ ]?threads/i.test(message);
}

export function isLegacyThreadTurnsCursor(value: unknown): value is string {
  return typeof value === "string" && value.startsWith(legacyCursorPrefix);
}

export function legacyThreadTurnsCursorStart(value: string): number | undefined {
  if (!isLegacyThreadTurnsCursor(value)) return undefined;
  const start = Number(value.slice(legacyCursorPrefix.length));
  return Number.isSafeInteger(start) && start >= 0 ? start : undefined;
}

export function legacyThreadTurnsCursor(endIndex: number): string {
  return `${legacyCursorPrefix}${Math.max(0, Math.floor(endIndex))}`;
}

export function paginateLegacyThreadTurns(
  result: JsonObject,
  params: JsonObject,
): JsonObject {
  const thread = result.thread && typeof result.thread === "object" && !Array.isArray(result.thread)
    ? result.thread as JsonObject
    : {};
  const turns = Array.isArray(thread.turns) ? thread.turns : Array.isArray(result.turns) ? result.turns : [];
  const orderedTurns = params.sortDirection === "asc" ? turns : [...turns].reverse();
  const requestedLimit = typeof params.limit === "number" && Number.isFinite(params.limit)
    ? Math.floor(params.limit)
    : 12;
  const limit = Math.min(50, Math.max(1, requestedLimit));
  const cursor = isLegacyThreadTurnsCursor(params.cursor) ? params.cursor : undefined;
  const parsedStart = cursor ? legacyThreadTurnsCursorStart(cursor) ?? 0 : 0;
  const startIndex = Number.isSafeInteger(parsedStart) ? Math.min(orderedTurns.length, Math.max(0, parsedStart)) : 0;
  const endIndex = Math.min(orderedTurns.length, startIndex + limit);

  return {
    data: orderedTurns.slice(startIndex, endIndex),
    ...(endIndex < orderedTurns.length ? { nextCursor: legacyThreadTurnsCursor(endIndex) } : {}),
  };
}
