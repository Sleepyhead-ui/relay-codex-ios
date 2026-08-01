import type { JsonObject } from "./protocol.js";

export interface CompletionSnapshot {
  turnId?: string;
  items?: JsonObject[];
}

export function finalAnswerText(items: JsonObject[] | undefined): string | undefined {
  const answer = [...(items ?? [])].reverse().find((item) =>
    item.type === "agentMessage"
      && item.phase !== "commentary"
      && typeof item.text === "string"
      && item.text.trim());
  return typeof answer?.text === "string" ? answer.text.trim() : undefined;
}

export async function awaitFinalAnswer(options: {
  turnId: string;
  initialItems?: JsonObject[];
  loadSnapshot: () => Promise<CompletionSnapshot>;
  retryDelaysMs?: number[];
  wait?: (milliseconds: number) => Promise<void>;
}): Promise<string | undefined> {
  const immediate = finalAnswerText(options.initialItems);
  if (immediate) return immediate;

  const wait = options.wait ?? ((milliseconds) => new Promise<void>((resolve) => setTimeout(resolve, milliseconds)));
  for (const delay of options.retryDelaysMs ?? [0, 120, 280, 600, 1_200]) {
    if (delay > 0) await wait(delay);
    const snapshot = await options.loadSnapshot();
    if (snapshot.turnId && snapshot.turnId !== options.turnId) continue;
    const answer = finalAnswerText(snapshot.items);
    if (answer) return answer;
  }
  return undefined;
}
