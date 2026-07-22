import type { PlanStep } from "./types";

export type TaskRunPhase = "idle" | "starting" | "running" | "retrying" | "completed" | "interrupted" | "failed";

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
  | { type: "starting"; startedAt?: number }
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
    case "starting":
      return { threadId: state.threadId, phase: "starting", startedAt: event.startedAt ?? Date.now() / 1000, plan: [] };
    case "hydrate":
      return event.running
        ? { threadId: state.threadId, phase: event.turnId ? "running" : "starting", turnId: event.turnId, startedAt: event.startedAt, plan: [] }
        : idleTaskState(state.threadId);
    case "started":
      return { threadId: state.threadId, phase: "running", turnId: event.turnId, startedAt: event.startedAt ?? Date.now() / 1000, plan: [] };
    case "progress":
      if (state.turnId && state.turnId !== event.turnId && !["idle", "starting", "retrying"].includes(state.phase)) return state;
      if (!state.turnId && ["completed", "interrupted", "failed"].includes(state.phase)) return state;
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
      return { ...state, phase: state.phase === "retrying" ? state.turnId ? "running" : "starting" : state.phase, retryMessage: undefined };
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
  return state?.phase === "starting" || state?.phase === "running" || state?.phase === "retrying";
}

export interface TaskStateCore {
  states: Record<string, TaskRunState>;
  completedTurnIds: ReadonlySet<string>;
}

export interface TaskEventTransition {
  threadId?: string;
  turnId?: string;
  events: TaskRunEvent[];
}

export function createTaskStateCore(): TaskStateCore {
  return { states: {}, completedTurnIds: new Set() };
}

export function reduceTaskStateCore(core: TaskStateCore, threadId: string, event: TaskRunEvent): TaskStateCore {
  const previous = core.states[threadId] || idleTaskState(threadId);
  const turnId = referencedTurnId(event);
  if (turnId && core.completedTurnIds.has(turnId) && isReplayableProgress(event)) return core;

  const next = reduceTaskRunState(previous, event);
  let completed = core.completedTurnIds;
  const mutableCompleted = () => {
    if (completed === core.completedTurnIds) completed = new Set(completed);
    return completed as Set<string>;
  };
  if (event.type === "terminal") {
    const completedTurnId = event.turnId || previous.turnId;
    if (completedTurnId) mutableCompleted().add(completedTurnId);
  } else if (event.type === "hydrate" && event.turnId) {
    if (event.running) mutableCompleted().delete(event.turnId);
    else mutableCompleted().add(event.turnId);
  }
  if (next === previous && completed === core.completedTurnIds) return core;
  return { states: next === previous ? core.states : { ...core.states, [threadId]: next }, completedTurnIds: completed };
}

export function decodeTaskRunEvents(method: string, params: any, fallbackThreadId?: string): TaskEventTransition {
  const threadId = params?.threadId || fallbackThreadId;
  const turnId = params?.turnId || params?.turn?.id;
  let events: TaskRunEvent[] = [];
  if (method === "turn/started" && turnId) {
    events = [{ type: "started", turnId, startedAt: params?.turn?.startedAt }];
  } else if (["turn/completed", "turn/aborted", "turn/interrupted", "turn/failed"].includes(method)) {
    events = [{
      type: "terminal",
      turnId,
      phase: method === "turn/failed" ? "failed" : method === "turn/completed" ? "completed" : "interrupted",
      completedAt: params?.turn?.completedAt,
    }];
  } else if (method === "turn/plan/updated" && turnId) {
    events = [
      { type: "progress", turnId },
      {
        type: "plan",
        turnId,
        plan: (params?.plan || []).flatMap((step: any, index: number) => {
          const text = String(step?.step || "").trim();
          return text ? [{ id: `${turnId}.${index}`, text, status: step?.status || "pending" }] : [];
        }),
      },
    ];
  } else if (method === "error") {
    const message = params?.error?.message || params?.message;
    if (params?.willRetry === true) events = [{ type: "retrying", turnId, message }];
    else if (params?.willRetry === false) events = [{ type: "terminal", turnId, phase: "failed" }];
    else events = [{ type: "clearRetry" }];
  } else if (turnId && (method === "item/started" || method === "item/completed" || method.startsWith("item/") && (/\/delta$/i.test(method) || /Delta$/.test(method)))) {
    events = [{ type: "progress", turnId }];
  }
  return { threadId, turnId, events };
}

function referencedTurnId(event: TaskRunEvent) {
  switch (event.type) {
    case "started": case "progress": case "plan": case "retrying": case "terminal": return event.turnId;
    case "hydrate": return event.turnId;
    default: return undefined;
  }
}

function isReplayableProgress(event: TaskRunEvent) {
  return event.type === "started" || event.type === "progress" || event.type === "plan";
}
