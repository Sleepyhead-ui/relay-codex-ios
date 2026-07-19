import { randomUUID } from "node:crypto";
import { appendFile, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import type { JsonObject } from "./protocol.js";

const MAX_FILE_BYTES = 50 * 1024 * 1024;
export const FILE_CHUNK_BYTES = 512 * 1024;

interface UploadSession {
  path: string;
  name: string;
  expectedSize: number;
  receivedSize: number;
  nextIndex: number;
}

interface DownloadSession {
  path: string;
  name: string;
  size: number;
}

export class FileTransferManager {
  readonly filesRoot: string;
  private readonly allowedRoots: string[];
  private readonly defaultCwd: string | undefined;
  private readonly uploads = new Map<string, UploadSession>();
  private readonly downloads = new Map<string, DownloadSession>();

  constructor(defaultCwd?: string, filesRoot = path.join(homedir(), ".relay", "files")) {
    this.filesRoot = path.resolve(filesRoot);
    this.defaultCwd = defaultCwd ? path.resolve(defaultCwd) : undefined;
    this.allowedRoots = [this.filesRoot, ...(this.defaultCwd ? [this.defaultCwd] : [])];
  }

  async handle(method: string, params: JsonObject): Promise<JsonObject> {
    switch (method) {
    case "relay/file/upload/start": return this.startUpload(params);
    case "relay/file/upload/chunk": return this.uploadChunk(params);
    case "relay/file/upload/finish": return this.finishUpload(params);
    case "relay/file/download/start": return this.startDownload(params);
    case "relay/file/download/chunk": return this.downloadChunk(params);
    case "relay/project/create": return this.createProject(params);
    default: throw new Error(`Unsupported Relay method: ${method}`);
    }
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
    await writeFile(filePath, Buffer.alloc(0), { flag: "wx" });
    this.uploads.set(uploadId, { path: filePath, name, expectedSize: size, receivedSize: 0, nextIndex: 0 });
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
    await appendFile(session.path, data);
    session.receivedSize += data.length;
    session.nextIndex += 1;
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
    return { path: session.path, name: session.name, size: session.receivedSize };
  }

  private async startDownload(params: JsonObject): Promise<JsonObject> {
    const suppliedPath = requiredString(params, "path");
    const requestedPath = path.resolve(path.isAbsolute(suppliedPath) ? suppliedPath : (this.defaultCwd ?? process.cwd()), path.isAbsolute(suppliedPath) ? "" : suppliedPath);
    if (!this.allowedRoots.some((root) => isInside(root, requestedPath))) {
      throw new Error("That file is outside the configured workspace.");
    }
    const info = await stat(requestedPath);
    if (!info.isFile()) throw new Error("The requested path is not a file.");
    if (info.size > MAX_FILE_BYTES) throw new Error("File must be 50 MB or smaller.");
    const downloadId = randomUUID();
    const name = path.basename(requestedPath);
    this.downloads.set(downloadId, { path: requestedPath, name, size: info.size });
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
    const data = (await readFile(session.path)).subarray(offset, Math.min(offset + FILE_CHUNK_BYTES, session.size));
    const done = offset + data.length >= session.size;
    if (done) this.downloads.delete(downloadId);
    return { index, data: data.toString("base64"), done };
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
