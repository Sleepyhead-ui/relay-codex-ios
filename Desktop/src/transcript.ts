import type { ApprovalRequest, ModelOption, ThreadSummary, TranscriptItem, TurnMetadata } from "./types";

export interface UserMessagePlacement {
  messageId: string;
  threadId: string;
  turnId?: string;
  afterItemId?: string;
  sequence: number;
}

export function parseThread(value: any): ThreadSummary | null {
  if (!value?.id) return null;
  const status = typeof value.status === "string" ? value.status : value.status?.type || "idle";
  return {
    id: String(value.id),
    title: value.name || value.title || firstLine(value.preview || "新任务"),
    preview: value.preview || "",
    cwd: value.cwd || "",
    updatedAt: numericDate(value.updatedAt ?? value.updated_at ?? value.recencyAt ?? value.createdAt),
    status,
  };
}

export function parseModel(value: any): ModelOption | null {
  const model = value?.model || value?.id;
  if (!model) return null;
  const effortValues = value.supportedReasoningEfforts || value.reasoningEfforts || [];
  const efforts = effortValues
    .map((item: any) => typeof item === "string" ? item : item.reasoningEffort || item.id)
    .filter(Boolean);
  return {
    id: value.id || model,
    model,
    displayName: value.displayName || value.display_name || model,
    description: value.description || "",
    defaultEffort: value.defaultReasoningEffort || value.defaultEffort || efforts[0] || "high",
    efforts,
    isDefault: Boolean(value.isDefault || value.is_default),
  };
}

export function parseTurn(value: any): TurnMetadata | null {
  if (!value?.id) return null;
  return {
    id: String(value.id),
    status: value.status || "completed",
    startedAt: numericDate(value.startedAt),
    completedAt: numericDate(value.completedAt),
    durationMs: value.durationMs,
    error: value.error?.message,
  };
}

export function parseItem(value: any, turnId?: string): TranscriptItem | null {
  if (!value?.id || !value?.type) return null;
  const id = String(value.type === "userMessage" ? value.clientId || value.id : value.id);
  switch (value.type) {
    case "userMessage": {
      const content = userContent(value.content);
      const visible = extractGoalContext(cleanDesktopUserText(content.text));
      return { id, turnId, kind: "user", text: visible.text, imagePaths: content.imagePaths, goal: visible.objective };
    }
    case "agentMessage": return { id, turnId, kind: "assistant", text: value.text || "", phase: value.phase };
    case "reasoning": return { id, turnId, kind: "reasoning", title: "思考", text: arrayText(value.summary), detail: arrayText(value.content) };
    case "commandExecution": return {
      id, turnId, kind: "command", title: "运行命令", text: value.command || "命令",
      detail: value.aggregatedOutput, status: value.status, cwd: value.cwd, exitCode: value.exitCode,
    };
    case "fileChange": return {
      id, turnId, kind: "file", title: "修改文件",
      text: (value.changes || []).map((item: any) => item.path).filter(Boolean).join("\n"),
      detail: (value.changes || []).map((item: any) => item.diff).filter(Boolean).join("\n\n"), status: value.status,
    };
    case "webSearch": return { id, turnId, kind: "tool", title: "搜索网页", text: value.query || "" };
    case "plan": return { id, turnId, kind: "plan", title: "计划", text: value.text || "" };
    case "contextCompaction": return { id, turnId, kind: "compaction", title: "已压缩上下文", text: "Codex 已整理较早的对话内容" };
    case "dynamicToolCall":
    case "mcpToolCall": {
      const name = value.tool || "工具";
      const namespace = value.namespace || value.server || "";
      if (isCommandTool(name, namespace)) {
        return {
          id, turnId, kind: "command", title: "运行命令",
          text: extractCommand(value.arguments ?? value.input) || (name === "exec" ? "执行命令" : name),
          detail: pretty(value.contentItems ?? value.result ?? value.error), status: value.status,
          cwd: value.cwd, exitCode: value.exitCode,
        };
      }
      return {
        id, turnId, kind: "tool", title: friendlyTool(name, namespace), text: friendlyToolSummary(name, namespace),
        detail: pretty(value.contentItems ?? value.result ?? value.arguments), status: value.status,
      };
    }
    default: return { id, turnId, kind: "other", title: value.type, text: value.text || "", detail: pretty(value), status: value.status };
  }
}

export function mergeItem(existing: TranscriptItem | undefined, incoming: TranscriptItem): TranscriptItem {
  if (!existing) return incoming;
  return {
    ...existing, ...incoming,
    id: existing.id,
    text: incoming.text || existing.text,
    detail: incoming.detail || existing.detail,
    turnId: incoming.turnId || existing.turnId,
    phase: incoming.phase || existing.phase,
    title: incoming.title || existing.title,
    status: incoming.status || existing.status,
    imagePaths: incoming.imagePaths?.length ? incoming.imagePaths : existing.imagePaths,
  };
}

export function upsert(items: TranscriptItem[], incoming: TranscriptItem) {
  let index = items.findIndex((item) => item.id === incoming.id);
  if (index < 0) index = items.findIndex((item) => semanticMatch(item, incoming));
  if (index < 0) return [...items, incoming];
  const next = [...items];
  next[index] = mergeItem(next[index], incoming);
  return next;
}

export function bindUserPrompt(items: TranscriptItem[], messageId: string, turnId: string) {
  const index = items.findIndex((item) => item.id === messageId && item.kind === "user");
  if (index < 0) return items;
  const prompt = { ...items[index], turnId };
  const remaining = items.filter((_, itemIndex) => itemIndex !== index);
  const firstTurnItem = remaining.findIndex((item) => item.turnId === turnId);
  const insertion = firstTurnItem >= 0 ? firstTurnItem : Math.min(index, remaining.length);
  return [...remaining.slice(0, insertion), prompt, ...remaining.slice(insertion)];
}

export function applyUserMessagePlacements(
  items: TranscriptItem[],
  placements: Iterable<UserMessagePlacement>,
  threadId: string,
  turnId: string,
) {
  let ordered = items;
  const matching = [...placements]
    .filter((placement) => placement.threadId === threadId && placement.turnId === turnId)
    .sort((left, right) => left.sequence - right.sequence);
  for (const placement of matching) {
    const index = ordered.findIndex((item) => item.id === placement.messageId && item.kind === "user");
    if (index < 0) continue;
    const prompt = { ...ordered[index], turnId };
    const remaining = ordered.filter((_, itemIndex) => itemIndex !== index);
    let insertion: number;
    if (placement.afterItemId) {
      const anchor = remaining.findIndex((item) => item.id === placement.afterItemId);
      insertion = anchor >= 0 ? anchor + 1 : Math.min(index, remaining.length);
    } else {
      const firstTurnItem = remaining.findIndex((item) => item.turnId === turnId);
      insertion = firstTurnItem >= 0 ? firstTurnItem : Math.min(index, remaining.length);
    }
    ordered = [...remaining.slice(0, insertion), prompt, ...remaining.slice(insertion)];
  }
  return ordered;
}

export function mergeSnapshot(existing: TranscriptItem[], snapshot: TranscriptItem[], turnId: string) {
  const outside = existing.filter((item) => item.turnId !== turnId);
  const current = existing.filter((item) => item.turnId === turnId);
  const consumed = new Set<string>();
  const merged = snapshot.map((item) => {
    const match = current.find((candidate) => !consumed.has(candidate.id) && (candidate.id === item.id || semanticMatch(candidate, item)));
    if (!match) return item;
    consumed.add(match.id);
    return mergeItem(match, item);
  });
  merged.push(...current.filter((item) => !consumed.has(item.id)));
  const first = existing.findIndex((item) => item.turnId === turnId);
  if (first < 0) return [...existing, ...merged];
  return [...outside.slice(0, first), ...merged, ...outside.slice(first)];
}

export function applyContextCompaction(items: TranscriptItem[], turnId: string) {
  const next = [...items];
  let summaryIndex = -1;
  for (let index = next.length - 1; index >= 0; index -= 1) {
    const item = next[index]!;
    if (item.turnId === turnId && item.kind === "assistant" && item.phase === "final_answer") {
      summaryIndex = index;
      break;
    }
  }
  if (summaryIndex >= 0) next.splice(summaryIndex, 1);
  if (!next.some((item) => item.turnId === turnId && item.kind === "compaction")) {
    next.push({
      id: `compaction.${turnId}`,
      turnId,
      kind: "compaction",
      title: "已压缩上下文",
      text: "Codex 已整理较早的对话内容",
      status: "completed",
    });
  }
  return next;
}

export function groupProjects(threads: ThreadSummary[]) {
  const groups = new Map<string, ThreadSummary[]>();
  for (const thread of threads) {
    const key = thread.cwd || "未指定项目";
    groups.set(key, [...(groups.get(key) || []), thread]);
  }
  return [...groups.entries()].map(([path, values]) => ({
    path,
    name: path === "未指定项目" ? path : path.split(/[\\/]/).filter(Boolean).at(-1) || path,
    threads: values,
  }));
}

export function filterThreads(threads: ThreadSummary[], query: string) {
  const normalized = query.trim().toLocaleLowerCase();
  if (!normalized) return threads;
  return threads.filter((thread) => [thread.title, thread.preview, thread.cwd]
    .some((value) => value.toLocaleLowerCase().includes(normalized)));
}

export function diffLineKind(line: string) {
  if (/^(\+\+\+|---|diff |index )/.test(line)) return "header";
  if (line.startsWith("@@")) return "hunk";
  if (line.startsWith("+")) return "added";
  if (line.startsWith("-")) return "removed";
  return "context";
}

export function isRunningStatus(status?: string) {
  return /active|running|progress|started|processing|pending|queued/i.test(status || "");
}

export function parseApproval(message: any): ApprovalRequest {
  const method = String(message.method || "approval");
  const params = message.params || {};
  const ownership = {
    threadId: params.threadId || params.thread?.id || params.conversationId,
    turnId: params.turnId || params.turn?.id,
  };
  if (method === "mcpServer/elicitation/request") {
    return { id: message.id, method, params, ...ownership, title: "需要确认", summary: params.message || "Codex 请求继续执行外部操作", detail: params.url };
  }
  if (/commandExecution/i.test(method)) {
    return { id: message.id, method, params, ...ownership, title: "运行这条命令？", summary: params.reason || "Codex 请求运行命令", detail: [params.command, params.cwd].filter(Boolean).join("\n\n") };
  }
  if (/fileChange/i.test(method)) {
    return { id: message.id, method, params, ...ownership, title: "应用文件修改？", summary: params.reason || "Codex 请求修改文件", detail: params.grantRoot };
  }
  if (/permissions/i.test(method)) {
    return { id: message.id, method, params, ...ownership, title: "授予额外权限？", summary: params.reason || "Codex 需要额外权限", detail: pretty(params.permissions) };
  }
  return { id: message.id, method, params, ...ownership, title: "需要确认", summary: params.reason || params.message || method, detail: pretty(params) };
}

export function formatElapsed(startedAt?: number, completedAt?: number, durationMs?: number) {
  const milliseconds = durationMs != null && durationMs > 0
    ? durationMs
    : startedAt ? Math.max(0, (completedAt ?? Date.now() / 1000) - startedAt) * 1000 : durationMs ?? 0;
  const seconds = Math.floor(milliseconds / 1000);
  if (seconds < 60) return `${seconds} 秒`;
  return `${Math.floor(seconds / 60)} 分 ${seconds % 60} 秒`;
}

export function extractGoalContext(value: string): { text: string; objective?: string } {
  let objective: string | undefined;
  const text = value.replace(/<codex_internal_context\b[^>]*\bsource\s*=\s*["']goal["'][^>]*>([\s\S]*?)<\/codex_internal_context>/gi, (_block, content: string) => {
    const match = content.match(/<objective>([\s\S]*?)<\/objective>/i);
    const candidate = match?.[1]?.trim();
    if (!objective && candidate) objective = candidate;
    return "";
  }).replace(/\n{3,}/g, "\n\n").trim();
  return { text, objective };
}

function semanticMatch(left: TranscriptItem, right: TranscriptItem) {
  if (left.turnId !== right.turnId || left.kind !== right.kind) return false;
  if (left.kind === "assistant") return left.phase === right.phase && normalized(left.text) !== "" && normalized(left.text) === normalized(right.text);
  if (["command", "file", "reasoning", "plan", "compaction"].includes(left.kind)) {
    const leftText = normalized(left.text || left.detail || "");
    const rightText = normalized(right.text || right.detail || "");
    return leftText !== "" && leftText === rightText;
  }
  return false;
}

function isCommandTool(name: string, namespace: string) {
  const normalizedName = name.toLowerCase();
  const combined = `${namespace} ${name}`.toLowerCase();
  return ["exec", "exec_command", "shell_command"].includes(normalizedName) || /\s(?:exec_command|shell_command)/.test(combined);
}

function extractCommand(value: any): string | undefined {
  if (value && typeof value === "object") return value.command || value.cmd || value.script;
  if (typeof value !== "string" || !value.trim()) return undefined;
  const raw = value.trim();
  try {
    const nested = JSON.parse(raw);
    if (nested !== raw) return extractCommand(nested);
  } catch {}
  const match = raw.match(/\bcommand\s*:\s*("(?:\\.|[^"\\])*")/s);
  if (match?.[1]) {
    try { return JSON.parse(match[1]); } catch {}
  }
  return raw.includes("tools.shell_command") ? undefined : raw;
}

function contentText(content: any[]) {
  return (content || []).map((item) => item.text || (item.path ? `附件 ${item.name || item.path.split(/[\\/]/).at(-1)}` : "")).filter(Boolean).join("\n");
}
function userContent(content: any[]) {
  const imagePaths: string[] = [];
  const text = (content || []).map((item) => {
    if (item?.path && ["localImage", "image"].includes(item.type)) {
      imagePaths.push(String(item.path));
      return "";
    }
    if (item?.text) {
      const parsed = extractImageMarkup(String(item.text));
      imagePaths.push(...parsed.imagePaths);
      return parsed.text;
    }
    return item?.path ? `附件 ${item.name || item.path.split(/[\\/]/).at(-1)}` : "";
  }).filter(Boolean).join("\n");
  return { text, imagePaths: [...new Set(imagePaths)] };
}
function extractImageMarkup(value: string) {
  const imagePaths: string[] = [];
  const text = value.replace(/<image\b[^>]*\bpath\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))[^>]*>/gi, (_match, doubleQuoted, singleQuoted, bare) => {
    const imagePath = doubleQuoted || singleQuoted || bare;
    if (imagePath) imagePaths.push(imagePath);
    return "";
  }).replace(/\n{3,}/g, "\n\n").trim();
  return { text, imagePaths };
}
function cleanDesktopUserText(value: string) {
  const marker = /^\s*#{0,6}\s*My request for Codex:\s*$/im.exec(value);
  return marker ? value.slice((marker.index || 0) + marker[0].length).trim() : value;
}
function arrayText(values: any[]) { return (values || []).map((item) => typeof item === "string" ? item : item.text || "").filter(Boolean).join("\n\n"); }
function friendlyTool(name = "工具", namespace = "") {
  const value = `${namespace} ${name}`.toLowerCase();
  if (/node_repl|computer/.test(value)) return "控制 Windows 应用";
  if (/browser|playwright/.test(value)) return "操作浏览器";
  if (/image/.test(value)) return "处理图片";
  return name;
}
function friendlyToolSummary(name = "工具", namespace = "") {
  const value = `${namespace} ${name}`.toLowerCase();
  if (/node_repl|computer/.test(value)) return "正在与 Windows 应用交互";
  if (/browser|playwright/.test(value)) return "正在操作浏览器";
  return name;
}
function pretty(value: unknown) { if (value == null) return undefined; if (typeof value === "string") return value; try { return JSON.stringify(value, null, 2); } catch { return String(value); } }
function normalized(value: string) { return value.replace(/\s+/g, " ").trim(); }
function firstLine(value: string) { return value.split(/\r?\n/)[0]?.slice(0, 72) || "新任务"; }
function numericDate(value: any) { const number = Number(value || 0); return number > 1e12 ? number / 1000 : number; }
