export interface QueuedPromptWait {
  waitForTurnId?: string;
  createdAt: number;
}

export interface ObservedTurnWaitState {
  known: boolean;
  isRunning: boolean;
  turnId?: string;
  startedAt?: number;
}

export function queuedPromptWaitSatisfied(
  prompt: QueuedPromptWait,
  observed: ObservedTurnWaitState,
  completedTurnId?: string,
): boolean {
  if (!prompt.waitForTurnId) return true;
  if (completedTurnId === prompt.waitForTurnId) return true;
  if (!observed.known) return false;
  if (observed.turnId === prompt.waitForTurnId) return !observed.isRunning;
  return typeof observed.startedAt === "number" && observed.startedAt >= prompt.createdAt;
}
