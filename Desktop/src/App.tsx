import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import DOMPurify from "dompurify";
import { marked } from "marked";
import {
  Activity, AlertCircle, Archive, ArrowDown, ArrowUp, Check, ChevronDown, ChevronRight, CircleStop, Copy,
  FileCode2, Folder, FolderOpen, Menu, MessageSquare, MoreHorizontal, Paperclip, Pencil, Pin, PinOff, Plus, RefreshCw, Search, Target,
  Power, RotateCcw, Server, Settings, Sparkles, SquarePen, Terminal, Wifi, WifiOff, X,
} from "lucide-react";
import { BridgeRpc } from "./bridge";
import {
  applyContextCompaction, applyDeltaBatch, applyUserMessagePlacements, bindUserPrompt, diffLineKind, filterThreads, formatElapsed, groupProjects, isRunningStatus, mergeSessionPatch, mergeSnapshot, parseApproval,
  parseItem, parseModel, parseThread, parseTurn, upsert,
} from "./transcript";
import type { UserMessagePlacement } from "./transcript";
import { createTaskStateCore, decodeTaskRunEvents, isTaskRunning, reduceTaskStateCore, type TaskRunEvent } from "./taskState";
import { DesktopPerformanceMetrics } from "./performanceMetrics";
import { SessionRevisionTracker } from "./sessionRevision";
import type {
  ApprovalRequest, Attachment, CodexProfile, ConnectionConfig, ConnectionState, DesktopPreferences, DesktopUpdateState, DiagnosticReport, ModelOption,
  GoalState, PlanStep, QueuedPrompt, ServiceStatus, ThreadSummary, TranscriptItem, TurnMetadata, WorkspaceAccess,
} from "./types";

const imageExtensions = new Set(["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"]);

export default function App() {
  const rpc = useMemo(() => new BridgeRpc(), []);
  const [connection, setConnection] = useState<ConnectionState>("disconnected");
  const [connectionAttempt, setConnectionAttempt] = useState(0);
  const [service, setService] = useState<ServiceStatus>({ state: "stopped", message: "远程服务未启动" });
  const [config, setConfig] = useState<ConnectionConfig>({ endpoint: "ws://127.0.0.1:8765", token: "" });
  const [version, setVersion] = useState("0.1.0");
  const [threads, setThreads] = useState<ThreadSummary[]>([]);
  const [models, setModels] = useState<ModelOption[]>([]);
  const [selectedModel, setSelectedModel] = useState("");
  const [effort, setEffort] = useState("high");
  const [defaultAccess, setDefaultAccess] = useState<WorkspaceAccess>(() => storedWorkspaceAccess());
  const [projectAccesses, setProjectAccesses] = useState<Record<string, WorkspaceAccess>>(() => storedProjectAccesses());
  const [workspace, setWorkspace] = useState(localStorage.getItem("relay.desktop.cwd") || "");
  const [selectedThreadId, setSelectedThreadId] = useState<string>();
  const [messages, setMessages] = useState<TranscriptItem[]>([]);
  const [turns, setTurns] = useState<Record<string, TurnMetadata>>({});
  const [taskCore, setTaskCore] = useState(createTaskStateCore);
  const [goals, setGoals] = useState<Record<string, GoalState>>({});
  const [composer, setComposer] = useState("");
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [followUpBehavior, setFollowUpBehavior] = useState<"steer" | "queue">(() => localStorage.getItem("relay.desktop.followUp") === "queue" ? "queue" : "steer");
  const [queuedPrompts, setQueuedPrompts] = useState<QueuedPrompt[]>([]);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [newTaskOpen, setNewTaskOpen] = useState(false);
  const [newTaskCwd, setNewTaskCwd] = useState(workspace);
  const [loadingThread, setLoadingThread] = useState(false);
  const [loadingOlderTurns, setLoadingOlderTurns] = useState(false);
  const [olderTurnsCursor, setOlderTurnsCursor] = useState<string>();
  const [threadSearch, setThreadSearch] = useState("");
  const [archivedView, setArchivedView] = useState(false);
  const [pinnedThreadIds, setPinnedThreadIds] = useState<Set<string>>(() => storedPinnedThreads("default"));
  const [renamingThread, setRenamingThread] = useState<ThreadSummary>();
  const [renameDraft, setRenameDraft] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string>();
  const [approvals, setApprovals] = useState<ApprovalRequest[]>([]);
  const [codexProfiles, setCodexProfiles] = useState<CodexProfile[]>([]);
  const [activeProfileId, setActiveProfileId] = useState("");
  const [profileSwitching, setProfileSwitching] = useState(false);
  const [diagnosticsOpen, setDiagnosticsOpen] = useState(false);
  const [diagnosticsLoading, setDiagnosticsLoading] = useState(false);
  const [diagnostics, setDiagnostics] = useState<DiagnosticReport>();
  const [preferences, setPreferences] = useState<DesktopPreferences>({ autoStart: false, notifications: true });
  const [update, setUpdate] = useState<DesktopUpdateState>({ state: "idle" });
  const selectedRef = useRef<string>();
  const activeTurnRef = useRef<string>();
  const profileSwitchingRef = useRef(false);
  const pendingStartMessageRef = useRef<string>();
  const userMessagePlacementsRef = useRef(new Map<string, UserMessagePlacement>());
  const placementSequenceRef = useRef(0);
  const messagesRef = useRef<TranscriptItem[]>([]);
  const threadMessageCacheRef = useRef(new Map<string, TranscriptItem[]>());
  const notifiedTurnIdsRef = useRef(new Set<string>());
  const sessionRevisionRef = useRef(new SessionRevisionTracker());
  const recoveringSessionRef = useRef(new Set<string>());
  const pendingDeltaRef = useRef(new Map<string, { id: string; turnId: string; kind: "assistant" | "reasoning" | "command"; textChunks: string[]; detailChunks: string[] }>());
  const deltaFrameRef = useRef<number>();
  const performanceMetricsRef = useRef(new DesktopPerformanceMetrics());
  const messageHandlerRef = useRef<(message: any) => void>(() => {});
  const transcriptEndRef = useRef<HTMLDivElement>(null);
  const [atBottom, setAtBottom] = useState(true);
  const scrollRef = useRef<HTMLDivElement>(null);

  const selectedThread = threads.find((thread) => thread.id === selectedThreadId);
  const taskStates = taskCore.states;
  const accessKey = normalizedWorkspaceKey(selectedThread?.cwd || workspace);
  const access = accessKey ? projectAccesses[accessKey] || defaultAccess : defaultAccess;
  const selectedTaskState = selectedThreadId ? taskStates[selectedThreadId] : undefined;
  const activeTurnId = selectedTaskState?.turnId;
  const plan = selectedTaskState && selectedTaskState.planTurnId === activeTurnId ? selectedTaskState.plan : [];
  const upstreamRetrying = selectedTaskState?.phase === "retrying";
  const running = isTaskRunning(selectedTaskState) || (!selectedTaskState && isRunningStatus(selectedThread?.status));
  const selectedModelOption = models.find((model) => model.model === selectedModel || model.id === selectedModel);
  const activeCodexProfile = codexProfiles.find((profile) => profile.id === activeProfileId);
  const selectedApprovals = approvals.filter((item) => item.threadId === selectedThreadId || !item.threadId);
  const approvalQueue = selectedApprovals.length ? selectedApprovals : approvals;
  const approval = approvalQueue[0];
  const approvalThreadIds = useMemo(() => new Set(approvals.flatMap((item) => item.threadId ? [item.threadId] : [])), [approvals]);
  const projects = useMemo(() => groupProjects(sortPinnedThreads(filterThreads(threads, threadSearch), pinnedThreadIds)), [threads, threadSearch, pinnedThreadIds]);
  const currentQueuedPrompts = queuedPrompts.filter((item) => item.threadId === selectedThreadId);
  const currentGoal = selectedThreadId ? goals[selectedThreadId] : undefined;
  messagesRef.current = messages;

  function updateTaskState(threadId: string, event: TaskRunEvent) {
    setTaskCore((current) => reduceTaskStateCore(current, threadId, event));
  }

  function setAccess(value: WorkspaceAccess) {
    if (accessKey) setProjectAccesses((current) => ({ ...current, [accessKey]: value }));
    else setDefaultAccess(value);
  }

  useEffect(() => { selectedRef.current = selectedThreadId; }, [selectedThreadId]);
  useEffect(() => { activeTurnRef.current = activeTurnId; }, [activeTurnId]);
  useEffect(() => { localStorage.setItem("relay.desktop.cwd", workspace); }, [workspace]);
  useEffect(() => { localStorage.setItem("relay.desktop.access", defaultAccess); }, [defaultAccess]);
  useEffect(() => { localStorage.setItem("relay.desktop.accessByProject", JSON.stringify(projectAccesses)); }, [projectAccesses]);
  useEffect(() => { localStorage.setItem("relay.desktop.followUp", followUpBehavior); }, [followUpBehavior]);
  useEffect(() => () => {
    if (deltaFrameRef.current !== undefined) cancelAnimationFrame(deltaFrameRef.current);
  }, []);

  useEffect(() => {
    const offMessage = window.relayDesktop.onMessage((message) => rpc.handle(message));
    const offState = window.relayDesktop.onState((state) => {
      setConnection(state.state);
      setConnectionAttempt(state.attempt || 0);
      if (["disconnected", "failed", "error"].includes(state.state)) rpc.failAll("Bridge 连接已断开");
    });
    const offService = window.relayDesktop.onService(setService);
    const offUpdate = window.relayDesktop.onUpdate(setUpdate);
    const offRpc = rpc.onMessage((message) => messageHandlerRef.current(message));
    void window.relayDesktop.bootstrap().then((bootstrap) => {
      setConfig(bootstrap.connection);
      setVersion(bootstrap.version);
      setService(bootstrap.service);
      setPreferences(bootstrap.preferences || { autoStart: false, notifications: true });
      void window.relayDesktop.updateStatus().then(setUpdate);
      if (bootstrap.connection.token && ["running", "starting"].includes(bootstrap.service.state)) void window.relayDesktop.connect(bootstrap.connection).catch((reason) => setError(String(reason)));
    });
    return () => { offMessage(); offState(); offService(); offUpdate(); offRpc(); };
  }, [rpc]);

  useEffect(() => {
    if (connection !== "connected") return;
    void initialize();
  }, [connection]);

  useEffect(() => {
    if (atBottom) transcriptEndRef.current?.scrollIntoView({ block: "end" });
  }, [messages, plan, atBottom]);

  messageHandlerRef.current = (message: any) => {
    if (message?.type === "event") handleEvent(String(message.method || ""), message.params || {});
    else if (message?.type === "sessionSnapshot") handleSessionSnapshot(message.threadId, message.snapshot);
    else if (message?.type === "sessionPatch") handleSessionPatch(message.threadId, message.patch);
    else if (message?.type === "serverRequest") {
      const incoming = parseApproval(message);
      setApprovals((current) => current.some((item) => String(item.id) === String(incoming.id))
        ? current.map((item) => String(item.id) === String(incoming.id) ? incoming : item)
        : [...current, incoming]);
      void window.relayDesktop.notify({ title: "Relay 等待确认", body: incoming.summary });
    }
    else if (message?.type === "serverRequestResolved") setApprovals((current) => current.filter((item) => String(item.id) !== String(message.id)));
    else if (message?.type === "promptQueueUpdated") {
      setQueuedPrompts((current) => [
        ...current.filter((item) => item.threadId !== message.threadId),
        ...(message.items || []),
      ].sort((left, right) => left.createdAt - right.createdAt));
    }
    else if (message?.type === "bridgeStatus") handleBridgeStatus(message);
    else if (message?.type === "bridgeError") setError(message.message || "Bridge 出错");
  };

  async function initialize() {
    try {
      const [threadResult, modelResult, profileResult, queueResult] = await Promise.all([
        rpc.rpc("thread/list", { limit: 200, sortKey: "updated_at", sortDirection: "desc", useStateDbOnly: true }),
        rpc.rpc("model/list", { limit: 100, includeHidden: false }),
        rpc.rpc("relay/codex/profiles/list", {}, 12_000),
        rpc.rpc("relay/prompt/queue/list", {}, 12_000),
      ]);
      const nextThreads = (threadResult.data || []).map(parseThread).filter(Boolean) as ThreadSummary[];
      const nextModels = (modelResult.data || []).map(parseModel).filter(Boolean) as ModelOption[];
      setThreads(nextThreads);
      setModels(nextModels);
      setCodexProfiles(profileResult.profiles || []);
      const nextProfileId = profileResult.activeProfileId || "default";
      setActiveProfileId(nextProfileId);
      setPinnedThreadIds(storedPinnedThreads(nextProfileId));
      setArchivedView(false);
      setQueuedPrompts((queueResult.items || []).sort((left: QueuedPrompt, right: QueuedPrompt) => left.createdAt - right.createdAt));
      const preferred = nextModels.find((model) => model.isDefault) || nextModels[0];
      if (!selectedModel && preferred) {
        setSelectedModel(preferred.model);
        setEffort(preferred.defaultEffort);
      }
      const remembered = localStorage.getItem("relay.desktop.thread");
      const target = nextThreads.find((thread) => thread.id === remembered)?.id || nextThreads[0]?.id;
      if (target && target !== selectedRef.current) await selectThread(target);
    } catch (reason) { setError(errorText(reason)); }
  }

  function handleBridgeStatus(message: any) {
    if (message.codexProfile?.id) {
      setActiveProfileId(message.codexProfile.id);
      setPinnedThreadIds(storedPinnedThreads(message.codexProfile.id));
      setCodexProfiles((current) => current.map((profile) => ({ ...profile, active: profile.id === message.codexProfile.id })));
    }
    if (message.status === "switching") {
      profileSwitchingRef.current = true;
      setProfileSwitching(true);
      setSelectedThreadId(undefined);
      selectedRef.current = undefined;
      setThreads([]);
      setMessages([]);
      setApprovals([]);
      setQueuedPrompts([]);
      userMessagePlacementsRef.current.clear();
      threadMessageCacheRef.current.clear();
      setTurns({});
      setModels([]);
      setTaskCore(createTaskStateCore());
      setGoals({});
      sessionRevisionRef.current.clear();
      recoveringSessionRef.current.clear();
      pendingDeltaRef.current.clear();
      if (deltaFrameRef.current !== undefined) cancelAnimationFrame(deltaFrameRef.current);
      deltaFrameRef.current = undefined;
      setArchivedView(false);
    } else if (message.status === "ready" && profileSwitchingRef.current) {
      profileSwitchingRef.current = false;
      setProfileSwitching(false);
      void initialize();
    }
  }

  async function startRemoteService() {
    try {
      setService({ state: "starting", message: "正在启动远程服务" });
      const status = await window.relayDesktop.startService();
      setService(status);
      if (!status.connection) throw new Error("远程服务没有返回连接信息。");
      setConfig(status.connection);
    } catch (reason) {
      setService({ state: "failed", message: errorText(reason) });
      setError(errorText(reason));
    }
  }

  async function switchCodexProfile(profileId: string) {
    if (!profileId || profileId === activeProfileId) return;
    try {
      profileSwitchingRef.current = true;
      setProfileSwitching(true);
      const result = await rpc.rpc("relay/codex/profiles/switch", { profileId }, 20_000);
      if (result.profile?.id) setActiveProfileId(result.profile.id);
    } catch (reason) {
      profileSwitchingRef.current = false;
      setProfileSwitching(false);
      setError(errorText(reason));
      throw reason;
    }
  }

  async function refreshThreads(showArchived = archivedView) {
    try {
      const result = await rpc.rpc("thread/list", { limit: 200, sortKey: "updated_at", sortDirection: "desc", useStateDbOnly: true, archived: showArchived });
      setThreads((result.data || []).map(parseThread).filter(Boolean));
    } catch {}
  }

  async function setArchivedMode(showArchived: boolean) {
    if (archivedView === showArchived) return;
    setArchivedView(showArchived);
    setSelectedThreadId(undefined);
    selectedRef.current = undefined;
    setMessages([]);
    messagesRef.current = [];
    setTurns({});
    setThreads([]);
    try {
      const result = await rpc.rpc("thread/list", { limit: 200, sortKey: "updated_at", sortDirection: "desc", useStateDbOnly: true, archived: showArchived });
      const nextThreads = (result.data || []).map(parseThread).filter(Boolean) as ThreadSummary[];
      setThreads(nextThreads);
      if (nextThreads[0]) await selectThread(nextThreads[0].id, showArchived);
    } catch (reason) { setError(errorText(reason)); }
  }

  function toggleThreadPin(threadId: string) {
    setPinnedThreadIds((current) => {
      const next = new Set(current);
      if (next.has(threadId)) next.delete(threadId); else next.add(threadId);
      localStorage.setItem(pinnedThreadsKey(activeProfileId), JSON.stringify([...next]));
      return next;
    });
  }

  async function renameThread() {
    if (!renamingThread) return;
    const name = renameDraft.trim();
    if (!name) return;
    try {
      await rpc.rpc("thread/name/set", { threadId: renamingThread.id, name });
      setThreads((current) => current.map((thread) => thread.id === renamingThread.id ? { ...thread, title: name } : thread));
      setRenamingThread(undefined);
    } catch (reason) { setError(errorText(reason)); }
  }

  async function archiveThread(threadId: string) {
    if (isTaskRunning(taskStates[threadId])) { setError("请先停止正在运行的任务。"); return; }
    try {
      await rpc.rpc("thread/archive", { threadId });
      removeThreadFromCurrentList(threadId);
    } catch (reason) { setError(errorText(reason)); }
  }

  async function unarchiveThread(threadId: string) {
    try {
      await rpc.rpc("thread/unarchive", { threadId });
      removeThreadFromCurrentList(threadId);
    } catch (reason) { setError(errorText(reason)); }
  }

  function removeThreadFromCurrentList(threadId: string) {
    setThreads((current) => {
      const next = current.filter((thread) => thread.id !== threadId);
      if (selectedRef.current === threadId) {
        selectedRef.current = undefined;
        setSelectedThreadId(undefined);
        setMessages([]);
        messagesRef.current = [];
        setTurns({});
        if (next[0]) void selectThread(next[0].id);
      }
      return next;
    });
    setPinnedThreadIds((current) => {
      if (!current.has(threadId)) return current;
      const next = new Set(current); next.delete(threadId);
      localStorage.setItem(pinnedThreadsKey(activeProfileId), JSON.stringify([...next]));
      return next;
    });
  }

  async function selectThread(id: string, readingArchived = archivedView) {
    flushPendingDeltas();
    const previous = selectedRef.current;
    if (previous && previous !== id) threadMessageCacheRef.current.set(previous, messagesRef.current);
    selectedRef.current = id;
    setSelectedThreadId(id);
    localStorage.setItem("relay.desktop.thread", id);
    setLoadingThread(true);
    setOlderTurnsCursor(undefined);
    const cachedMessages = threadMessageCacheRef.current.get(id) || [];
    setMessages(cachedMessages);
    messagesRef.current = cachedMessages;
    setTurns({});
    updateTaskState(id, { type: "reset" });
    try {
      if (previous && previous !== id) void rpc.rpc("relay/thread/session/unsubscribe", { threadId: previous }, 5_000).catch(() => {});
      const conversationPromise = readingArchived
        ? await Promise.all([
            rpc.rpc("thread/read", { threadId: id, includeTurns: false }, 30_000),
            rpc.rpc("thread/turns/list", { threadId: id, limit: 12, sortDirection: "desc", itemsView: "full" }, 120_000),
          ]).then(([summary, page]) => ({ ...summary, initialTurnsPage: page }))
        : rpc.rpc("thread/resume", {
            threadId: id,
            excludeTurns: true,
            initialTurnsPage: { limit: 12, sortDirection: "desc", itemsView: "full" },
          }, 30_000);
      const [result, goalResult] = await Promise.all([
        conversationPromise,
        rpc.rpc("relay/thread/goal", { threadId: id }, 8_000).catch(() => ({ goal: null })),
      ]);
      if (selectedRef.current !== id) return;
      setGoalState(id, goalResult.goal);
      const page = result.initialTurnsPage?.data || [];
      setOlderTurnsCursor(result.initialTurnsPage?.nextCursor || undefined);
      const rawTurns = page.length ? [...page].reverse() : result.thread?.turns || [];
      const loadedMessages: TranscriptItem[] = [];
      const loadedTurns: Record<string, TurnMetadata> = {};
      for (const rawTurn of rawTurns) {
        const metadata = parseTurn(rawTurn);
        if (!metadata) continue;
        loadedTurns[metadata.id] = metadata;
        for (const rawItem of rawTurn.items || []) {
          const item = parseItem(rawItem, metadata.id);
          if (item) loadedMessages.push(item);
        }
      }
      const active = [...rawTurns].reverse().find((turn: any) => isRunningStatus(turn.status));
      const threadActive = isRunningStatus(result.thread?.status?.type || result.thread?.status);
      const nextActiveTurnId = active?.id || (threadActive ? rawTurns.at(-1)?.id : undefined);
      const loadedIds = new Set(loadedMessages.map((item) => item.id));
      for (const item of cachedMessages) {
        const placement = userMessagePlacementsRef.current.get(item.id);
        if (placement?.threadId === id && !loadedIds.has(item.id)) loadedMessages.push(item);
      }
      const orderedMessages = nextActiveTurnId
        ? applyUserMessagePlacements(loadedMessages, userMessagePlacementsRef.current.values(), id, nextActiveTurnId)
        : loadedMessages;
      setMessages(orderedMessages);
      messagesRef.current = orderedMessages;
      threadMessageCacheRef.current.set(id, orderedMessages);
      setTurns(loadedTurns);
      updateTaskState(id, {
        type: "hydrate",
        running: Boolean(nextActiveTurnId) || threadActive,
        turnId: nextActiveTurnId,
        startedAt: nextActiveTurnId ? loadedTurns[nextActiveTurnId]?.startedAt : undefined,
      });
      if (result.model) setSelectedModel(result.model);
      if (result.reasoningEffort) setEffort(result.reasoningEffort);
      if (!readingArchived) try {
        const snapshot = await rpc.rpc("relay/thread/session/subscribe", { threadId: id, incremental: true }, 12_000);
        if (selectedRef.current === id) handleSessionSnapshot(id, snapshot);
      } catch {}
    } catch (reason) { setError(errorText(reason)); }
    finally { if (selectedRef.current === id) setLoadingThread(false); }
  }

  async function refreshGoal(threadId: string) {
    try {
      const result = await rpc.rpc("relay/thread/goal", { threadId }, 8_000);
      setGoalState(threadId, result.goal);
    } catch {}
  }

  function setGoalState(threadId: string, goal: GoalState | null | undefined) {
    setGoals((current) => {
      if (goal) return { ...current, [threadId]: goal };
      if (!(threadId in current)) return current;
      const next = { ...current };
      delete next[threadId];
      return next;
    });
  }

  async function loadOlderTurns() {
    const threadId = selectedRef.current;
    const cursor = olderTurnsCursor;
    if (!threadId || !cursor || loadingOlderTurns) return;
    setLoadingOlderTurns(true);
    const scroll = scrollRef.current;
    const previousHeight = scroll?.scrollHeight || 0;
    try {
      const result = await rpc.rpc("thread/turns/list", {
        threadId,
        cursor,
        limit: 12,
        sortDirection: "desc",
        itemsView: "full",
      }, 120_000);
      if (selectedRef.current !== threadId) return;
      const page = [...(result.data || [])].reverse();
      const olderMessages: TranscriptItem[] = [];
      const olderTurns: Record<string, TurnMetadata> = {};
      for (const rawTurn of page) {
        const metadata = parseTurn(rawTurn);
        if (!metadata) continue;
        olderTurns[metadata.id] = metadata;
        for (const rawItem of rawTurn.items || []) {
          const item = parseItem(rawItem, metadata.id);
          if (item) olderMessages.push(item);
        }
      }
      setTurns((current) => ({ ...olderTurns, ...current }));
      setMessages((current) => {
        const existingIds = new Set(current.map((item) => item.id));
        const next = [...olderMessages.filter((item) => !existingIds.has(item.id)), ...current];
        messagesRef.current = next;
        threadMessageCacheRef.current.set(threadId, next);
        return next;
      });
      setOlderTurnsCursor(result.nextCursor || undefined);
      requestAnimationFrame(() => {
        if (scroll) scroll.scrollTop += scroll.scrollHeight - previousHeight;
      });
    } catch (reason) {
      setError(`加载更早对话失败：${errorText(reason)}`);
    } finally {
      setLoadingOlderTurns(false);
    }
  }

  function handleSessionSnapshot(threadId: string, snapshot: any, recordPerformance = true) {
    if (selectedRef.current !== threadId || !snapshot?.known || !snapshot.turnId) return;
    const startedAt = performance.now();
    let performanceRecorded = false;
    const recordSnapshot = () => {
      if (!recordPerformance || performanceRecorded) return;
      performanceRecorded = true;
      performanceMetricsRef.current.recordSessionSnapshot(performance.now() - startedAt);
    };
    flushPendingDeltas();
    sessionRevisionRef.current.reset(threadId, Number(snapshot.revision || 0));
    const live = snapshot.isRunning === true && snapshot.stale !== true;
    if (live) bindPendingStartMessage(snapshot.turnId);
    const snapshotItems = (snapshot.items || []).map((value: any) => parseItem(value, snapshot.turnId)).filter(Boolean) as TranscriptItem[];
    if (snapshotItems.length) setMessages((current) => {
      const next = applyUserMessagePlacements(
        mergeSnapshot(current, snapshotItems, snapshot.turnId),
        userMessagePlacementsRef.current.values(),
        threadId,
        snapshot.turnId,
      );
      recordSnapshot();
      return next;
    });
    setTurns((current) => ({
      ...current,
      [snapshot.turnId]: {
        ...(current[snapshot.turnId] || { id: snapshot.turnId }), id: snapshot.turnId,
        status: live ? "inProgress" : snapshot.stale ? "interrupted" : "completed",
        startedAt: snapshot.startedAt || current[snapshot.turnId]?.startedAt,
        completedAt: live ? undefined : snapshot.completedAt || current[snapshot.turnId]?.completedAt,
        durationMs: live || snapshot.stale ? undefined : current[snapshot.turnId]?.durationMs,
      },
    }));
    if (live) updateTaskState(threadId, { type: "progress", turnId: snapshot.turnId, startedAt: snapshot.startedAt });
    else {
      updateTaskState(threadId, {
        type: "terminal",
        turnId: snapshot.turnId,
        phase: snapshot.stale ? "interrupted" : "completed",
        completedAt: snapshot.completedAt,
      });
      if (snapshot.stale) {
        setThreads((current) => current.map((thread) => thread.id === threadId ? { ...thread, status: "idle" } : thread));
      }
    }
    if (!snapshotItems.length) recordSnapshot();
  }

  function handleSessionPatch(threadId: string, patch: any) {
    if (selectedRef.current !== threadId || !patch?.known || !patch.turnId) return;
    if (!sessionRevisionRef.current.acceptPatch(threadId, Number(patch.baseRevision), Number(patch.revision))) {
      performanceMetricsRef.current.recordRevisionGap();
      void recoverSessionSubscription(threadId);
      return;
    }
    const startedAt = performance.now();
    let performanceRecorded = false;
    const recordPatch = () => {
      if (performanceRecorded) return;
      performanceRecorded = true;
      performanceMetricsRef.current.recordSessionPatch(performance.now() - startedAt);
    };
    flushPendingDeltas();
    const upserts = (patch.upsertItems || [])
      .map((value: any) => parseItem(value, patch.turnId))
      .filter(Boolean) as TranscriptItem[];
    if (upserts.length || patch.removedItemIds?.length) {
      setMessages((current) => {
        const next = applyUserMessagePlacements(
          mergeSessionPatch(current, upserts, patch.removedItemIds || [], patch.turnId),
          userMessagePlacementsRef.current.values(),
          threadId,
          patch.turnId,
        );
        recordPatch();
        return next;
      });
    }
    handleSessionSnapshot(threadId, { ...patch, items: [], revision: patch.revision }, false);
    if (!upserts.length && !patch.removedItemIds?.length) recordPatch();
  }

  async function recoverSessionSubscription(threadId: string) {
    if (recoveringSessionRef.current.has(threadId)) return;
    performanceMetricsRef.current.recordRecovery();
    recoveringSessionRef.current.add(threadId);
    try {
      const snapshot = await rpc.rpc("relay/thread/session/subscribe", { threadId, incremental: true }, 12_000);
      if (selectedRef.current === threadId) handleSessionSnapshot(threadId, snapshot);
    } catch {}
    finally { recoveringSessionRef.current.delete(threadId); }
  }

  function handleEvent(method: string, params: any) {
    const threadId = params.threadId;
    const turnId = params.turnId || params.turn?.id;
    const terminal = ["turn/completed", "turn/aborted", "turn/interrupted", "turn/failed"].includes(method);
    if (method === "thread/name/updated" && threadId) {
      setThreads((current) => current.map((thread) => thread.id === threadId ? { ...thread, title: params.name || thread.title } : thread));
    }
    if ((method === "thread/archived" && !archivedView) || (method === "thread/unarchived" && archivedView) || method === "thread/deleted") {
      if (threadId) removeThreadFromCurrentList(threadId);
      return;
    }
    if (threadId) {
      setThreads((current) => current.map((thread) => thread.id === threadId
        ? { ...thread, status: terminal ? "idle" : method.startsWith("turn/") || method.startsWith("item/") ? "active" : thread.status, updatedAt: Date.now() / 1000 }
        : thread));
      const transition = decodeTaskRunEvents(method, params, threadId);
      for (const event of transition.events) updateTaskState(threadId, event);
      if (terminal) {
        if (turnId && !notifiedTurnIdsRef.current.has(turnId)) {
          notifiedTurnIdsRef.current.add(turnId);
          const taskTitle = threads.find((thread) => thread.id === threadId)?.title || "Codex 任务";
          void window.relayDesktop.notify({ title: method === "turn/failed" ? "任务执行失败" : "任务已完成", body: taskTitle });
        }
        void refreshGoal(threadId);
      }
    }
    if (threadId !== selectedRef.current) return;
    if (turnId && (method === "turn/started" || method.startsWith("item/") || method === "turn/plan/updated")) {
      bindPendingStartMessage(turnId);
    }
    if (method === "turn/started") {
      const metadata: TurnMetadata = parseTurn(params.turn) || { id: String(turnId || ""), status: "inProgress" };
      if (turnId) {
        setTurns((current) => ({ ...current, [turnId]: { ...metadata, status: "inProgress", startedAt: metadata.startedAt || Date.now() / 1000 } }));
      }
      return;
    }
    if (method === "thread/compacted" && turnId) {
      setMessages((current) => applyContextCompaction(current, turnId));
      return;
    }
    if (terminal) {
      flushPendingDeltas();
      if (turnId) {
        const metadata: TurnMetadata = parseTurn(params.turn || { id: turnId }) || { id: String(turnId), status: "completed" };
        const status = method.includes("failed") ? "failed" : method.includes("abort") || method.includes("interrupt") ? "interrupted" : metadata.status;
        setTurns((current) => ({ ...current, [turnId]: { ...current[turnId], ...metadata, status, completedAt: metadata.completedAt || Date.now() / 1000 } }));
        for (const rawItem of params.turn?.items || []) {
          const item = parseItem(rawItem, turnId);
          if (item) setMessages((current) => upsert(current, item));
        }
      }
      void refreshThreads();
      return;
    }
    if (method === "item/started" || method === "item/completed") {
      flushPendingDeltas();
      const item = parseItem(params.item, turnId);
      if (item) setMessages((current) => upsert(current, item));
      return;
    }
    if (method === "item/agentMessage/delta") appendText(params.itemId, params.delta, turnId, "assistant");
    else if (method === "item/reasoning/summaryTextDelta" || method === "item/reasoningSummaryText/delta") appendText(params.itemId, params.delta, turnId, "reasoning");
    else if (method === "item/reasoning/textDelta") appendDetail(params.itemId, params.delta, turnId, "reasoning");
    else if (method === "item/commandExecution/outputDelta") appendDetail(params.itemId, params.delta, turnId, "command");
    else if (method === "error") {
      const message = params.error?.message || params.message || "Codex 出错";
      if (params.willRetry !== true) {
        setError(message);
      }
    }
  }

  function appendText(id: string, delta: string, turnId: string, kind: "assistant" | "reasoning") {
    if (!id || !delta) return;
    queueDelta(id, turnId, kind, delta, "");
  }

  function appendDetail(id: string, delta: string, turnId: string, kind: "reasoning" | "command") {
    if (!id || !delta) return;
    queueDelta(id, turnId, kind, "", delta);
  }

  function queueDelta(id: string, turnId: string, kind: "assistant" | "reasoning" | "command", text: string, detail: string) {
    performanceMetricsRef.current.recordQueuedDelta();
    const existing = pendingDeltaRef.current.get(id);
    if (existing) {
      if (!existing.turnId) existing.turnId = turnId;
      if (text) existing.textChunks.push(text);
      if (detail) existing.detailChunks.push(detail);
    } else {
      pendingDeltaRef.current.set(id, {
        id, turnId, kind,
        textChunks: text ? [text] : [],
        detailChunks: detail ? [detail] : [],
      });
    }
    if (deltaFrameRef.current === undefined) deltaFrameRef.current = requestAnimationFrame(flushPendingDeltas);
  }

  function flushPendingDeltas() {
    if (deltaFrameRef.current !== undefined) cancelAnimationFrame(deltaFrameRef.current);
    deltaFrameRef.current = undefined;
    if (!pendingDeltaRef.current.size) return;
    const pending = [...pendingDeltaRef.current.values()].map((value) => ({
      id: value.id,
      turnId: value.turnId,
      kind: value.kind,
      text: value.textChunks.join(""),
      detail: value.detailChunks.join(""),
    }));
    const startedAt = performance.now();
    let performanceRecorded = false;
    pendingDeltaRef.current.clear();
    setMessages((current) => {
      const next = applyDeltaBatch(current, pending);
      if (!performanceRecorded) {
        performanceRecorded = true;
        performanceMetricsRef.current.recordFrameFlush(pending.length, performance.now() - startedAt);
      }
      return next;
    });
  }

  async function createThread(cwd = workspace) {
    if (archivedView) setArchivedView(false);
    const threadAccess = accessForWorkspace(cwd, defaultAccess, projectAccesses);
    const result = await rpc.rpc("thread/start", {
      cwd: cwd || undefined,
      approvalPolicy: "on-request",
      sandbox: threadAccess === "fullAccess" ? "danger-full-access" : threadAccess === "readOnly" ? "read-only" : "workspace-write",
      threadSource: "relay-desktop",
      model: selectedModel || undefined,
    });
    const id = result.thread?.id;
    if (!id) throw new Error("Codex 未返回对话编号");
    if (cwd) { setWorkspace(cwd); setNewTaskCwd(cwd); }
    await refreshThreads();
    setSelectedThreadId(id); selectedRef.current = id; setMessages([]); setTurns({}); updateTaskState(id, { type: "reset" });
    localStorage.setItem("relay.desktop.thread", id);
    return id as string;
  }

  async function submit() {
    const text = composer.trim();
    if (!text && !attachments.length) {
      if (running) await stopTurn();
      return;
    }
    if (connection !== "connected" || sending) return;
    setSending(true); setComposer("");
    const selectedAttachments = attachments; setAttachments([]);
    let submittedMessageId: string | undefined;
    try {
      const threadId = selectedRef.current || await createThread(workspace);
      const clientId = crypto.randomUUID();
      submittedMessageId = clientId;
      const currentTurnId = activeTurnRef.current;
      const input = [
        ...(text ? [{ type: "text", text }] : []),
        ...selectedAttachments.map((item) => item.isImage
          ? { type: "localImage", path: item.path }
          : { type: "mention", name: item.name, path: item.path }),
      ];
      if (currentTurnId && followUpBehavior === "queue") {
        const result = await rpc.rpc("relay/prompt/queue/add", {
          threadId,
          clientUserMessageId: clientId,
          text,
          input,
          sandboxPolicy: sandboxPolicy(access, selectedThread?.cwd || workspace),
          model: selectedModelOption?.model || selectedModel || undefined,
          effort: effort || undefined,
        }, 12_000);
        if (result.item) {
          setQueuedPrompts((current) => [...current.filter((item) => item.id !== result.item.id), result.item]
            .sort((left, right) => left.createdAt - right.createdAt));
        }
        return;
      }
      const afterItemId = currentTurnId
        ? [...messagesRef.current].reverse().find((item) => item.turnId === currentTurnId)?.id
        : undefined;
      userMessagePlacementsRef.current.set(clientId, {
        messageId: clientId,
        threadId,
        turnId: currentTurnId,
        afterItemId,
        sequence: ++placementSequenceRef.current,
      });
      const imagePaths = selectedAttachments.filter((item) => item.isImage).map((item) => item.path);
      const display = [text, ...selectedAttachments.filter((item) => !item.isImage).map((item) => `附件 ${item.name}`)].filter(Boolean).join("\n\n");
      setMessages((current) => [...current, { id: clientId, kind: "user", text: display, imagePaths }]);
      if (!activeTurnRef.current) pendingStartMessageRef.current = clientId;
      if (activeTurnRef.current) {
        const result = await rpc.rpc("turn/steer", { threadId, expectedTurnId: activeTurnRef.current, clientUserMessageId: clientId, input }, 120_000);
        const confirmed = result.turnId || activeTurnRef.current;
        const placement = userMessagePlacementsRef.current.get(clientId);
        if (placement && confirmed) userMessagePlacementsRef.current.set(clientId, { ...placement, turnId: confirmed });
        setMessages((current) => current.map((item) => item.id === clientId ? { ...item, turnId: confirmed } : item));
      } else {
        updateTaskState(threadId, { type: "starting" });
        const result = await rpc.rpc("turn/start", {
          threadId, clientUserMessageId: clientId, input, summary: "detailed",
          sandboxPolicy: sandboxPolicy(access, selectedThread?.cwd || workspace),
          model: selectedModelOption?.model || selectedModel || undefined,
          effort: effort || undefined,
        }, 120_000);
        const confirmed = result.turn?.id;
        if (confirmed) {
          updateTaskState(threadId, { type: "started", turnId: confirmed, startedAt: result.turn?.startedAt });
          bindPendingStartMessage(confirmed);
        }
      }
    } catch (reason) {
      const failedThreadId = selectedRef.current;
      if (failedThreadId) {
        setTaskCore((current) => current.states[failedThreadId]?.phase === "starting"
          ? reduceTaskStateCore(current, failedThreadId, { type: "terminal", phase: "failed" })
          : current);
      }
      if (submittedMessageId) userMessagePlacementsRef.current.delete(submittedMessageId);
      if (pendingStartMessageRef.current) {
        pendingStartMessageRef.current = undefined;
      }
      setComposer(text); setAttachments(selectedAttachments); setError(errorText(reason));
    }
    finally { setSending(false); }
  }

  function bindPendingStartMessage(turnId: string) {
    const messageId = pendingStartMessageRef.current;
    if (!messageId) return;
    pendingStartMessageRef.current = undefined;
    const placement = userMessagePlacementsRef.current.get(messageId);
    if (placement) userMessagePlacementsRef.current.set(messageId, { ...placement, turnId });
    setMessages((current) => applyUserMessagePlacements(
      bindUserPrompt(current, messageId, turnId),
      userMessagePlacementsRef.current.values(),
      selectedRef.current || placement?.threadId || "",
      turnId,
    ));
  }

  async function stopTurn() {
    const threadId = selectedRef.current;
    const turnId = activeTurnRef.current;
    if (!threadId || !turnId) return;
    try { await rpc.rpc("turn/interrupt", { threadId, turnId }, 20_000); updateTaskState(threadId, { type: "terminal", turnId, phase: "interrupted" }); }
    catch (reason) { setError(errorText(reason)); }
  }

  async function removeQueuedPrompt(id: string) {
    try {
      await rpc.rpc("relay/prompt/queue/remove", { id }, 12_000);
      setQueuedPrompts((current) => current.filter((item) => item.id !== id));
    } catch (reason) { setError(errorText(reason)); }
  }

  async function pickFiles() {
    const paths = await window.relayDesktop.pickFiles();
    setAttachments((current) => [...current, ...paths.map((path) => {
      const name = path.split(/[\\/]/).at(-1) || path;
      return { path, name, isImage: imageExtensions.has(name.split(".").at(-1)?.toLowerCase() || "") };
    })]);
  }

  async function resolveApproval(accepted: boolean) {
    if (!approval) return;
    try {
      let result: Record<string, unknown>;
      if (approval.method === "mcpServer/elicitation/request") result = { action: accepted ? "accept" : "decline", content: accepted ? {} : null };
      else if (/permissions/i.test(approval.method)) result = { permissions: accepted ? approval.params.permissions || {} : {}, scope: "turn" };
      else result = { decision: accepted ? "accept" : "decline" };
      await rpc.respond(approval.id, result);
      setApprovals((current) => current.filter((item) => String(item.id) !== String(approval.id)));
    } catch (reason) { setError(errorText(reason)); }
  }

  async function saveConnection() {
    try { await window.relayDesktop.connect(config); setSettingsOpen(false); }
    catch (reason) { setError(errorText(reason)); }
  }

  async function refreshDiagnostics() {
    setDiagnosticsLoading(true);
    try {
      const report = await rpc.rpc("relay/diagnostics/report", {}, 12_000) as DiagnosticReport;
      setDiagnostics({ ...report, clientPerformance: performanceMetricsRef.current.report() });
    } catch (reason) {
      setError(errorText(reason));
    } finally {
      setDiagnosticsLoading(false);
    }
  }

  function openDiagnostics() {
    setDiagnosticsOpen(true);
    void refreshDiagnostics();
  }

  async function updatePreferences(patch: Partial<DesktopPreferences>) {
    try { setPreferences(await window.relayDesktop.setPreferences(patch)); }
    catch (reason) { setError(errorText(reason)); }
  }

  async function checkDesktopUpdate() {
    try { setUpdate(await window.relayDesktop.checkUpdate()); }
    catch (reason) { setError(errorText(reason)); }
  }

  async function applyDesktopUpdate() {
    try {
      if (update.state === "ready" || update.state === "deferred") setUpdate(await window.relayDesktop.installUpdate());
      else setUpdate(await window.relayDesktop.downloadUpdate());
    } catch (reason) { setError(errorText(reason)); }
  }

  const serviceAvailable = service.state === "running" || service.state === "starting" || service.state === "degraded";
  const connectionLabel = !serviceAvailable ? "远程服务未启动" : profileSwitching ? "正在切换实例" : upstreamRetrying ? "Codex 上游服务正在重试" : connection === "connected" ? "实时同步" : connection === "reconnecting" ? `正在重新连接 Windows · ${connectionAttempt}` : connection === "handshaking" ? "正在初始化" : "未连接";

  return (
    <div className="app-shell">
      <div className="titlebar"><div className="brand-dot"/><span>Relay Desktop</span><span className="titlebar-thread">{selectedThread?.title || "Codex 实时工作台"}</span></div>
      <div className={`workspace-shell ${sidebarOpen ? "sidebar-visible" : ""}`}>
        <aside className="sidebar">
          <div className="sidebar-actions">
            {service.state === "running"
              ? <button className="primary-action" onClick={() => { setNewTaskCwd(workspace); setNewTaskOpen(true); }}><SquarePen size={15}/><span>新任务</span></button>
              : <button className="primary-action service-action" disabled={service.state === "starting"} onClick={() => void startRemoteService()}>{service.state === "starting" ? <span className="spinner small"/> : <Power size={15}/>}<span>{service.state === "starting" ? "正在启动" : "启动远程服务"}</span></button>}
          </div>
          <div className="sidebar-search"><Search size={13}/><input aria-label="搜索对话" value={threadSearch} onChange={(event) => setThreadSearch(event.target.value)} placeholder="搜索对话"/>{threadSearch && <button className="icon-button" title="清除搜索" onClick={() => setThreadSearch("")}><X size={12}/></button>}</div>
          <div className="project-list">
            {projects.map((project) => <ProjectGroup
              key={project.path}
              project={project}
              selectedId={selectedThreadId}
              approvalThreadIds={approvalThreadIds}
              pinnedThreadIds={pinnedThreadIds}
              archived={archivedView}
              onSelect={selectThread}
              onTogglePin={toggleThreadPin}
              onRename={(thread) => { setRenamingThread(thread); setRenameDraft(thread.title); }}
              onArchive={archiveThread}
              onUnarchive={unarchiveThread}
            />) }
            {!projects.length && <div className="empty-sidebar">{threadSearch ? "没有匹配的对话" : "暂无对话"}</div>}
          </div>
          <button className={`archive-mode ${archivedView ? "active" : ""}`} onClick={() => void setArchivedMode(!archivedView)}>
            {archivedView ? <RotateCcw size={13}/> : <Archive size={13}/>}
            <span>{archivedView ? "返回当前任务" : "已归档任务"}</span>
            <ChevronRight size={12}/>
          </button>
          <div className="sidebar-footer"><Server size={12}/><span>{activeCodexProfile?.name || "Codex"}</span><span className="version">v{version}</span></div>
        </aside>

        <main className="main-pane">
          <header className="thread-header">
            <button className="icon-button sidebar-toggle" onClick={() => setSidebarOpen((value) => !value)}><Menu size={18}/></button>
            <div className="thread-identity"><strong>{selectedThread?.title || (archivedView ? "已归档任务" : "新任务")}</strong><span>{archivedView ? "只读历史" : selectedThread?.cwd || workspace || "未指定工作目录"}</span></div>
            <button title="打开诊断中心" onClick={openDiagnostics} className={`live-badge ${serviceAvailable && upstreamRetrying ? "retrying" : serviceAvailable && connection === "connected" ? "connected" : "offline"}`}>
              {serviceAvailable && connection === "connected" ? <Wifi size={12}/> : <WifiOff size={12}/>}<span>{connectionLabel}</span>
            </button>
            <button className="icon-button" onClick={() => setSettingsOpen(true)}><Settings size={17}/></button>
          </header>

          <div className="transcript" ref={scrollRef} onScroll={(event) => {
            const element = event.currentTarget; setAtBottom(element.scrollHeight - element.scrollTop - element.clientHeight < 80);
          }}>
            <div className="transcript-inner">
              {!loadingThread && olderTurnsCursor && <button className="load-older" disabled={loadingOlderTurns} onClick={() => void loadOlderTurns()}>{loadingOlderTurns ? <span className="spinner small"/> : <ChevronDown size={13}/>}<span>{loadingOlderTurns ? "正在加载" : "加载更早对话"}</span></button>}
              {service.state !== "running"
                ? <ServiceState status={service} onStart={startRemoteService}/>
                : profileSwitching
                  ? <LoadingState label="正在切换 Codex 实例"/>
                  : loadingThread
                    ? <LoadingState/>
                    : messages.length
                      ? <Transcript items={messages} turns={turns} activeTurnId={activeTurnId}/>
                      : <EmptyState cwd={selectedThread?.cwd || workspace}/>
              }
              <div ref={transcriptEndRef}/>
            </div>
          </div>
          {!atBottom && <button className="jump-bottom" onClick={() => { setAtBottom(true); transcriptEndRef.current?.scrollIntoView({ behavior: "smooth" }); }}><ArrowDown size={16}/></button>}

          {archivedView ? <div className="archived-bar"><Archive size={14}/><span>此任务已归档，仅供查看</span>{selectedThreadId && <button onClick={() => void unarchiveThread(selectedThreadId)}><RotateCcw size={13}/>恢复任务</button>}</div> : <div className="composer-zone">
            {plan.length > 0 && <PlanPanel steps={plan}/>
            }
            {currentQueuedPrompts.length > 0 && <PromptQueuePanel items={currentQueuedPrompts} onRemove={removeQueuedPrompt}/>
            }
            {currentGoal && currentGoal.status !== "complete" && <GoalPanel goal={currentGoal} running={running}/>
            }
            <div className={`composer ${!serviceAvailable || connection !== "connected" ? "offline" : ""}`}>
              {attachments.length > 0 && <div className="attachments">{attachments.map((item) => <span key={item.path}><FileCode2 size={12}/>{item.name}<button onClick={() => setAttachments((current) => current.filter((value) => value.path !== item.path))}><X size={11}/></button></span>)}</div>}
              <textarea disabled={!serviceAvailable || connection !== "connected"} value={composer} onChange={(event) => setComposer(event.target.value)} placeholder={!serviceAvailable ? "启动远程服务后开始" : running ? followUpBehavior === "queue" ? "排队到下一轮" : "引导当前任务" : "随心输入"} rows={1} onKeyDown={(event) => {
                if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); void submit(); }
              }}/>
              <div className="composer-controls">
                <button disabled={!serviceAvailable || connection !== "connected"} className="icon-button attach" onClick={() => void pickFiles()} title="添加文件"><Paperclip size={17}/></button>
                <div className="generation-controls">
                  {running && <select aria-label="后续消息方式" value={followUpBehavior} onChange={(event) => setFollowUpBehavior(event.target.value as "steer" | "queue")}><option value="steer">引导</option><option value="queue">排队</option></select>}
                  <select disabled={!serviceAvailable || connection !== "connected"} value={selectedModel} onChange={(event) => { setSelectedModel(event.target.value); const model = models.find((item) => item.model === event.target.value); if (model && !model.efforts.includes(effort)) setEffort(model.defaultEffort); }}>
                    {models.map((model) => <option key={model.id} value={model.model}>{model.displayName}</option>)}
                  </select>
                  <select disabled={!serviceAvailable || connection !== "connected"} value={effort} onChange={(event) => setEffort(event.target.value)}>{(selectedModelOption?.efforts.length ? selectedModelOption.efforts : ["low", "medium", "high", "xhigh"]).map((value) => <option key={value} value={value}>{effortName(value)}</option>)}</select>
                  <button className={`send-button ${running && !composer.trim() && !attachments.length ? "stop" : ""}`} onClick={() => void submit()} disabled={sending || connection !== "connected"}>
                    {running && !composer.trim() && !attachments.length
                      ? <CircleStop size={18}/>
                      : <ArrowUp size={18}/>
                    }
                  </button>
                </div>
              </div>
            </div>
          </div>}
        </main>
      </div>

      {settingsOpen && <SettingsPanel config={config} setConfig={setConfig} workspace={workspace} setWorkspace={setWorkspace} access={access} setAccess={setAccess} profiles={codexProfiles} activeProfileId={activeProfileId} switching={profileSwitching} switchDisabled={running || Boolean(approval)} onSwitch={switchCodexProfile} onStartService={startRemoteService} service={service} preferences={preferences} update={update} onPreferences={updatePreferences} onCheckUpdate={checkDesktopUpdate} onApplyUpdate={applyDesktopUpdate} onDiagnostics={openDiagnostics} onClose={() => setSettingsOpen(false)} onSave={saveConnection}/>
      }
      {newTaskOpen && <Modal title="新建任务" onClose={() => setNewTaskOpen(false)}><label className="field"><span>工作目录</span><input value={newTaskCwd} onChange={(event) => setNewTaskCwd(event.target.value)} placeholder="C:\\项目目录"/></label><div className="modal-actions"><button onClick={() => setNewTaskOpen(false)}>取消</button><button className="accent" onClick={() => { void createThread(newTaskCwd).then(() => setNewTaskOpen(false)).catch((reason) => setError(errorText(reason))); }}>创建</button></div></Modal>}
      {renamingThread && <Modal title="重命名任务" onClose={() => setRenamingThread(undefined)}><label className="field"><span>任务名称</span><input autoFocus value={renameDraft} onChange={(event) => setRenameDraft(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") void renameThread(); }}/></label><div className="modal-actions"><button onClick={() => setRenamingThread(undefined)}>取消</button><button className="accent" disabled={!renameDraft.trim()} onClick={() => void renameThread()}>保存</button></div></Modal>}
      {approval && <Modal title={approval.title} closable={false} onClose={() => {}}>{approvalQueue.length > 1 && <div className="approval-queue-count">当前任务审批 1 / {approvalQueue.length}</div>}{approval.threadId && <div className="approval-task">{threads.find((thread) => thread.id === approval.threadId)?.title || approval.threadId}</div>}<p className="approval-summary">{approval.summary}</p>{approval.detail && <pre className="approval-detail">{approval.detail}</pre>}<div className="modal-actions"><button onClick={() => void resolveApproval(false)}>拒绝</button><button className="accent" onClick={() => void resolveApproval(true)}>允许</button></div></Modal>}
      {diagnosticsOpen && <DiagnosticsPanel report={diagnostics} loading={diagnosticsLoading} onRefresh={refreshDiagnostics} onClose={() => setDiagnosticsOpen(false)}/>}
      {error && <div className="toast"><AlertCircle size={16}/><span>{error}</span><button onClick={() => setError(undefined)}><X size={14}/></button></div>}
    </div>
  );
}

function ProjectGroup({ project, selectedId, approvalThreadIds, pinnedThreadIds, archived, onSelect, onTogglePin, onRename, onArchive, onUnarchive }: {
  project: ReturnType<typeof groupProjects>[number]; selectedId?: string; approvalThreadIds: Set<string>; pinnedThreadIds: Set<string>; archived: boolean;
  onSelect: (id: string) => Promise<void>; onTogglePin: (id: string) => void; onRename: (thread: ThreadSummary) => void;
  onArchive: (id: string) => Promise<void>; onUnarchive: (id: string) => Promise<void>;
}) {
  const [open, setOpen] = useState(true);
  return <section className="project-group"><button className="project-heading" onClick={() => setOpen((value) => !value)}>{open ? <ChevronDown size={13}/> : <ChevronRight size={13}/>}<Folder size={14}/><span>{project.name}</span><small>{project.threads.length}</small></button>{open && <div className="thread-list">{project.threads.map((thread) => <ThreadRow key={thread.id} thread={thread} selected={selectedId === thread.id} needsApproval={approvalThreadIds.has(thread.id)} pinned={pinnedThreadIds.has(thread.id)} archived={archived} onSelect={onSelect} onTogglePin={onTogglePin} onRename={onRename} onArchive={onArchive} onUnarchive={onUnarchive}/>)}</div>}</section>;
}

function ThreadRow({ thread, selected, needsApproval, pinned, archived, onSelect, onTogglePin, onRename, onArchive, onUnarchive }: {
  thread: ThreadSummary; selected: boolean; needsApproval: boolean; pinned: boolean; archived: boolean;
  onSelect: (id: string) => Promise<void>; onTogglePin: (id: string) => void; onRename: (thread: ThreadSummary) => void;
  onArchive: (id: string) => Promise<void>; onUnarchive: (id: string) => Promise<void>;
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  return <div className={`thread-row-shell ${selected ? "selected" : ""}`}>
    <button className="thread-row" onClick={() => void onSelect(thread.id)}>
      {needsApproval ? <AlertCircle className="thread-approval" size={12}/> : <span className={`thread-running ${isRunningStatus(thread.status) ? "active" : ""}`}/>}
      <span className="thread-copy">{pinned && <Pin size={10}/>}<strong>{thread.title}</strong><small>{relativeTime(thread.updatedAt)}</small></span>
    </button>
    <button className="thread-menu-trigger" title="任务操作" onClick={() => setMenuOpen((value) => !value)}><MoreHorizontal size={14}/></button>
    {menuOpen && <div className="thread-menu" onMouseLeave={() => setMenuOpen(false)}>
      {!archived ? <>
        <button onClick={() => { onTogglePin(thread.id); setMenuOpen(false); }}>{pinned ? <PinOff size={13}/> : <Pin size={13}/>}<span>{pinned ? "取消置顶" : "置顶"}</span></button>
        <button onClick={() => { onRename(thread); setMenuOpen(false); }}><Pencil size={13}/><span>重命名</span></button>
        <button className="danger" onClick={() => { setMenuOpen(false); void onArchive(thread.id); }}><Archive size={13}/><span>归档</span></button>
      </> : <button onClick={() => { setMenuOpen(false); void onUnarchive(thread.id); }}><RotateCcw size={13}/><span>恢复任务</span></button>}
    </div>}
  </div>;
}

function Transcript({ items, turns, activeTurnId }: { items: TranscriptItem[]; turns: Record<string, TurnMetadata>; activeTurnId?: string }) {
  const groups: { id: string; items: TranscriptItem[] }[] = [];
  const indexes = new Map<string, number>();
  for (const item of items) {
    const key = item.turnId ? `turn.${item.turnId}` : `item.${item.id}`;
    const index = indexes.get(key);
    if (index == null) { indexes.set(key, groups.length); groups.push({ id: key, items: [item] }); }
    else groups[index].items.push(item);
  }
  return <>{groups.map((group) => <TurnBlock key={group.id} items={group.items} metadata={group.items[0]?.turnId ? turns[group.items[0].turnId!] : undefined} live={group.items[0]?.turnId === activeTurnId}/>)}</>;
}

function TurnBlock({ items, metadata, live }: { items: TranscriptItem[]; metadata?: TurnMetadata; live: boolean }) {
  const segments: ({ type: "item"; item: TranscriptItem } | { type: "activity"; id: string; items: TranscriptItem[] })[] = [];
  let activity: TranscriptItem[] = [];
  const flush = () => { if (activity.length) { segments.push({ type: "activity", id: activity[0].id, items: activity }); activity = []; } };
  for (const item of items) {
    const isActivity = item.kind === "reasoning" || item.kind === "command" || item.kind === "file" || item.kind === "tool" || item.kind === "plan" || item.kind === "compaction" || (item.kind === "assistant" && item.phase === "commentary");
    if (isActivity) activity.push(item); else { flush(); segments.push({ type: "item", item }); }
  }
  flush();
  if (live && !segments.some((segment) => segment.type === "activity")) segments.push({ type: "activity", id: "pending", items: [] });
  const firstActivityIndex = segments.findIndex((segment) => segment.type === "activity");
  const hasActivityContent = segments.some((segment) => segment.type === "activity" && segment.items.some((item) => item.kind !== "plan"));
  const [activityExpanded, setActivityExpanded] = useState(live || !metadata);
  useEffect(() => { setActivityExpanded(live || !metadata); }, [live, metadata]);
  return <div className="turn-block">{segments.map((segment, index) => segment.type === "activity" ? <ActivityBlock
    key={`${segment.id}.${index}`}
    items={segment.items}
    metadata={metadata}
    live={live}
    showHeader={Boolean(metadata) && index === firstActivityIndex}
    canExpand={hasActivityContent}
    expanded={activityExpanded}
    onToggle={() => setActivityExpanded((value) => !value)}
  /> : <MessageRow key={segment.item.id} item={segment.item}/>)}</div>;
}

function MessageRow({ item }: { item: TranscriptItem }) {
  if (item.kind === "user") return (item.text || item.imagePaths?.length) ? <div className="user-row"><div className="user-message">{Boolean(item.imagePaths?.length) && <div className={`user-images ${item.imagePaths!.length > 1 ? "multiple" : ""}`}>{item.imagePaths!.map((path) => <LocalImage key={path} path={path}/>)}</div>}{item.text && <div className="user-bubble"><Markdown text={item.text}/></div>}</div></div> : null;
  if (item.kind === "assistant") return <div className="assistant-answer"><Markdown text={item.text}/></div>;
  return <ToolRow item={item}/>;
}

function LocalImage({ path }: { path: string }) {
  const [source, setSource] = useState<string>();
  useEffect(() => {
    let active = true;
    void window.relayDesktop.readImage(path).then((value) => { if (active) setSource(value); });
    return () => { active = false; };
  }, [path]);
  if (!source) return <div className="image-placeholder"><span className="spinner small"/></div>;
  return <button className="user-image" title={path.split(/[\\/]/).at(-1)} onClick={() => void window.relayDesktop.showFile(path)}><img src={source} alt={path.split(/[\\/]/).at(-1) || "附件图片"}/></button>;
}

function ActivityBlock({ items, metadata, live, showHeader, canExpand, expanded, onToggle }: { items: TranscriptItem[]; metadata?: TurnMetadata; live: boolean; showHeader: boolean; canExpand: boolean; expanded: boolean; onToggle: () => void }) {
  const [, setTick] = useState(0);
  useEffect(() => { if (!live || !showHeader) return; const timer = setInterval(() => setTick((value) => value + 1), 1000); return () => clearInterval(timer); }, [live, showHeader]);
  const latestReasoning = [...items].reverse().find((item) => item.kind === "reasoning");
  const hasDuration = (metadata?.durationMs || 0) > 0 || (metadata?.startedAt != null && (live || metadata.completedAt != null));
  const duration = hasDuration ? formatElapsed(metadata?.startedAt, metadata?.completedAt, metadata?.durationMs) : undefined;
  const statusLabel = live ? "正在处理" : metadata?.status === "failed" ? "处理失败" : metadata?.status === "interrupted" ? "已停止" : "已处理";
  const label = duration ? `${statusLabel} · ${duration}` : statusLabel;
  const visible = items.filter((item) => item.kind !== "plan" && (item.kind !== "reasoning" || item.id === latestReasoning?.id));
  const segments: ({ commentary?: TranscriptItem; reasoning?: TranscriptItem; execution?: TranscriptItem[]; id: string })[] = [];
  let execution: TranscriptItem[] = [];
  const flush = () => { if (execution.length) { segments.push({ execution, id: `exec.${execution[0].id}` }); execution = []; } };
  for (const item of visible) {
    if (item.kind === "assistant" && item.phase === "commentary") { flush(); segments.push({ commentary: item, id: `comment.${item.id}` }); }
    else if (item.kind === "reasoning") { flush(); segments.push({ reasoning: item, id: `reasoning.${item.id}` }); }
    else execution.push(item);
  }
  flush();
  const [visibleSegmentCount, setVisibleSegmentCount] = useState(() => expanded ? Math.min(8, segments.length) : 0);
  useEffect(() => {
    if (!expanded) {
      setVisibleSegmentCount(0);
      return;
    }
    setVisibleSegmentCount((current) => Math.min(segments.length, Math.max(current, Math.min(8, segments.length))));
  }, [expanded, segments.length]);
  if (!showHeader && !expanded) return null;
  return <div className={`activity-block ${!showHeader ? "continuation" : ""} ${live ? "live" : metadata?.status || ""}`}>
    {showHeader && <button className="activity-header" onClick={() => canExpand && onToggle()}><span className="activity-status">{live ? <span className="spinner"/> : metadata?.status === "failed" ? <AlertCircle size={15}/> : metadata?.status === "interrupted" ? <CircleStop size={15}/> : <Check size={15}/>}</span><span className="activity-label">{label}</span>{canExpand && <ChevronDown size={14} className={expanded ? "rotated" : ""}/>}</button>}
    {expanded && <div className="activity-content">{segments.slice(0, visibleSegmentCount).map((segment) => segment.commentary ? <div className="progress-copy" key={segment.id}><Markdown text={segment.commentary.text}/></div> : segment.reasoning ? <div className="reasoning-summary" key={segment.id}><Sparkles size={13}/><Markdown text={lastLine(segment.reasoning.text || segment.reasoning.detail || "思考")}/></div> : <ExecutionGroup key={segment.id} items={segment.execution || []}/>)}{visibleSegmentCount < segments.length && <button className="activity-more" onClick={() => setVisibleSegmentCount((current) => Math.min(segments.length, current + 8))}><MoreHorizontal size={13}/><span>显示更多进展（剩余 {segments.length - visibleSegmentCount} 条）</span></button>}</div>}
  </div>;
}

function ExecutionGroup({ items }: { items: TranscriptItem[] }) {
  const [expanded, setExpanded] = useState(items.length === 1);
  if (items.length === 1) return <ToolRow item={items[0]}/>;
  const commands = items.filter((item) => item.kind === "command").length;
  const files = items.filter((item) => item.kind === "file").length;
  const others = items.length - commands - files;
  const summary = [files ? `编辑了${files > 1 ? "多个" : ""}文件` : "", commands ? `运行了${commands > 1 ? "多个" : ""}命令` : "", others ? `使用了${others > 1 ? "多个" : ""}工具` : ""].filter(Boolean).join("并");
  return <div className="execution-group"><button onClick={() => setExpanded((value) => !value)}><Terminal size={14}/><span>{summary}</span><span className="execution-state">{items.some((item) => isRunningStatus(item.status)) ? <span className="spinner small"/> : items.some((item) => (item.exitCode || 0) !== 0) ? <AlertCircle size={13}/> : <Check size={13}/>}</span><ChevronDown size={13} className={expanded ? "rotated" : ""}/></button>{expanded && <div className="execution-list">{items.map((item) => <ToolRow key={item.id} item={item}/>)}</div>}</div>;
}

function ToolRow({ item }: { item: TranscriptItem }) {
  const [expanded, setExpanded] = useState(false);
  const icon = item.kind === "file" ? <FileCode2 size={14}/> : item.kind === "compaction" ? <Sparkles size={14}/> : <Terminal size={14}/>;
  return <div className={`tool-row ${item.exitCode ? "failed" : ""}`}><button onClick={() => item.detail && setExpanded((value) => !value)}>{icon}<span className="tool-title">{item.kind === "command" ? firstLine(item.text) : item.title || item.text}</span>{item.cwd && <small>{item.cwd}</small>}{item.exitCode != null && item.exitCode !== 0 && <em>exit {item.exitCode}</em>}{isRunningStatus(item.status) ? <span className="spinner small"/> : <Check size={12}/>} {item.detail && <ChevronDown size={12} className={expanded ? "rotated" : ""}/>}</button>{expanded && item.detail && (item.kind === "file" ? <DiffView source={item.detail}/> : <pre>{item.detail}</pre>)}</div>;
}

function DiffView({ source }: { source: string }) {
  return <div className="diff-view" aria-label="文件差异">{source.split(/\r?\n/).map((line, index) => {
    const kind = diffLineKind(line);
    const content = kind === "added" || kind === "removed" ? line.slice(1) : line;
    return <div className={`diff-line ${kind}`} key={`${index}.${line}`}><span>{kind === "added" ? "+" : kind === "removed" ? "-" : ""}</span><code>{content || " "}</code></div>;
  })}</div>;
}

function PlanPanel({ steps }: { steps: PlanStep[] }) { return <div className="plan-panel"><div className="plan-title"><Sparkles size={14}/><span>执行计划</span></div>{steps.map((step) => <div className="plan-step" key={step.id}>{/complete/i.test(step.status) ? <Check size={13}/> : /progress|running|active/i.test(step.status) ? <span className="spinner small"/> : <span className="plan-dot"/>}<span>{step.text}</span></div>)}</div>; }

function GoalPanel({ goal, running }: { goal: GoalState; running: boolean }) {
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => {
    if (!running || goal.status !== "active") return;
    const timer = window.setInterval(() => setNow(Date.now() / 1000), 1_000);
    return () => window.clearInterval(timer);
  }, [goal.status, running]);
  const liveSeconds = running && goal.status === "active" ? Math.max(0, now - goal.updatedAt) : 0;
  const label = goal.status === "active" ? "进行中的目标"
    : goal.status === "blocked" ? "目标已阻塞"
      : goal.status === "budget_limited" ? "目标已达预算"
        : goal.status === "usage_limited" ? "目标已达用量限制" : "已暂停的目标";
  return <div className={`goal-panel ${goal.status}`} role="status" aria-label={`${label}，${goal.objective}`}>
    <Target size={15}/><strong>{label}</strong><span className="goal-objective" title={goal.objective}>{goal.objective}</span><span className="goal-separator">·</span><time>{formatGoalDuration(goal.timeUsedSeconds + liveSeconds)}</time>
  </div>;
}

function formatGoalDuration(value: number) {
  const seconds = Math.max(0, Math.floor(value));
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const remainder = seconds % 60;
  return [hours ? `${hours}h` : "", hours || minutes ? `${minutes}m` : "", `${remainder}s`].filter(Boolean).join(" ");
}

function PromptQueuePanel({ items, onRemove }: { items: QueuedPrompt[]; onRemove: (id: string) => Promise<void> }) {
  return <div className="prompt-queue-panel"><div className="prompt-queue-title"><MessageSquare size={13}/><span>已排队 {items.length} 条后续消息</span><small>任务结束后发送</small></div>{items.slice(0, 3).map((item) => <div className="prompt-queue-row" key={item.id}><span>{queuedPromptLabel(item)}</span><button className="icon-button" title="删除排队消息" onClick={() => void onRemove(item.id)}><X size={11}/></button></div>)}</div>;
}

function queuedPromptLabel(item: QueuedPrompt) {
  if (item.text.trim()) return item.text.trim();
  return item.input.filter((input) => input.type !== "text").map((input) => input.name || input.path?.split(/[\\/]/).at(-1)).filter(Boolean).join("、") || "附件";
}

function SettingsPanel({ config, setConfig, workspace, setWorkspace, access, setAccess, profiles, activeProfileId, switching, switchDisabled, onSwitch, onStartService, service, preferences, update, onPreferences, onCheckUpdate, onApplyUpdate, onDiagnostics, onClose, onSave }: {
  config: ConnectionConfig; setConfig: (value: ConnectionConfig) => void; workspace: string; setWorkspace: (value: string) => void;
  access: WorkspaceAccess; setAccess: (value: WorkspaceAccess) => void; profiles: CodexProfile[]; activeProfileId: string;
  switching: boolean; switchDisabled: boolean; onSwitch: (id: string) => Promise<void>; onStartService: () => Promise<void>;
  service: ServiceStatus; preferences: DesktopPreferences; onPreferences: (patch: Partial<DesktopPreferences>) => Promise<void>;
  update: DesktopUpdateState; onCheckUpdate: () => Promise<void>; onApplyUpdate: () => Promise<void>;
  onDiagnostics: () => void; onClose: () => void; onSave: () => Promise<void>;
}) {
  const [selectedProfileId, setSelectedProfileId] = useState(activeProfileId);
  useEffect(() => { setSelectedProfileId(activeProfileId); }, [activeProfileId]);
  const selected = profiles.find((profile) => profile.id === selectedProfileId);
  return <div className="drawer-backdrop" onMouseDown={onClose}>
    <aside className="settings-drawer" onMouseDown={(event) => event.stopPropagation()}>
      <div className="drawer-heading"><div><strong>Relay 设置</strong><span>实例、工作区与权限</span></div><button className="icon-button" onClick={onClose}><X size={17}/></button></div>
      <div className="settings-section">
        <h3>Codex 实例</h3>
        {service.state === "running" ? <>
          <div className="profile-control">
            <label className="field"><span>当前 Windows 实例</span><select value={selectedProfileId} onChange={(event) => setSelectedProfileId(event.target.value)}>{profiles.map((profile) => <option key={profile.id} value={profile.id}>{profile.name}{profile.running ? " · 运行中" : ""}</option>)}</select></label>
            <button disabled={!selectedProfileId || selectedProfileId === activeProfileId || switching || switchDisabled} onClick={() => void onSwitch(selectedProfileId)}>{switching ? "切换中" : "切换"}</button>
          </div>
          <div className="profile-status"><span className="running-dot"/><span>{switching ? "正在重新连接 Codex" : `正在使用 ${profiles.find((profile) => profile.id === activeProfileId)?.name || "Codex"}`}</span></div>
          {switchDisabled && <p>任务运行或等待审批时不能切换实例。</p>}
          {selected && !selected.running && selected.id !== activeProfileId && <p>该桌面实例当前未运行，仍可使用它保存的配置和会话。</p>}
        </> : <button className="primary-action service-action" disabled={service.state === "starting"} onClick={() => void onStartService()}>{service.state === "starting" ? <span className="spinner small"/> : <Power size={15}/>}<span>{service.state === "starting" ? "正在启动" : "启动远程服务"}</span></button>}
      </div>
      <div className="settings-section"><h3>默认工作区</h3><label className="field"><span>目录</span><input value={workspace} onChange={(event) => setWorkspace(event.target.value)} placeholder="C:\\项目目录"/></label><label className="field"><span>访问权限</span><select value={access} onChange={(event) => setAccess(event.target.value as WorkspaceAccess)}><option value="readOnly">只读</option><option value="workspaceWrite">工作区写入</option><option value="fullAccess">完全访问</option></select></label><p>{access === "fullAccess" ? "允许访问本机文件和网络；仅在你信任当前任务时使用。" : access === "workspaceWrite" ? "仅允许修改所选工作区内的文件。" : "可以查看文件，但不能修改。"}</p></div>
      <div className="settings-section"><h3>运行与通知</h3><label className="toggle-row"><span><strong>开机启动远程服务</strong><small>登录 Windows 后自动运行 Relay 与 Bridge</small></span><input type="checkbox" checked={preferences.autoStart} onChange={(event) => void onPreferences({ autoStart: event.target.checked })}/></label><label className="toggle-row"><span><strong>任务与审批通知</strong><small>窗口不在前台时显示系统通知</small></span><input type="checkbox" checked={preferences.notifications} onChange={(event) => void onPreferences({ notifications: event.target.checked })}/></label><button className="settings-link" onClick={() => { onClose(); onDiagnostics(); }}><Activity size={14}/><span>打开诊断中心</span><ChevronRight size={13}/></button></div>
      <div className="settings-section"><h3>应用更新</h3><div className="update-row"><div><strong>{update.message || "检查 Relay Desktop 更新"}</strong><span>{update.version ? `版本 ${update.version}` : "通过 GitHub Release 获取"}</span></div>{update.state === "available" || update.state === "ready" || update.state === "deferred" ? <button disabled={update.state === "deferred"} onClick={() => void onApplyUpdate()}>{update.state === "ready" ? "安全重启安装" : update.state === "deferred" ? "等待任务结束" : "下载"}</button> : <button disabled={update.state === "checking" || update.state === "downloading" || update.state === "installing"} onClick={() => void onCheckUpdate()}>{update.state === "checking" ? "检查中" : update.state === "downloading" ? `${update.percent || 0}%` : update.state === "installing" ? "安装中" : "检查"}</button>}</div></div>
      <details className="advanced-settings"><summary>高级连接</summary><label className="field"><span>Bridge 地址</span><input value={config.endpoint} onChange={(event) => setConfig({ ...config, endpoint: event.target.value })}/></label><label className="field"><span>Token</span><input type="password" value={config.token} onChange={(event) => setConfig({ ...config, token: event.target.value })}/></label></details>
      <div className="drawer-actions"><button onClick={onClose}>关闭</button><button className="accent" onClick={() => void onSave()}>保存高级连接</button></div>
    </aside>
  </div>;
}

function DiagnosticsPanel({ report, loading, onRefresh, onClose }: {
  report?: DiagnosticReport; loading: boolean; onRefresh: () => Promise<void>; onClose: () => void;
}) {
  const summaryLabel = report?.summary === "ok" ? "运行正常" : report?.summary === "error" ? "需要处理" : "需要留意";
  return <div className="drawer-backdrop" onMouseDown={onClose}>
    <aside className="diagnostics-drawer" onMouseDown={(event) => event.stopPropagation()}>
      <div className="drawer-heading">
        <div><strong>诊断中心</strong><span>{report ? `${summaryLabel} · ${new Date(report.generatedAt).toLocaleTimeString()}` : "正在读取 Bridge 状态"}</span></div>
        <div className="drawer-tools">
          <button className="icon-button" title="导出诊断 JSON" disabled={!report} onClick={() => report && void window.relayDesktop.exportDiagnostics(report)}><Copy size={15}/></button>
          <button className="icon-button" title="刷新" disabled={loading} onClick={() => void onRefresh()}>{loading ? <span className="spinner small"/> : <RefreshCw size={15}/>}</button>
          <button className="icon-button" title="关闭" onClick={onClose}><X size={17}/></button>
        </div>
      </div>
      {!report ? <div className="diagnostics-loading"><span className="spinner"/><span>正在读取诊断信息</span></div> : <>
        <div className={`diagnostics-summary ${report.summary}`}><Activity size={16}/><strong>{summaryLabel}</strong><span>{report.metrics.activeTurns} 个任务运行中 · {report.metrics.queuedPromptCount} 条排队消息</span></div>
        <section className="diagnostic-section">
          <h3>系统检查</h3>
          <div className="diagnostic-checks">{report.checks.map((check) => <div className="diagnostic-check" key={check.id}><span className={`diagnostic-dot ${check.level}`}/><div><strong>{check.title}</strong><span>{check.detail}</span></div></div>)}</div>
        </section>
        {report.clientPerformance && <section className="diagnostic-section">
          <h3>性能</h3>
          <div className="diagnostic-metrics">
            <DiagnosticMetric title="会话增量同步" value={`${report.clientPerformance.sessions.patches} 补丁 / ${report.clientPerformance.sessions.snapshots} 快照`} detail={`应用 P95 ${formatMilliseconds(report.clientPerformance.sessions.patchApplyLatency.p95Ms)} · ${report.clientPerformance.sessions.revisionGaps} 次修订缺口`}/>
            <DiagnosticMetric title="流式内容刷新" value={`P95 ${formatMilliseconds(report.clientPerformance.deltas.flushLatency.p95Ms)}`} detail={`${report.clientPerformance.deltas.frameFlushes} 帧 · 单帧最多 ${report.clientPerformance.deltas.maxItemsPerFrame} 项`}/>
            {report.performance && <DiagnosticMetric title="Bridge RPC" value={`P95 ${formatMilliseconds(report.performance.rpcLatency.p95Ms)}`} detail={`补丁/快照流量比 ${formatPercent(report.performance.sessions.patchToSnapshotByteRatio)}`}/>}
          </div>
        </section>}
        <section className="diagnostic-section events">
          <h3>最近事件</h3>
          {!report.events.length ? <p>暂无异常事件</p> : report.events.slice(0, 40).map((event) => <div className="diagnostic-event" key={event.id}><span className={`diagnostic-dot ${event.level}`}/><div><strong>{event.message}</strong><span>{event.category} · {new Date(event.at).toLocaleTimeString()}</span></div></div>)}
        </section>
      </>}
    </aside>
  </div>;
}

function DiagnosticMetric({ title, value, detail }: { title: string; value: string; detail: string }) {
  return <div className="diagnostic-metric"><div><strong>{title}</strong><span>{value}</span></div><small>{detail}</small></div>;
}

function formatMilliseconds(value = 0) { return value < 10 ? `${value.toFixed(1)} ms` : `${Math.round(value)} ms`; }
function formatPercent(value = 0) { return `${(value * 100).toFixed(1)}%`; }

function Modal({ title, children, onClose, closable = true }: { title: string; children: ReactNode; onClose: () => void; closable?: boolean }) { return <div className="modal-backdrop"><div className="modal"><div className="modal-heading"><strong>{title}</strong>{closable && <button className="icon-button" onClick={onClose}><X size={16}/></button>}</div>{children}</div></div>; }
function Markdown({ text }: { text: string }) { const html = useMemo(() => DOMPurify.sanitize(marked.parse(text || "", { breaks: true, gfm: true }) as string), [text]); return <div className="markdown" dangerouslySetInnerHTML={{ __html: html }}/>; }
function LoadingState({ label = "正在加载对话" }: { label?: string }) { return <div className="center-state"><span className="spinner large"/><span>{label}</span></div>; }
function ServiceState({ status, onStart }: { status: ServiceStatus; onStart: () => Promise<void> }) { return <div className="center-state service-start"><Server size={28}/><span>{status.message}</span>{status.state !== "starting" && <button onClick={() => void onStart()}><Power size={15}/>启动远程服务</button>}</div>; }
function EmptyState({ cwd }: { cwd?: string }) { return <div className="empty-state"><div className="relay-mark"><Sparkles size={24}/></div><h1>Codex 要处理什么？</h1><p>{cwd || "选择项目目录后开始任务"}</p></div>; }

function sandboxPolicy(access: WorkspaceAccess, cwd: string) { if (access === "fullAccess") return { type: "dangerFullAccess" }; if (access === "readOnly") return { type: "readOnly", networkAccess: false }; return { type: "workspaceWrite", writableRoots: cwd ? [cwd] : [], networkAccess: false }; }
function storedWorkspaceAccess(): WorkspaceAccess { const value = localStorage.getItem("relay.desktop.access"); return value === "readOnly" || value === "fullAccess" || value === "workspaceWrite" ? value : "workspaceWrite"; }
function storedProjectAccesses(): Record<string, WorkspaceAccess> {
  try {
    const parsed = JSON.parse(localStorage.getItem("relay.desktop.accessByProject") || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return Object.fromEntries(Object.entries(parsed).filter((entry): entry is [string, WorkspaceAccess] =>
      ["readOnly", "workspaceWrite", "fullAccess"].includes(String(entry[1]))));
  } catch { return {}; }
}
function normalizedWorkspaceKey(value: string) { return value.trim().replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase(); }
function accessForWorkspace(value: string, fallback: WorkspaceAccess, projects: Record<string, WorkspaceAccess>) {
  const key = normalizedWorkspaceKey(value);
  return key ? projects[key] || fallback : fallback;
}
function pinnedThreadsKey(profileId: string) { return `relay.desktop.pinnedThreads.${profileId || "default"}`; }
function storedPinnedThreads(profileId: string) {
  try {
    const values = JSON.parse(localStorage.getItem(pinnedThreadsKey(profileId)) || "[]");
    return new Set<string>(Array.isArray(values) ? values.filter((value) => typeof value === "string") : []);
  } catch { return new Set<string>(); }
}
function sortPinnedThreads(threads: ThreadSummary[], pinned: Set<string>) {
  return [...threads].sort((left, right) => {
    const leftPinned = pinned.has(left.id);
    const rightPinned = pinned.has(right.id);
    return leftPinned === rightPinned ? right.updatedAt - left.updatedAt : leftPinned ? -1 : 1;
  });
}
function effortName(value: string) { return ({ none: "关闭", minimal: "最低", low: "低", medium: "中", high: "高", xhigh: "最高", ultra: "极高+" } as Record<string, string>)[value] || value; }
function errorText(reason: unknown) { return reason instanceof Error ? reason.message : String(reason); }
function firstLine(value: string) { return value.split(/\r?\n/)[0]?.trim() || "命令"; }
function lastLine(value: string) { return value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean).at(-1)?.replaceAll("**", "") || ""; }
function relativeTime(timestamp: number) { if (!timestamp) return ""; const seconds = Math.max(0, Date.now() / 1000 - timestamp); if (seconds < 60) return "刚刚"; if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟`; if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时`; return `${Math.floor(seconds / 86400)} 天`; }
