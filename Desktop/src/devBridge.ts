export function installDevBridge() {
  if (window.relayDesktop) return;
  const messageListeners = new Set<(message: any) => void>();
  const stateListeners = new Set<(state: any) => void>();
  const serviceListeners = new Set<(state: any) => void>();
  const previewServiceRunning = new URLSearchParams(window.location.search).get("service") !== "stopped";
  const threadId = "preview.thread";
  const turnId = "preview.turn";
  const now = Date.now() / 1000;
  const items = [
    { id: "user.1", type: "userMessage", content: [{ type: "text", text: "检查这个项目，并让桌面端与手机端保持实时同步" }] },
    { id: "reasoning.1", type: "reasoning", summary: ["Inspecting realtime event flow"], content: [] },
    { id: "comment.1", type: "agentMessage", phase: "commentary", text: "我会先核对 Bridge 的事件转发与会话恢复路径，再验证双端是否接收同一组增量事件。" },
    { id: "command.1", type: "commandExecution", command: "npm test", aggregatedOutput: "18 tests passed", status: "completed", exitCode: 0, cwd: "C:\\Projects\\Relay" },
    { id: "comment.2", type: "agentMessage", phase: "commentary", text: "实时通道已经连通。现在正在检查界面折叠、执行计划和断线恢复。" },
  ];
  const emit = (message: any) => messageListeners.forEach((listener) => listener(message));
  const rpcResult = (request: any, result: any) => setTimeout(() => emit({ type: "rpcResult", id: request.id, result }), 15);
  window.relayDesktop = {
    bootstrap: async () => ({ connection: { endpoint: "ws://127.0.0.1:8765", token: "preview-token" }, version: "preview", service: previewServiceRunning ? { state: "running", message: "远程服务已启动" } : { state: "stopped", message: "远程服务未启动" } }),
    serviceStatus: async () => previewServiceRunning ? { state: "running", message: "远程服务已启动" } : { state: "stopped", message: "远程服务未启动" },
    startService: async () => {
      const status = { state: "running" as const, message: "远程服务已启动", connection: { endpoint: "ws://127.0.0.1:8765", token: "preview-token" } };
      serviceListeners.forEach((listener) => listener(status));
      return status;
    },
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
      else if (message.method === "thread/resume") rpcResult(message, { model: "gpt-5.6-sol", reasoningEffort: "high", thread: { id: threadId, status: { type: "active" } }, initialTurnsPage: { data: [{ id: turnId, status: "inProgress", startedAt: now - 67, items }] } });
      else if (message.method === "relay/thread/session/subscribe") rpcResult(message, { known: true, isRunning: true, turnId, startedAt: now - 67, items });
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
  };
}
