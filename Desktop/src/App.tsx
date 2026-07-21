import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import DOMPurify from "dompurify";
import { marked } from "marked";
import {
  AlertCircle, ArrowDown, ArrowUp, Check, ChevronDown, ChevronRight, CircleStop,
  FileCode2, Folder, FolderOpen, Menu, MessageSquare, Paperclip, Plus, Search, Target,
  Power, Server, Settings, Sparkles, SquarePen, Terminal, Wifi, WifiOff, X,
} from "lucide-react";
import { BridgeRpc } from "./bridge";
import {
  applyUserMessagePlacements, bindUserPrompt, formatElapsed, groupProjects, isRunningStatus, mergeSnapshot, parseApproval,
  parseItem, parseModel, parseThread, parseTurn, upsert,
} from "./transcript";
import type { UserMessagePlacement } from "./transcript";
import { idleTaskState, isTaskRunning, reduceTaskRunState, type TaskRunEvent, type TaskRunState } from "./taskState";
import type {
  ApprovalRequest, Attachment, CodexProfile, ConnectionConfig, ConnectionState, ModelOption,
  PlanStep, QueuedPrompt, ServiceStatus, ThreadSummary, TranscriptItem, TurnMetadata, WorkspaceAccess,
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
  const [taskStates, setTaskStates] = useState<Record<string, TaskRunState>>({});
  const [composer, setComposer] = useState("");
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [followUpBehavior, setFollowUpBehavior] = useState<"steer" | "queue">(() => localStorage.getItem("relay.desktop.followUp") === "queue" ? "queue" : "steer");
  const [queuedPrompts, setQueuedPrompts] = useState<QueuedPrompt[]>([]);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [newTaskOpen, setNewTaskOpen] = useState(false);
  const [newTaskCwd, setNewTaskCwd] = useState(workspace);
  const [loadingThread, setLoadingThread] = useState(false);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string>();
  const [approvals, setApprovals] = useState<ApprovalRequest[]>([]);
  const [codexProfiles, setCodexProfiles] = useState<CodexProfile[]>([]);
  const [activeProfileId, setActiveProfileId] = useState("");
  const [profileSwitching, setProfileSwitching] = useState(false);
  const selectedRef = useRef<string>();
  const activeTurnRef = useRef<string>();
  const profileSwitchingRef = useRef(false);
  const pendingStartMessageRef = useRef<string>();
  const userMessagePlacementsRef = useRef(new Map<string, UserMessagePlacement>());
  const placementSequenceRef = useRef(0);
  const messagesRef = useRef<TranscriptItem[]>([]);
  const threadMessageCacheRef = useRef(new Map<string, TranscriptItem[]>());
  const messageHandlerRef = useRef<(message: any) => void>(() => {});
  const transcriptEndRef = useRef<HTMLDivElement>(null);
  const [atBottom, setAtBottom] = useState(true);
  const scrollRef = useRef<HTMLDivElement>(null);

  const selectedThread = threads.find((thread) => thread.id === selectedThreadId);
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
  const projects = useMemo(() => groupProjects(threads), [threads]);
  const currentQueuedPrompts = queuedPrompts.filter((item) => item.threadId === selectedThreadId);
  const currentGoal = [...messages].reverse().find((item) => item.goal)?.goal;
  messagesRef.current = messages;

  function updateTaskState(threadId: string, event: TaskRunEvent) {
    setTaskStates((current) => ({
      ...current,
      [threadId]: reduceTaskRunState(current[threadId] || idleTaskState(threadId), event),
    }));
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

  useEffect(() => {
    const offMessage = window.relayDesktop.onMessage((message) => rpc.handle(message));
    const offState = window.relayDesktop.onState((state) => {
      setConnection(state.state);
      setConnectionAttempt(state.attempt || 0);
      if (["disconnected", "failed", "error"].includes(state.state)) rpc.failAll("Bridge 连接已断开");
    });
    const offService = window.relayDesktop.onService(setService);
    const offRpc = rpc.onMessage((message) => messageHandlerRef.current(message));
    void window.relayDesktop.bootstrap().then((bootstrap) => {
      setConfig(bootstrap.connection);
      setVersion(bootstrap.version);
      setService(bootstrap.service);
      if (bootstrap.connection.token && ["running", "starting"].includes(bootstrap.service.state)) void window.relayDesktop.connect(bootstrap.connection).catch((reason) => setError(String(reason)));
    });
    return () => { offMessage(); offState(); offService(); offRpc(); };
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
    else if (message?.type === "serverRequest") {
      const incoming = parseApproval(message);
      setApprovals((current) => current.some((item) => String(item.id) === String(incoming.id))
        ? current.map((item) => String(item.id) === String(incoming.id) ? incoming : item)
        : [...current, incoming]);
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
      setActiveProfileId(profileResult.activeProfileId || "");
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
      setTaskStates({});
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
      await window.relayDesktop.connect(status.connection);
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

  async function refreshThreads() {
    try {
      const result = await rpc.rpc("thread/list", { limit: 200, sortKey: "updated_at", sortDirection: "desc", useStateDbOnly: true });
      setThreads((result.data || []).map(parseThread).filter(Boolean));
    } catch {}
  }

  async function selectThread(id: string) {
    const previous = selectedRef.current;
    if (previous && previous !== id) threadMessageCacheRef.current.set(previous, messagesRef.current);
    selectedRef.current = id;
    setSelectedThreadId(id);
    localStorage.setItem("relay.desktop.thread", id);
    setLoadingThread(true);
    const cachedMessages = threadMessageCacheRef.current.get(id) || [];
    setMessages(cachedMessages);
    messagesRef.current = cachedMessages;
    setTurns({});
    updateTaskState(id, { type: "reset" });
    try {
      if (previous && previous !== id) void rpc.rpc("relay/thread/session/unsubscribe", { threadId: previous }, 5_000).catch(() => {});
      const result = await rpc.rpc("thread/resume", {
        threadId: id,
        excludeTurns: true,
        initialTurnsPage: { limit: 12, sortDirection: "desc", itemsView: "full" },
      }, 30_000);
      if (selectedRef.current !== id) return;
      const page = result.initialTurnsPage?.data || [];
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
      try {
        const snapshot = await rpc.rpc("relay/thread/session/subscribe", { threadId: id }, 12_000);
        if (selectedRef.current === id) handleSessionSnapshot(id, snapshot);
      } catch {}
    } catch (reason) { setError(errorText(reason)); }
    finally { if (selectedRef.current === id) setLoadingThread(false); }
  }

  function handleSessionSnapshot(threadId: string, snapshot: any) {
    if (selectedRef.current !== threadId || !snapshot?.known || !snapshot.turnId) return;
    const live = snapshot.isRunning === true && snapshot.stale !== true;
    if (live) bindPendingStartMessage(snapshot.turnId);
    const snapshotItems = (snapshot.items || []).map((value: any) => parseItem(value, snapshot.turnId)).filter(Boolean) as TranscriptItem[];
    if (snapshotItems.length) setMessages((current) => applyUserMessagePlacements(
      mergeSnapshot(current, snapshotItems, snapshot.turnId),
      userMessagePlacementsRef.current.values(),
      threadId,
      snapshot.turnId,
    ));
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
  }

  function handleEvent(method: string, params: any) {
    const threadId = params.threadId;
    const turnId = params.turnId || params.turn?.id;
    const terminal = ["turn/completed", "turn/aborted", "turn/interrupted", "turn/failed"].includes(method);
    if (threadId) {
      setThreads((current) => current.map((thread) => thread.id === threadId
        ? { ...thread, status: terminal ? "idle" : method.startsWith("turn/") || method.startsWith("item/") ? "active" : thread.status, updatedAt: Date.now() / 1000 }
        : thread));
      if (method === "turn/started" && turnId) {
        updateTaskState(threadId, { type: "started", turnId, startedAt: params.turn?.startedAt });
      } else if (terminal) {
        updateTaskState(threadId, {
          type: "terminal",
          turnId,
          phase: method === "turn/failed" ? "failed" : method === "turn/completed" ? "completed" : "interrupted",
          completedAt: params.turn?.completedAt,
        });
      } else if (method === "turn/plan/updated" && turnId) {
        updateTaskState(threadId, {
          type: "plan",
          turnId,
          plan: (params.plan || []).map((step: any, index: number) => ({ id: `${turnId}.${index}`, text: step.step, status: step.status || "pending" })),
        });
      } else if (method === "error") {
        if (params.willRetry === true) updateTaskState(threadId, { type: "retrying", turnId, message: params.error?.message || params.message });
        else if (params.willRetry === false) updateTaskState(threadId, { type: "terminal", turnId, phase: "failed" });
      } else if (turnId && method.startsWith("item/")) {
        updateTaskState(threadId, { type: "progress", turnId });
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
    if (terminal) {
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
    setMessages((current) => {
      const index = current.findIndex((item) => item.id === id);
      if (index < 0) return [...current, { id, turnId, kind, text: delta, phase: kind === "assistant" ? "commentary" : undefined, title: kind === "reasoning" ? "思考" : undefined }];
      const next = [...current]; next[index] = { ...next[index], text: next[index].text + delta, turnId: next[index].turnId || turnId }; return next;
    });
  }

  function appendDetail(id: string, delta: string, turnId: string, kind: "reasoning" | "command") {
    if (!id || !delta) return;
    setMessages((current) => {
      const index = current.findIndex((item) => item.id === id);
      if (index < 0) return [...current, { id, turnId, kind, text: "", detail: delta, title: kind === "reasoning" ? "思考" : "运行命令", status: "inProgress" }];
      const next = [...current]; next[index] = { ...next[index], detail: (next[index].detail || "") + delta }; return next;
    });
  }

  async function createThread(cwd = workspace) {
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

  const serviceAvailable = service.state === "running" || service.state === "starting";
  const connectionLabel = !serviceAvailable ? "远程服务未启动" : profileSwitching ? "正在切换实例" : upstreamRetrying ? "Codex 上游重连中" : connection === "connected" ? "实时同步" : connection === "reconnecting" ? `正在重连 · ${connectionAttempt}` : connection === "handshaking" ? "正在初始化" : "未连接";

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
          <div className="sidebar-search"><Search size={13}/><input placeholder="搜索对话"/></div>
          <div className="project-list">
            {projects.map((project) => <ProjectGroup key={project.path} project={project} selectedId={selectedThreadId} approvalThreadIds={approvalThreadIds} onSelect={selectThread}/>) }
            {!projects.length && <div className="empty-sidebar">暂无对话</div>}
          </div>
          <div className="sidebar-footer"><Server size={12}/><span>{activeCodexProfile?.name || "Codex"}</span><span className="version">v{version}</span></div>
        </aside>

        <main className="main-pane">
          <header className="thread-header">
            <button className="icon-button sidebar-toggle" onClick={() => setSidebarOpen((value) => !value)}><Menu size={18}/></button>
            <div className="thread-identity"><strong>{selectedThread?.title || "新任务"}</strong><span>{selectedThread?.cwd || workspace || "未指定工作目录"}</span></div>
            <div className={`live-badge ${serviceAvailable && upstreamRetrying ? "retrying" : serviceAvailable && connection === "connected" ? "connected" : "offline"}`}>
              {serviceAvailable && connection === "connected" ? <Wifi size={12}/> : <WifiOff size={12}/>}<span>{connectionLabel}</span>
            </div>
            <button className="icon-button" onClick={() => setSettingsOpen(true)}><Settings size={17}/></button>
          </header>

          <div className="transcript" ref={scrollRef} onScroll={(event) => {
            const element = event.currentTarget; setAtBottom(element.scrollHeight - element.scrollTop - element.clientHeight < 80);
          }}>
            <div className="transcript-inner">
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

          <div className="composer-zone">
            {plan.length > 0 && <PlanPanel steps={plan}/>
            }
            {currentQueuedPrompts.length > 0 && <PromptQueuePanel items={currentQueuedPrompts} onRemove={removeQueuedPrompt}/>
            }
            {currentGoal && <GoalPanel objective={currentGoal}/>
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
          </div>
        </main>
      </div>

      {settingsOpen && <SettingsPanel config={config} setConfig={setConfig} workspace={workspace} setWorkspace={setWorkspace} access={access} setAccess={setAccess} profiles={codexProfiles} activeProfileId={activeProfileId} switching={profileSwitching} switchDisabled={running || Boolean(approval)} onSwitch={switchCodexProfile} onStartService={startRemoteService} service={service} onClose={() => setSettingsOpen(false)} onSave={saveConnection}/>
      }
      {newTaskOpen && <Modal title="新建任务" onClose={() => setNewTaskOpen(false)}><label className="field"><span>工作目录</span><input value={newTaskCwd} onChange={(event) => setNewTaskCwd(event.target.value)} placeholder="C:\\项目目录"/></label><div className="modal-actions"><button onClick={() => setNewTaskOpen(false)}>取消</button><button className="accent" onClick={() => { void createThread(newTaskCwd).then(() => setNewTaskOpen(false)).catch((reason) => setError(errorText(reason))); }}>创建</button></div></Modal>}
      {approval && <Modal title={approval.title} closable={false} onClose={() => {}}>{approvalQueue.length > 1 && <div className="approval-queue-count">当前任务审批 1 / {approvalQueue.length}</div>}{approval.threadId && <div className="approval-task">{threads.find((thread) => thread.id === approval.threadId)?.title || approval.threadId}</div>}<p className="approval-summary">{approval.summary}</p>{approval.detail && <pre className="approval-detail">{approval.detail}</pre>}<div className="modal-actions"><button onClick={() => void resolveApproval(false)}>拒绝</button><button className="accent" onClick={() => void resolveApproval(true)}>允许</button></div></Modal>}
      {error && <div className="toast"><AlertCircle size={16}/><span>{error}</span><button onClick={() => setError(undefined)}><X size={14}/></button></div>}
    </div>
  );
}

function ProjectGroup({ project, selectedId, approvalThreadIds, onSelect }: { project: ReturnType<typeof groupProjects>[number]; selectedId?: string; approvalThreadIds: Set<string>; onSelect: (id: string) => Promise<void> }) {
  const [open, setOpen] = useState(true);
  return <section className="project-group"><button className="project-heading" onClick={() => setOpen((value) => !value)}>{open ? <ChevronDown size={13}/> : <ChevronRight size={13}/>}<Folder size={14}/><span>{project.name}</span><small>{project.threads.length}</small></button>{open && <div className="thread-list">{project.threads.map((thread) => <button key={thread.id} className={`thread-row ${selectedId === thread.id ? "selected" : ""}`} onClick={() => void onSelect(thread.id)}>{approvalThreadIds.has(thread.id) ? <AlertCircle className="thread-approval" size={12}/> : <span className={`thread-running ${isRunningStatus(thread.status) ? "active" : ""}`}/>}<span className="thread-copy"><strong>{thread.title}</strong><small>{relativeTime(thread.updatedAt)}</small></span></button>)}</div>}</section>;
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
  return <div className="turn-block">{segments.map((segment, index) => segment.type === "activity" ? <ActivityBlock key={`${segment.id}.${index}`} items={segment.items} metadata={metadata} live={live && index === segments.length - 1}/> : <MessageRow key={segment.item.id} item={segment.item}/>)}</div>;
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

function ActivityBlock({ items, metadata, live }: { items: TranscriptItem[]; metadata?: TurnMetadata; live: boolean }) {
  const [expanded, setExpanded] = useState(live);
  const [, setTick] = useState(0);
  useEffect(() => { if (!live) setExpanded(false); }, [live]);
  useEffect(() => { if (!live) return; const timer = setInterval(() => setTick((value) => value + 1), 1000); return () => clearInterval(timer); }, [live]);
  const latestReasoning = [...items].reverse().find((item) => item.kind === "reasoning");
  const duration = formatElapsed(metadata?.startedAt, metadata?.completedAt, metadata?.durationMs);
  const statusLabel = live ? "正在处理" : metadata?.status === "failed" ? "处理失败" : metadata?.status === "interrupted" ? "已停止" : "已处理";
  const label = `${statusLabel} · ${duration}`;
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
  return <div className={`activity-block ${live ? "live" : metadata?.status || ""}`}><button className="activity-header" onClick={() => setExpanded((value) => !value)}><span className="activity-status">{live ? <span className="spinner"/> : metadata?.status === "failed" ? <AlertCircle size={15}/> : metadata?.status === "interrupted" ? <CircleStop size={15}/> : <Check size={15}/>}</span><span className="activity-label">{label}</span>{segments.length > 0 && <ChevronDown size={14} className={expanded ? "rotated" : ""}/>}</button>{expanded && <div className="activity-content">{segments.map((segment) => segment.commentary ? <div className="progress-copy" key={segment.id}><Markdown text={segment.commentary.text}/></div> : segment.reasoning ? <div className="reasoning-summary" key={segment.id}><Sparkles size={13}/><Markdown text={lastLine(segment.reasoning.text || segment.reasoning.detail || "思考")}/></div> : <ExecutionGroup key={segment.id} items={segment.execution || []}/>)}</div>}</div>;
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
  return <div className={`tool-row ${item.exitCode ? "failed" : ""}`}><button onClick={() => item.detail && setExpanded((value) => !value)}>{icon}<span className="tool-title">{item.kind === "command" ? firstLine(item.text) : item.title || item.text}</span>{item.cwd && <small>{item.cwd}</small>}{item.exitCode != null && item.exitCode !== 0 && <em>exit {item.exitCode}</em>}{isRunningStatus(item.status) ? <span className="spinner small"/> : <Check size={12}/>} {item.detail && <ChevronDown size={12} className={expanded ? "rotated" : ""}/>}</button>{expanded && item.detail && <pre>{item.detail}</pre>}</div>;
}

function PlanPanel({ steps }: { steps: PlanStep[] }) { return <div className="plan-panel"><div className="plan-title"><Sparkles size={14}/><span>执行计划</span></div>{steps.map((step) => <div className="plan-step" key={step.id}>{/complete/i.test(step.status) ? <Check size={13}/> : /progress|running|active/i.test(step.status) ? <span className="spinner small"/> : <span className="plan-dot"/>}<span>{step.text}</span></div>)}</div>; }

function GoalPanel({ objective }: { objective: string }) {
  return <div className="goal-panel"><Target size={15}/><strong>进行中的目标</strong><span>{objective}</span></div>;
}

function PromptQueuePanel({ items, onRemove }: { items: QueuedPrompt[]; onRemove: (id: string) => Promise<void> }) {
  return <div className="prompt-queue-panel"><div className="prompt-queue-title"><MessageSquare size={13}/><span>已排队 {items.length} 条后续消息</span><small>任务结束后发送</small></div>{items.slice(0, 3).map((item) => <div className="prompt-queue-row" key={item.id}><span>{queuedPromptLabel(item)}</span><button className="icon-button" title="删除排队消息" onClick={() => void onRemove(item.id)}><X size={11}/></button></div>)}</div>;
}

function queuedPromptLabel(item: QueuedPrompt) {
  if (item.text.trim()) return item.text.trim();
  return item.input.filter((input) => input.type !== "text").map((input) => input.name || input.path?.split(/[\\/]/).at(-1)).filter(Boolean).join("、") || "附件";
}

function SettingsPanel({ config, setConfig, workspace, setWorkspace, access, setAccess, profiles, activeProfileId, switching, switchDisabled, onSwitch, onStartService, service, onClose, onSave }: {
  config: ConnectionConfig; setConfig: (value: ConnectionConfig) => void; workspace: string; setWorkspace: (value: string) => void;
  access: WorkspaceAccess; setAccess: (value: WorkspaceAccess) => void; profiles: CodexProfile[]; activeProfileId: string;
  switching: boolean; switchDisabled: boolean; onSwitch: (id: string) => Promise<void>; onStartService: () => Promise<void>;
  service: ServiceStatus; onClose: () => void; onSave: () => Promise<void>;
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
      <details className="advanced-settings"><summary>高级连接</summary><label className="field"><span>Bridge 地址</span><input value={config.endpoint} onChange={(event) => setConfig({ ...config, endpoint: event.target.value })}/></label><label className="field"><span>Token</span><input type="password" value={config.token} onChange={(event) => setConfig({ ...config, token: event.target.value })}/></label></details>
      <div className="drawer-actions"><button onClick={onClose}>关闭</button><button className="accent" onClick={() => void onSave()}>保存高级连接</button></div>
    </aside>
  </div>;
}

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
function effortName(value: string) { return ({ none: "关闭", minimal: "最低", low: "低", medium: "中", high: "高", xhigh: "最高", ultra: "极高+" } as Record<string, string>)[value] || value; }
function errorText(reason: unknown) { return reason instanceof Error ? reason.message : String(reason); }
function firstLine(value: string) { return value.split(/\r?\n/)[0]?.trim() || "命令"; }
function lastLine(value: string) { return value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean).at(-1)?.replaceAll("**", "") || ""; }
function relativeTime(timestamp: number) { if (!timestamp) return ""; const seconds = Math.max(0, Date.now() / 1000 - timestamp); if (seconds < 60) return "刚刚"; if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟`; if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时`; return `${Math.floor(seconds / 86400)} 天`; }
