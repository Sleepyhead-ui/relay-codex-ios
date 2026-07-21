export function installDevBridge() {
  if (window.relayDesktop) return;
  const messageListeners = new Set<(message: any) => void>();
  const stateListeners = new Set<(state: any) => void>();
  const serviceListeners = new Set<(state: any) => void>();
  const previewServiceRunning = new URLSearchParams(window.location.search).get("service") !== "stopped";
  const threadId = "preview.thread";
  const turnId = "preview.turn";
  const now = Date.now() / 1000;
  let preferences = { autoStart: false, notifications: true };
  let update = { state: "current" as const, currentVersion: "preview", message: "开发预览版" };
  const items = [
    { id: "goal.1", type: "userMessage", content: [{ type: "text", text: "<codex_internal_context source=\"goal\"><objective>完成第二、第三和第四阶段</objective></codex_internal_context>" }] },
    { id: "user.1", type: "userMessage", content: [{ type: "text", text: "检查这个项目，并让桌面端与手机端保持实时同步" }] },
    { id: "reasoning.1", type: "reasoning", summary: ["Inspecting realtime event flow"], content: [] },
    { id: "comment.1", type: "agentMessage", phase: "commentary", text: "我会先核对 Bridge 的事件转发与会话恢复路径，再验证双端是否接收同一组增量事件。" },
    { id: "command.1", type: "commandExecution", command: "npm test", aggregatedOutput: "18 tests passed", status: "completed", exitCode: 0, cwd: "C:\\Projects\\Relay" },
    { id: "file.1", type: "fileChange", status: "completed", changes: [{ path: "Desktop/src/App.tsx", diff: "--- a/Desktop/src/App.tsx\n+++ b/Desktop/src/App.tsx\n@@ -10,2 +10,3 @@\n-old line\n+new line\n context" }] },
    { id: "user.followup", type: "userMessage", content: [{ type: "text", text: "继续检查重连后的显示顺序" }] },
    { id: "comment.2", type: "agentMessage", phase: "commentary", text: "实时通道已经连通。现在正在检查界面折叠、执行计划和断线恢复。" },
  ];
  const emit = (message: any) => messageListeners.forEach((listener) => listener(message));
  const rpcResult = (request: any, result: any) => setTimeout(() => emit({ type: "rpcResult", id: request.id, result }), 15);
  window.relayDesktop = {
    bootstrap: async () => ({ connection: { endpoint: "ws://127.0.0.1:8765", token: "preview-token" }, version: "preview", service: previewServiceRunning ? { state: "running", message: "远程服务已启动" } : { state: "stopped", message: "远程服务未启动" }, preferences }),
    serviceStatus: async () => previewServiceRunning ? { state: "running", message: "远程服务已启动" } : { state: "stopped", message: "远程服务未启动" },
    startService: async () => {
      const status = { state: "running" as const, message: "远程服务已启动", connection: { endpoint: "ws://127.0.0.1:8765", token: "preview-token" } };
      serviceListeners.forEach((listener) => listener(status));
      return status;
    },
    setPreferences: async (patch) => (preferences = { ...preferences, ...patch }),
    notify: async () => true,
    exportDiagnostics: async () => true,
    updateStatus: async () => update,
    checkUpdate: async () => update,
    downloadUpdate: async () => update,
    installUpdate: async () => true,
    connect: async () => { setTimeout(() => stateListeners.forEach((listener) => listener({ state: "connected" })), 10); return true; },
    disconnect: async () => {},
    send: async (message: any) => {
      if (message?.type !== "rpc") return true;
      if (message.method === "thread/list") rpcResult(message, { data: [
        { id: threadId, name: "Relay Desktop 实时同步", preview: "检查这个项目", cwd: "C:\\Projects\\Relay", updatedAt: now, status: { type: "active" } },
        { id: "preview.other", name: "优化 Markdown 显示", cwd: "C:\\Projects\\Relay", updatedAt: now - 3900, status: { type: "idle" } },
        { id: "preview.second", name: "配置 Sub2API", cwd: "C:\\Projects\\Sub2API", updatedAt: now - 86400, status: { type: "idle" } },
      ] });
      else if (message.method === "model/list") rpcResult(message, { data: [
        { id: "gpt-5.6-sol", model: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", isDefault: true, supportedReasoningEfforts: [{ reasoningEffort: "medium" }, { reasoningEffort: "high" }, { reasoningEffort: "xhigh" }], defaultReasoningEffort: "high" },
      ] });
      else if (message.method === "thread/resume") rpcResult(message, { model: "gpt-5.6-sol", reasoningEffort: "high", thread: { id: threadId, status: { type: "active" } }, initialTurnsPage: { data: [{ id: turnId, status: "inProgress", startedAt: now - 67, items }], nextCursor: "preview.older" } });
      else if (message.method === "thread/turns/list") rpcResult(message, { data: [{ id: "preview.older.turn", status: "completed", startedAt: now - 7200, completedAt: now - 7100, items: [
        { id: "preview.older.user", type: "userMessage", content: [{ type: "text", text: "先审计现有同步链路" }] },
        { id: "preview.older.answer", type: "agentMessage", phase: "final_answer", text: "已完成基础链路审计，并记录了断线恢复缺口。" },
      ] }] });
      else if (message.method === "relay/thread/session/subscribe") rpcResult(message, { known: true, isRunning: true, turnId, startedAt: now - 67, items });
      else if (message.method === "relay/thread/goal") rpcResult(message, { goal: { threadId, id: "preview.goal", objective: "完成第二、第三和第四阶段", status: "active", tokenBudget: null, tokensUsed: 2381362, timeUsedSeconds: 4156, createdAt: now - 4900, updatedAt: now - 67 } });
      else if (message.method === "relay/diagnostics/report") rpcResult(message, { generatedAt: new Date().toISOString(), summary: "warning", checks: [
        { id: "bridge", level: "ok", title: "Relay Bridge", detail: "已运行 2 小时 14 分钟" },
        { id: "codex", level: "ok", title: "Codex App Server", detail: "已就绪" },
        { id: "client", level: "ok", title: "远程客户端", detail: "2 台设备已连接" },
        { id: "rpc", level: "ok", title: "请求队列", detail: "没有积压请求" },
        { id: "approval", level: "warning", title: "待处理审批", detail: "1 项操作等待确认" },
      ], metrics: { clients: 2, activeTurns: 1, pendingRpcCount: 0, pendingApprovalCount: 1, queuedPromptCount: 0, uptimeSeconds: 8040 }, events: [
        { id: 2, at: new Date().toISOString(), level: "warning", category: "approval", message: "Codex is waiting for approval." },
        { id: 1, at: new Date(now * 1000 - 64_000).toISOString(), level: "info", category: "socket", message: "Remote client connected." },
      ] });
      else if (message.method === "relay/codex/profiles/list") rpcResult(message, { activeProfileId: "cockpit:user2", profiles: [
        { id: "cockpit:user2", name: "user2", codexHome: "C:\\Users\\preview\\user2", source: "cockpit", active: true, running: true },
        { id: "default", name: "默认 Codex", codexHome: "C:\\Users\\preview\\.codex", source: "default", active: false, running: true },
      ] });
      else if (message.method === "relay/codex/profiles/switch") {
        rpcResult(message, { profile: { id: message.params.profileId, name: message.params.profileId === "default" ? "默认 Codex" : "user2", active: true, running: true } });
        setTimeout(() => emit({ type: "bridgeStatus", status: "ready", codexProfile: { id: message.params.profileId } }), 120);
      }
      else rpcResult(message, {});
      return true;
    },
    pickFiles: async () => [],
    showFile: async () => true,
    readImage: async () => undefined,
    onMessage: (listener) => { messageListeners.add(listener); return () => messageListeners.delete(listener); },
    onState: (listener) => { stateListeners.add(listener); return () => stateListeners.delete(listener); },
    onService: (listener) => { serviceListeners.add(listener); return () => serviceListeners.delete(listener); },
    onUpdate: () => () => {},
  };
}
