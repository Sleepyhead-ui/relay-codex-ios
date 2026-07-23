export const codexStartupWatchdogMs = 30_000;

export function codexRestartDelayMs(attempt: number): number {
  const normalizedAttempt = Math.max(1, Math.trunc(Number.isFinite(attempt) ? attempt : 1));
  return Math.min(1_000 * Math.pow(1.8, normalizedAttempt - 1), 30_000);
}

export function shouldScheduleCodexRestart(options: {
  shuttingDown: boolean;
  generation: number;
  currentGeneration: number;
  timerPending: boolean;
}): boolean {
  return !options.shuttingDown
    && options.generation === options.currentGeneration
    && !options.timerPending;
}

export function shouldReplaceUnreadyCodex(options: {
  shuttingDown: boolean;
  generation: number;
  currentGeneration: number;
  ready: boolean;
}): boolean {
  return !options.shuttingDown
    && options.generation === options.currentGeneration
    && !options.ready;
}
