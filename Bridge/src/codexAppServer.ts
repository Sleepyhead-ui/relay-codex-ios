import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import type { JsonObject } from "./protocol.js";
import { isObject } from "./protocol.js";

export interface CodexMessageHandlers {
  onResponse(message: JsonObject): void;
  onNotification(message: JsonObject): void;
  onRequest(message: JsonObject): void;
  onLog(message: string): void;
  onExit(code: number | null, signal: NodeJS.Signals | null): void;
}

export class CodexAppServer {
  private process: ChildProcessWithoutNullStreams | null = null;
  private initialized = false;

  constructor(
    private readonly executable: string,
    private readonly handlers: CodexMessageHandlers,
  ) {}

  async start(): Promise<void> {
    if (this.process) return;

    const isJavaScriptEntrypoint = this.executable.toLowerCase().endsWith(".js");
    const command = isJavaScriptEntrypoint ? process.execPath : this.executable;
    const args = isJavaScriptEntrypoint
      ? [this.executable, "app-server", "--listen", "stdio://"]
      : ["app-server", "--listen", "stdio://"];
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      env: process.env,
    });
    this.process = child;

    const stdout = createInterface({ input: child.stdout });
    stdout.on("line", (line) => this.handleLine(line));
    child.stderr.on("data", (chunk: Buffer) => this.handlers.onLog(chunk.toString("utf8").trimEnd()));
    child.on("error", (error) => this.handlers.onLog(`Codex process error: ${error.message}`));
    child.on("exit", (code, signal) => {
      this.process = null;
      this.initialized = false;
      this.handlers.onExit(code, signal);
    });

    this.send({
      method: "initialize",
      id: "relay.initialize",
      params: {
        clientInfo: { name: "relay_ios", title: "Relay", version: "0.6.10" },
        capabilities: { experimentalApi: true },
      },
    });
  }

  send(message: JsonObject): void {
    if (!this.process?.stdin.writable) throw new Error("Codex App Server is not running.");
    this.process.stdin.write(`${JSON.stringify(message)}\n`);
  }

  stop(): void {
    this.process?.kill();
  }

  private handleLine(line: string): void {
    let message: unknown;
    try {
      message = JSON.parse(line);
    } catch {
      this.handlers.onLog(`Ignored non-JSON Codex output: ${line}`);
      return;
    }
    if (!isObject(message)) return;

    if (message.id === "relay.initialize" && "result" in message) {
      this.initialized = true;
      this.send({ method: "initialized", params: {} });
      this.handlers.onLog("Codex App Server initialized.");
      return;
    }

    if ("id" in message && ("result" in message || "error" in message)) {
      this.handlers.onResponse(message);
    } else if ("id" in message && typeof message.method === "string") {
      this.handlers.onRequest(message);
    } else if (typeof message.method === "string") {
      this.handlers.onNotification(message);
    }
  }
}
