import type { PlanStep } from "./types";

export type TaskRunPhase = "idle" | "running" | "retrying" | "completed" | "interrupted" | "failed";

export interface TaskRunState {
  threadId: string;
  phase: TaskRunPhase;
  turnId?: string;
  startedAt?: number;
  completedAt?: number;
  retryMessage?: string;
  planTurnId?: string;
  plan: PlanStep[];
}

export type TaskRunEvent =
  | { type: "reset" }
  | { type: "hydrate"; running: boolean; turnId?: string; startedAt?: number }
  | { type: "started"; turnId: string; startedAt?: number }
  | { type: "progress"; turnId: string; startedAt?: number }
  | { type: "plan"; turnId: string; plan: PlanStep[] }
  | { type: "retrying"; turnId?: string; message?: string }
  | { type: "clearRetry" }
  | { type: "terminal"; turnId?: string; phase?: "completed" | "interrupted" | "failed"; completedAt?: number };

export function idleTaskState(threadId: string): TaskRunState {
  return { threadId, phase: "idle", plan: [] };
}

export function reduceTaskRunState(state: TaskRunState, event: TaskRunEvent): TaskRunState {
  switch (event.type) {
    case "reset":
      return idleTaskState(state.threadId);
    case "hydrate":
      return event.running && event.turnId
        ? { threadId: state.threadId, phase: "running", turnId: event.turnId, startedAt: event.startedAt, plan: [] }
        : idleTaskState(state.threadId);
    case "started":
      return { threadId: state.threadId, phase: "running", turnId: event.turnId, startedAt: event.startedAt ?? Date.now() / 1000, plan: [] };
    case "progress":
      if (state.turnId && state.turnId !== event.turnId && state.phase !== "idle") return state;
      return {
        ...state,
        phase: "running",
        turnId: event.turnId,
        startedAt: state.turnId === event.turnId ? state.startedAt ?? event.startedAt : event.startedAt ?? Date.now() / 1000,
        completedAt: undefined,
        retryMessage: undefined,
        ...(state.turnId === event.turnId ? {} : { plan: [], planTurnId: undefined }),
      };
    case "plan":
      if (state.turnId !== event.turnId || !["running", "retrying"].includes(state.phase)) return state;
      return { ...state, planTurnId: event.turnId, plan: event.plan };
    case "retrying":
      if (event.turnId && state.turnId && event.turnId !== state.turnId) return state;
      return { ...state, phase: state.turnId ? "retrying" : state.phase, retryMessage: event.message };
    case "clearRetry":
      return { ...state, phase: state.phase === "retrying" ? "running" : state.phase, retryMessage: undefined };
    case "terminal":
      if (event.turnId && state.turnId && event.turnId !== state.turnId) return state;
      return {
        threadId: state.threadId,
        phase: event.phase ?? "completed",
        turnId: undefined,
        startedAt: state.startedAt,
        completedAt: event.completedAt ?? Date.now() / 1000,
        plan: [],
      };
  }
}

export function isTaskRunning(state: TaskRunState | undefined): boolean {
  return state?.phase === "running" || state?.phase === "retrying";
}
