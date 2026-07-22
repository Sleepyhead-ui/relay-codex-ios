import { createReadStream, createWriteStream } from "node:fs";
import { createHash } from "node:crypto";
import { mkdir, rename, rm, stat } from "node:fs/promises";
import path from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";

const latestReleaseUrl = "https://api.github.com/repos/Sleepyhead-ui/relay-codex-ios/releases/latest";
const maximumIPABytes = 100 * 1024 * 1024;
const maximumDigestBytes = 512;

export interface ReleaseAsset {
  id?: number;
  name: string;
  url?: string;
  browser_download_url: string;
  size: number;
}

export interface UpdateDownloadProgress {
  phase: "connecting" | "downloading" | "verifying" | "retrying";
  downloadedBytes: number;
  totalBytes: number;
  attempt: number;
}

interface GitHubRelease {
  tag_name: string;
  html_url: string;
  published_at: string;
  body?: string;
  assets: ReleaseAsset[];
}

export class UpdateManager {
  constructor(private readonly filesRoot: string) {}

  async check(currentVersion: string): Promise<Record<string, unknown>> {
    const release = await fetchLatestRelease();
    const ipa = selectIPAAsset(release.assets);
    const latestVersion = normalizeVersion(release.tag_name);
    return {
      currentVersion: normalizeVersion(currentVersion),
      latestVersion,
      available: compareVersions(latestVersion, currentVersion) > 0,
      releaseUrl: release.html_url,
      publishedAt: release.published_at,
      notes: release.body ?? "",
      ipa: ipa ? { name: ipa.name, size: ipa.size } : null,
    };
  }

  async downloadIOS(onProgress: (progress: UpdateDownloadProgress) => void = () => {}): Promise<Record<string, unknown>> {
    const release = await fetchLatestRelease();
    const asset = selectIPAAsset(release.assets);
    if (!asset) throw new Error("The latest release does not include Relay.ipa.");
    if (asset.size <= 0 || asset.size > maximumIPABytes) throw new Error("The IPA asset size is invalid.");
    const digestAsset = selectDigestAsset(release.assets);
    if (!digestAsset) throw new Error("The latest release does not include Relay.ipa.sha256.");
    const expectedDigest = await fetchExpectedDigest(digestAsset);

    const directory = path.join(this.filesRoot, "updates");
    const version = normalizeVersion(release.tag_name);
    const destination = path.join(directory, `Relay-v${version}.ipa`);
    const partial = `${destination}.partial`;
    await mkdir(directory, { recursive: true });
    const existing = await stat(destination).catch(() => undefined);
    if (existing?.isFile() && existing.size === asset.size && await sha256(destination) === expectedDigest) {
      return { path: destination, name: path.basename(destination), size: existing.size, version };
    }

    let lastError: unknown;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      await rm(partial, { force: true }).catch(() => {});
      try {
        onProgress({ phase: "connecting", downloadedBytes: 0, totalBytes: asset.size, attempt });
        const response = await fetchReleaseAsset(asset, "application/octet-stream");
        if (!response.body) throw new Error("GitHub returned an empty IPA response.");
        let downloadedBytes = 0;
        let lastProgressAt = 0;
        const meter = new Transform({
          transform(chunk, _encoding, callback) {
            downloadedBytes += chunk.length;
            const now = Date.now();
            if (now - lastProgressAt >= 250 || downloadedBytes === asset.size) {
              lastProgressAt = now;
              onProgress({ phase: "downloading", downloadedBytes, totalBytes: asset.size, attempt });
            }
            callback(null, chunk);
          },
        });
        await pipeline(Readable.fromWeb(response.body as never), meter, createWriteStream(partial, { flags: "wx" }));
        const info = await stat(partial);
        if (info.size !== asset.size || info.size > maximumIPABytes) throw new Error("The downloaded IPA size did not match the release asset.");
        onProgress({ phase: "verifying", downloadedBytes: info.size, totalBytes: asset.size, attempt });
        if (await sha256(partial) !== expectedDigest) throw new Error("The downloaded IPA failed SHA-256 verification.");
        await rename(partial, destination);
        return { path: destination, name: path.basename(destination), size: info.size, version };
      } catch (error) {
        lastError = error;
        await rm(partial, { force: true }).catch(() => {});
        if (attempt < 3) {
          onProgress({ phase: "retrying", downloadedBytes: 0, totalBytes: asset.size, attempt });
          await delay(attempt * 1_000);
        }
      }
    }
    throw new Error(`GitHub IPA 下载失败，已自动重试 3 次：${errorMessage(lastError)}`);
  }
}

export function compareVersions(left: string, right: string): number {
  const a = normalizeVersion(left).split(".").map((part) => Number.parseInt(part, 10) || 0);
  const b = normalizeVersion(right).split(".").map((part) => Number.parseInt(part, 10) || 0);
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    if ((a[index] ?? 0) !== (b[index] ?? 0)) return (a[index] ?? 0) > (b[index] ?? 0) ? 1 : -1;
  }
  return 0;
}

export function selectIPAAsset(assets: ReleaseAsset[]): ReleaseAsset | undefined {
  return assets.find((asset) => asset.name === "Relay.ipa" && /^https:\/\/github\.com\/Sleepyhead-ui\/relay-codex-ios\/releases\/download\//i.test(asset.browser_download_url));
}

export function selectDigestAsset(assets: ReleaseAsset[]): ReleaseAsset | undefined {
  return assets.find((asset) => asset.name === "Relay.ipa.sha256" && asset.size > 0 && asset.size <= maximumDigestBytes
    && /^https:\/\/github\.com\/Sleepyhead-ui\/relay-codex-ios\/releases\/download\//i.test(asset.browser_download_url));
}

async function fetchExpectedDigest(asset: ReleaseAsset): Promise<string> {
  const response = await fetchReleaseAsset(asset, "text/plain");
  const text = await response.text();
  if (Buffer.byteLength(text, "utf8") > maximumDigestBytes) throw new Error("The IPA digest asset is invalid.");
  const match = /^([a-f0-9]{64})(?:\s+\*?Relay\.ipa)?\s*$/i.exec(text);
  if (!match?.[1]) throw new Error("The IPA digest asset is invalid.");
  return match[1].toLowerCase();
}

async function sha256(filePath: string): Promise<string> {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(filePath)) hash.update(chunk);
  return hash.digest("hex");
}

function normalizeVersion(value: string): string {
  return value.trim().replace(/^v/i, "").split("-")[0] ?? "0.0.0";
}

async function fetchLatestRelease(): Promise<GitHubRelease> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      const response = await fetch(latestReleaseUrl, {
        headers: { Accept: "application/vnd.github+json", "User-Agent": "Relay-Codex-Bridge", "X-GitHub-Api-Version": "2022-11-28" },
        signal: AbortSignal.timeout(20_000),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return await response.json() as GitHubRelease;
    } catch (error) {
      lastError = error;
      if (attempt < 3) await delay(attempt * 500);
    }
  }
  throw new Error(`无法连接 GitHub 检查 Relay 更新：${errorMessage(lastError)}`);
}

async function fetchReleaseAsset(asset: ReleaseAsset, accept: string): Promise<Response> {
  const urls = releaseAssetUrls(asset);
  const failures: string[] = [];
  for (const url of urls) {
    try {
      const requestAccept = new URL(url).hostname === "api.github.com" ? "application/octet-stream" : accept;
      const response = await fetch(url, {
        headers: { Accept: requestAccept, "User-Agent": "Relay-Codex-Bridge", "X-GitHub-Api-Version": "2022-11-28" },
        redirect: "follow",
        signal: AbortSignal.timeout(90_000),
      });
      if (response.ok) return response;
      failures.push(`${new URL(url).hostname}: HTTP ${response.status}`);
    } catch (error) {
      failures.push(`${new URL(url).hostname}: ${errorMessage(error)}`);
    }
  }
  throw new Error(failures.join("；") || "没有可用的 GitHub 下载地址");
}

export function releaseAssetUrls(asset: ReleaseAsset): string[] {
  const urls: string[] = [];
  if (Number.isInteger(asset.id) && Number(asset.id) > 0) {
    urls.push(`https://api.github.com/repos/Sleepyhead-ui/relay-codex-ios/releases/assets/${asset.id}`);
  }
  if (/^https:\/\/github\.com\/Sleepyhead-ui\/relay-codex-ios\/releases\/download\//i.test(asset.browser_download_url)) {
    urls.push(asset.browser_download_url);
  }
  return [...new Set(urls)];
}

function errorMessage(error: unknown): string {
  if (!(error instanceof Error)) return String(error);
  const cause = error.cause instanceof Error ? ` (${error.cause.message})` : "";
  return `${error.message}${cause}`;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
