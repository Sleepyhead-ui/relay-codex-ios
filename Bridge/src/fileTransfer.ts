import { randomUUID } from "node:crypto";
import { mkdir, open, rm, stat, type FileHandle } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import type { JsonObject } from "./protocol.js";

const MAX_FILE_BYTES = 50 * 1024 * 1024;
const MAX_IMAGE_BYTES = 25 * 1024 * 1024;
const IMAGE_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".heif"]);
export const FILE_CHUNK_BYTES = 512 * 1024;

interface UploadSession {
  path: string;
  name: string;
  handle: FileHandle;
  expectedSize: number;
  receivedSize: number;
  nextIndex: number;
  lastActivityAt: number;
}

interface DownloadSession {
  path: string;
  name: string;
  size: number;
  handle: FileHandle;
  lastActivityAt: number;
}

export class FileTransferManager {
  readonly filesRoot: string;
  private readonly allowedRoots = new Set<string>();
  private readonly defaultCwd: string | undefined;
  private readonly uploads = new Map<string, UploadSession>();
  private readonly downloads = new Map<string, DownloadSession>();
  private readonly cleanupTimer: NodeJS.Timeout;

  constructor(
    defaultCwd?: string,
    filesRoot = path.join(homedir(), ".relay", "files"),
    private readonly sessionTtlMs = 10 * 60_000,
  ) {
    this.filesRoot = path.resolve(filesRoot);
    this.defaultCwd = defaultCwd ? path.resolve(defaultCwd) : undefined;
    this.allowedRoots.add(this.filesRoot);
    if (this.defaultCwd) this.allowedRoots.add(this.defaultCwd);
    this.cleanupTimer = setInterval(() => { void this.cleanupExpired(); }, Math.min(sessionTtlMs, 60_000));
    this.cleanupTimer.unref();
  }

  get activeTransferCount(): number {
    return this.uploads.size + this.downloads.size;
  }

  allowWorkspace(workspace: unknown): void {
    if (typeof workspace !== "string" || !workspace.trim()) return;
    this.allowedRoots.add(path.resolve(workspace));
  }

  async handle(method: string, params: JsonObject): Promise<JsonObject> {
    switch (method) {
    case "relay/file/upload/start": return this.startUpload(params);
    case "relay/file/upload/chunk": return this.uploadChunk(params);
    case "relay/file/upload/finish": return this.finishUpload(params);
    case "relay/file/upload/cancel": return this.cancelUpload(params);
    case "relay/file/download/start": return this.startDownload(params);
    case "relay/image/download/start": return this.startImageDownload(params);
    case "relay/file/download/chunk": return this.downloadChunk(params);
    case "relay/file/download/cancel": return this.cancelDownload(params);
    case "relay/project/create": return this.createProject(params);
    default: throw new Error(`Unsupported Relay method: ${method}`);
    }
  }

  async cleanupExpired(now = Date.now()): Promise<void> {
    const uploads = [...this.uploads.entries()].filter(([, session]) => now - session.lastActivityAt >= this.sessionTtlMs);
    const downloads = [...this.downloads.entries()].filter(([, session]) => now - session.lastActivityAt >= this.sessionTtlMs);
    await Promise.all([
      ...uploads.map(([id]) => this.releaseUpload(id, true)),
      ...downloads.map(([id]) => this.releaseDownload(id)),
    ]);
  }

  async dispose(): Promise<void> {
    clearInterval(this.cleanupTimer);
    await Promise.all([
      ...[...this.uploads.keys()].map((id) => this.releaseUpload(id, true)),
      ...[...this.downloads.keys()].map((id) => this.releaseDownload(id)),
    ]);
  }

  private async createProject(params: JsonObject): Promise<JsonObject> {
    if (!this.defaultCwd) throw new Error("Configure a default project directory on Relay Bridge first.");
    const suppliedName = requiredString(params, "name").trim();
    const name = safeName(suppliedName);
    if (name !== suppliedName) throw new Error("Project folder names cannot contain Windows path separators or reserved characters.");
    const projectPath = path.resolve(this.defaultCwd, name);
    if (!isInside(this.defaultCwd, projectPath) || projectPath === this.defaultCwd) {
      throw new Error("The project folder must be inside the default project directory.");
    }
    await mkdir(projectPath, { recursive: false });
    return { path: projectPath, name };
  }

  private async startUpload(params: JsonObject): Promise<JsonObject> {
    const name = safeName(requiredString(params, "name"));
    const size = requiredInteger(params, "size");
    if (size < 0 || size > MAX_FILE_BYTES) throw new Error("File must be 50 MB or smaller.");
    const uploadId = randomUUID();
    const directory = path.join(this.filesRoot, uploadId);
    const filePath = path.join(directory, name);
    await mkdir(directory, { recursive: true });
    const handle = await open(filePath, "wx");
    this.uploads.set(uploadId, { path: filePath, name, handle, expectedSize: size, receivedSize: 0, nextIndex: 0, lastActivityAt: Date.now() });
    return { uploadId, chunkSize: FILE_CHUNK_BYTES };
  }

  private async uploadChunk(params: JsonObject): Promise<JsonObject> {
    const uploadId = requiredString(params, "uploadId");
    const session = this.uploads.get(uploadId);
    if (!session) throw new Error("Upload expired or was not found.");
    const index = requiredInteger(params, "index");
    if (index !== session.nextIndex) throw new Error(`Expected upload chunk ${session.nextIndex}.`);
    const data = Buffer.from(requiredString(params, "data"), "base64");
    if (data.length > FILE_CHUNK_BYTES) throw new Error("Upload chunk is too large.");
    if (session.receivedSize + data.length > session.expectedSize) throw new Error("Upload exceeds the declared file size.");
    await writeAll(session.handle, data, session.receivedSize);
    session.receivedSize += data.length;
    session.nextIndex += 1;
    session.lastActivityAt = Date.now();
    return { received: session.receivedSize, nextIndex: session.nextIndex };
  }

  private async finishUpload(params: JsonObject): Promise<JsonObject> {
    const uploadId = requiredString(params, "uploadId");
    const session = this.uploads.get(uploadId);
    if (!session) throw new Error("Upload expired or was not found.");
    if (session.receivedSize !== session.expectedSize) {
      throw new Error(`Upload is incomplete (${session.receivedSize} of ${session.expectedSize} bytes).`);
    }
    this.uploads.delete(uploadId);
    await session.handle.close();
    return { path: session.path, name: session.name, size: session.receivedSize };
  }

  private async cancelUpload(params: JsonObject): Promise<JsonObject> {
    return { cancelled: await this.releaseUpload(requiredString(params, "uploadId"), true) };
  }

  private async startDownload(params: JsonObject): Promise<JsonObject> {
    const suppliedPath = requiredString(params, "path");
    const requestedPath = path.resolve(path.isAbsolute(suppliedPath) ? suppliedPath : (this.defaultCwd ?? process.cwd()), path.isAbsolute(suppliedPath) ? "" : suppliedPath);
    if (![...this.allowedRoots].some((root) => isInside(root, requestedPath))) {
      throw new Error("That file is outside the configured workspace.");
    }
    return this.createDownload(requestedPath, MAX_FILE_BYTES);
  }

  private async startImageDownload(params: JsonObject): Promise<JsonObject> {
    const requestedPath = path.resolve(requiredString(params, "path"));
    if (!path.isAbsolute(requiredString(params, "path")) || !IMAGE_EXTENSIONS.has(path.extname(requestedPath).toLowerCase())) {
      throw new Error("Only supported image files can be previewed.");
    }
    return this.createDownload(requestedPath, MAX_IMAGE_BYTES);
  }

  private async createDownload(requestedPath: string, maximumBytes: number): Promise<JsonObject> {
    const info = await stat(requestedPath);
    if (!info.isFile()) throw new Error("The requested path is not a file.");
    if (info.size > maximumBytes) throw new Error(`File must be ${Math.floor(maximumBytes / 1024 / 1024)} MB or smaller.`);
    const downloadId = randomUUID();
    const name = path.basename(requestedPath);
    const handle = await open(requestedPath, "r");
    this.downloads.set(downloadId, { path: requestedPath, name, size: info.size, handle, lastActivityAt: Date.now() });
    return { downloadId, name, size: info.size, chunkSize: FILE_CHUNK_BYTES };
  }

  private async downloadChunk(params: JsonObject): Promise<JsonObject> {
    const downloadId = requiredString(params, "downloadId");
    const session = this.downloads.get(downloadId);
    if (!session) throw new Error("Download expired or was not found.");
    const index = requiredInteger(params, "index");
    if (index < 0) throw new Error("Invalid download chunk index.");
    const offset = index * FILE_CHUNK_BYTES;
    if (offset > session.size) throw new Error("Download chunk is out of range.");
    const length = Math.min(FILE_CHUNK_BYTES, session.size - offset);
    const buffer = Buffer.allocUnsafe(length);
    let bytesRead = 0;
    if (length > 0) ({ bytesRead } = await session.handle.read(buffer, 0, length, offset));
    session.lastActivityAt = Date.now();
    const data = buffer.subarray(0, bytesRead);
    const done = offset + data.length >= session.size;
    if (done) await this.releaseDownload(downloadId);
    return { index, data: data.toString("base64"), done };
  }

  private async cancelDownload(params: JsonObject): Promise<JsonObject> {
    return { cancelled: await this.releaseDownload(requiredString(params, "downloadId")) };
  }

  private async releaseUpload(id: string, removePartial: boolean): Promise<boolean> {
    const session = this.uploads.get(id);
    if (!session) return false;
    this.uploads.delete(id);
    await session.handle.close().catch(() => {});
    if (removePartial) await rm(path.dirname(session.path), { recursive: true, force: true }).catch(() => {});
    return true;
  }

  private async releaseDownload(id: string): Promise<boolean> {
    const session = this.downloads.get(id);
    if (!session) return false;
    this.downloads.delete(id);
    await session.handle.close().catch(() => {});
    return true;
  }
}

async function writeAll(handle: FileHandle, data: Buffer, position: number): Promise<void> {
  let offset = 0;
  while (offset < data.length) {
    const { bytesWritten } = await handle.write(data, offset, data.length - offset, position + offset);
    if (bytesWritten <= 0) throw new Error("Could not write the upload chunk.");
    offset += bytesWritten;
  }
}

function requiredString(params: JsonObject, key: string): string {
  const value = params[key];
  if (typeof value !== "string" || !value) throw new Error(`Missing ${key}.`);
  return value;
}

function requiredInteger(params: JsonObject, key: string): number {
  const value = params[key];
  if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new Error(`Invalid ${key}.`);
  return value;
}

function safeName(value: string): string {
  const name = path.basename(value).replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").trim();
  if (!name || name === "." || name === "..") throw new Error("Invalid file name.");
  return name.slice(0, 180);
}

function isInside(root: string, candidate: string): boolean {
  const relative = path.relative(path.resolve(root), candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}
