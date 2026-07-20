import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { FileTransferManager } from "../dist/fileTransfer.js";

test("uploads and downloads a file in chunks", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-transfer-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const manager = new FileTransferManager(root, path.join(root, ".relay-files"));
  const payload = Buffer.from("Relay 文件传输 ".repeat(80_000));

  const started = await manager.handle("relay/file/upload/start", { name: "测试.txt", size: payload.length });
  const chunkSize = started.chunkSize;
  for (let offset = 0, index = 0; offset < payload.length; offset += chunkSize, index += 1) {
    await manager.handle("relay/file/upload/chunk", {
      uploadId: started.uploadId,
      index,
      data: payload.subarray(offset, offset + chunkSize).toString("base64"),
    });
  }
  const uploaded = await manager.handle("relay/file/upload/finish", { uploadId: started.uploadId });
  assert.deepEqual(await readFile(uploaded.path), payload);

  const download = await manager.handle("relay/file/download/start", { path: uploaded.path });
  const chunks = [];
  for (let index = 0, done = false; !done; index += 1) {
    const chunk = await manager.handle("relay/file/download/chunk", { downloadId: download.downloadId, index });
    chunks.push(Buffer.from(chunk.data, "base64"));
    done = chunk.done;
  }
  assert.deepEqual(Buffer.concat(chunks), payload);
});

test("rejects downloads outside allowed roots and invalid chunk order", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-transfer-"));
  const outside = await mkdtemp(path.join(tmpdir(), "relay-outside-"));
  t.after(() => Promise.all([rm(root, { recursive: true, force: true }), rm(outside, { recursive: true, force: true })]));
  const manager = new FileTransferManager(root, path.join(root, ".relay-files"));
  const outsideFile = path.join(outside, "secret.txt");
  await writeFile(outsideFile, "secret");
  await assert.rejects(() => manager.handle("relay/file/download/start", { path: outsideFile }), /outside/);

  const started = await manager.handle("relay/file/upload/start", { name: "a.txt", size: 1 });
  await assert.rejects(() => manager.handle("relay/file/upload/chunk", {
    uploadId: started.uploadId, index: 1, data: "YQ==",
  }), /Expected upload chunk 0/);
});

test("previews supported images outside the workspace without exposing other files", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-transfer-"));
  const outside = await mkdtemp(path.join(tmpdir(), "relay-preview-"));
  t.after(() => Promise.all([rm(root, { recursive: true, force: true }), rm(outside, { recursive: true, force: true })]));
  const manager = new FileTransferManager(root, path.join(root, ".relay-files"));
  const image = path.join(outside, "screen.png");
  const text = path.join(outside, "secret.txt");
  const payload = Buffer.from("not-a-real-png-but-valid-transfer-data");
  await writeFile(image, payload);
  await writeFile(text, "secret");

  const download = await manager.handle("relay/image/download/start", { path: image });
  const chunk = await manager.handle("relay/file/download/chunk", { downloadId: download.downloadId, index: 0 });
  assert.deepEqual(Buffer.from(chunk.data, "base64"), payload);
  assert.equal(chunk.done, true);
  await assert.rejects(() => manager.handle("relay/image/download/start", { path: text }), /supported image/);
});

test("creates project folders only under the configured default directory", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-project-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const manager = new FileTransferManager(root, path.join(root, ".relay-files"));

  const created = await manager.handle("relay/project/create", { name: "mobile-project" });
  assert.equal(created.path, path.join(root, "mobile-project"));
  assert.equal((await stat(created.path)).isDirectory(), true);
  await assert.rejects(() => manager.handle("relay/project/create", { name: "..\\outside" }), /cannot contain/);
});
