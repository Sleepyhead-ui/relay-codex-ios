export type ConnectionState = "disconnected" | "connecting" | "handshaking" | "reconnecting" | "connected" | "error" | "failed";

export interface ConnectionConfig { endpoint: string; token: string }
export type ServiceState = "stopped" | "starting" | "running" | "degraded" | "failed";
export interface ServiceStatus { state: ServiceState; message: string; connection?: ConnectionConfig }
export interface DesktopPreferences { autoStart: boolean; notifications: boolean }
export interface DesktopUpdateState { state: "idle" | "checking" | "available" | "current" | "downloading" | "ready" | "deferred" | "installing" | "error"; currentVersion?: string; version?: string; percent?: number; message?: string; blockers?: string[] }
export interface Bootstrap { connection: ConnectionConfig; version: string; service: ServiceStatus; preferences: DesktopPreferences }

export interface CodexProfile {
  id: string;
  name: string;
  codexHome: string;
  source: "default" | "cockpit" | "custom";
  active: boolean;
  running: boolean;
}

export interface ThreadSummary {
  id: string;
  title: string;
  preview: string;
  cwd: string;
  updatedAt: number;
  status: string;
}

export type GoalStatus = "active" | "paused" | "blocked" | "usage_limited" | "budget_limited" | "complete";
export interface GoalState {
  threadId: string;
  id: string;
  objective: string;
  status: GoalStatus;
  tokenBudget: number | null;
  tokensUsed: number;
  timeUsedSeconds: number;
  createdAt: number;
  updatedAt: number;
}

export type ItemKind = "user" | "assistant" | "reasoning" | "command" | "file" | "tool" | "plan" | "compaction" | "other";

export interface TranscriptItem {
  id: string;
  turnId?: string;
  kind: ItemKind;
  text: string;
  detail?: string;
  title?: string;
  phase?: string;
  status?: string;
  cwd?: string;
  exitCode?: number;
  imagePaths?: string[];
  goal?: string;
}

export interface TurnMetadata {
  id: string;
  status: string;
  startedAt?: number;
  completedAt?: number;
  durationMs?: number;
  error?: string;
}

export interface ModelOption {
  id: string;
  model: string;
  displayName: string;
  description: string;
  defaultEffort: string;
  efforts: string[];
  isDefault: boolean;
}

export interface PlanStep { id: string; text: string; status: string }
export interface Attachment { path: string; name: string; isImage: boolean }
export interface QueuedPrompt {
  id: string;
  threadId: string;
  clientUserMessageId: string;
  text: string;
  input: Array<{ type?: string; text?: string; name?: string; path?: string }>;
  createdAt: number;
}
export type WorkspaceAccess = "readOnly" | "workspaceWrite" | "fullAccess";

export interface ApprovalRequest {
  id: string | number;
  method: string;
  threadId?: string;
  turnId?: string;
  params: Record<string, any>;
  title: string;
  summary: string;
  detail?: string;
}

export interface DiagnosticCheck {
  id: string;
  level: "ok" | "warning" | "error";
  title: string;
  detail: string;
}

export interface DiagnosticEvent {
  id: number;
  at: string;
  level: "info" | "warning" | "error";
  category: string;
  message: string;
  details?: Record<string, unknown>;
}

export interface DiagnosticTimingMetrics {
  count: number;
  averageMs: number;
  p50Ms: number;
  p95Ms: number;
  maxMs: number;
}

export interface ClientDiagnosticPerformance {
  sessions: {
    snapshots: number;
    patches: number;
    revisionGaps: number;
    recoveries: number;
    snapshotApplyLatency: DiagnosticTimingMetrics;
    patchApplyLatency: DiagnosticTimingMetrics;
  };
  deltas: {
    queued: number;
    frameFlushes: number;
    updatedItems: number;
    maxItemsPerFrame: number;
    flushLatency: DiagnosticTimingMetrics;
  };
}

export interface BridgeDiagnosticPerformance {
  sessions: {
    snapshots: number;
    patches: number;
    patchToSnapshotByteRatio: number;
  };
  rpcLatency: DiagnosticTimingMetrics;
}

export interface DiagnosticReport {
  generatedAt: string;
  summary: "ok" | "warning" | "error";
  checks: DiagnosticCheck[];
  metrics: {
    clients: number;
    activeTurns: number;
    pendingRpcCount: number;
    pendingApprovalCount: number;
    queuedPromptCount: number;
    uptimeSeconds: number;
  };
  events: DiagnosticEvent[];
  performance?: BridgeDiagnosticPerformance;
  clientPerformance?: ClientDiagnosticPerformance;
  [key: string]: unknown;
}

declare global {
  interface Window {
    relayDesktop: {
      bootstrap(): Promise<Bootstrap>;
      serviceStatus(): Promise<ServiceStatus>;
      startService(): Promise<ServiceStatus>;
      setPreferences(patch: Partial<DesktopPreferences>): Promise<DesktopPreferences>;
      notify(payload: { title: string; body: string }): Promise<boolean>;
      exportDiagnostics(report: DiagnosticReport): Promise<boolean>;
      updateStatus(): Promise<DesktopUpdateState>;
      checkUpdate(): Promise<DesktopUpdateState>;
      downloadUpdate(): Promise<DesktopUpdateState>;
      installUpdate(): Promise<DesktopUpdateState>;
      connect(config: ConnectionConfig): Promise<boolean>;
      disconnect(): Promise<void>;
      send(message: unknown): Promise<boolean>;
      pickFiles(): Promise<string[]>;
      showFile(path: string): Promise<boolean>;
      readImage(path: string): Promise<string | undefined>;
      onMessage(listener: (message: any) => void): () => void;
      onState(listener: (state: any) => void): () => void;
      onService(listener: (state: ServiceStatus) => void): () => void;
      onUpdate(listener: (state: DesktopUpdateState) => void): () => void;
    };
  }
}
