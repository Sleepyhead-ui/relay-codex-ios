import { describe, expect, it } from "vitest";
import { bindUserPrompt, mergeSnapshot, parseItem } from "./transcript";

describe("desktop transcript", () => {
  it("extracts the actual shell command from an exec wrapper", () => {
    const item = parseItem({
      id: "tool.1",
      type: "dynamicToolCall",
      tool: "exec",
      arguments: 'const result = await tools.shell_command({ command: "Get-ChildItem -Force" });',
      result: "Exit code: 0",
      status: "completed",
    }, "turn.1");
    expect(item?.kind).toBe("command");
    expect(item?.text).toBe("Get-ChildItem -Force");
    expect(item?.detail).toContain("Exit code: 0");
  });

  it("removes the desktop attachment wrapper from user prompts", () => {
    const item = parseItem({
      id: "user.1",
      type: "userMessage",
      content: [{ type: "text", text: "# Files mentioned by the user:\n\nimage.png: C:\\\\Temp\\\\image.png\n\n## My request for Codex:\n\n输入文字应该正常显示" }],
    }, "turn.1");
    expect(item?.text).toBe("输入文字应该正常显示");
  });

  it("keeps local images as structured user-message media", () => {
    const item = parseItem({
      id: "user.image",
      type: "userMessage",
      content: [
        { type: "localImage", path: "C:\\Temp\\screen.png" },
        { type: "text", text: "查看这张截图" },
      ],
    }, "turn.1");
    expect(item?.text).toBe("查看这张截图");
    expect(item?.imagePaths).toEqual(["C:\\Temp\\screen.png"]);
  });

  it("turns Codex image markup into media without showing the raw tag", () => {
    const item = parseItem({
      id: "user.image-markup",
      type: "userMessage",
      content: [
        { type: "localImage", path: "C:\\Temp\\screen.png" },
        { type: "text", text: "查看这张截图\n\n<image name=[Image #1] path=\"C:\\Temp\\screen.png\">" },
      ],
    }, "turn.1");
    expect(item?.text).toBe("查看这张截图");
    expect(item?.imagePaths).toEqual(["C:\\Temp\\screen.png"]);
  });

  it("deduplicates matching progress from app-server and rollout snapshots", () => {
    const existing = [{ id: "live.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查同步状态" }];
    const snapshot = [{ id: "rollout.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查同步状态" }];
    const merged = mergeSnapshot(existing, snapshot, "turn.1");
    expect(merged).toHaveLength(1);
    expect(merged[0].id).toBe("live.1");
  });

  it("preserves two commands when the same command genuinely ran twice", () => {
    const existing = [
      { id: "live.1", turnId: "turn.1", kind: "command" as const, text: "npm test" },
      { id: "live.2", turnId: "turn.1", kind: "command" as const, text: "npm test" },
    ];
    const snapshot = [
      { id: "file.1", turnId: "turn.1", kind: "command" as const, text: "npm test" },
      { id: "file.2", turnId: "turn.1", kind: "command" as const, text: "npm test" },
    ];
    expect(mergeSnapshot(existing, snapshot, "turn.1")).toHaveLength(2);
  });

  it("moves an optimistic user prompt before activity as soon as the turn id is known", () => {
    const messages = [
      { id: "progress.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查" },
      { id: "user.1", kind: "user" as const, text: "帮我安装桌面端" },
      { id: "command.1", turnId: "turn.1", kind: "command" as const, text: "Get-Item setup.exe" },
    ];
    const bound = bindUserPrompt(messages, "user.1", "turn.1");
    expect(bound.map((item) => item.id)).toEqual(["user.1", "progress.1", "command.1"]);
    expect(bound[0].turnId).toBe("turn.1");
  });
});
