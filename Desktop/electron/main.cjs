const { app, BrowserWindow, dialog, ipcMain, Notification, shell } = require("electron");
const fs = require("node:fs");
const http = require("node:http");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { WebSocket } = require("ws");
const { autoUpdater } = require("electron-updater");
const { serviceStateFromHealth, updateReadinessForService } = require("./update-policy.cjs");
const { reconnectDelayMs, stableConnectionResetMs } = require("./connection-policy.cjs");

let mainWindow;
let socket;
let reconnectTimer;
let stableConnectionTimer;
let reconnectAttempt = 0;
let connectionConfig;
let intentionalClose = false;
let serviceState = "stopped";
let serviceMessage = "";
let autoServiceTimer;
let deferredInstallTimer;
let checkingDeferredInstall = false;
let resumeServiceAfterUpdate = false;
let updateState = { state: "idle", currentVersion: app.getVersion() };

const configPath = () => path.join(app.getPath("userData"), "connection.json");
const preferencesPath = () => path.join(app.getPath("userData"), "preferences.json");
const resumeServicePath = () => path.join(app.getPath("userData"), "resume-service-after-update");

const hasSingleInstanceLock = app.requestSingleInstanceLock();
if (!hasSingleInstanceLock) app.quit();
app.on("second-instance", () => {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
});

function readPreferences() {
  try { return { autoStart: false, notifications: true, ...JSON.parse(fs.readFileSync(preferencesPath(), "utf8")) }; }
  catch { return { autoStart: false, notifications: true }; }
}

function writePreferences(value) {
  fs.mkdirSync(path.dirname(preferencesPath()), { recursive: true });
  fs.writeFileSync(preferencesPath(), JSON.stringify(value, null, 2), "utf8");
}

function scheduleAutomaticServiceStart() {
  if (autoServiceTimer) clearInterval(autoServiceTimer);
  const attempt = async () => {
    if ((!readPreferences().autoStart && !resumeServiceAfterUpdate) || serviceState === "running" || serviceState === "starting") return;
    try {
      await startRemoteService();
      if (resumeServiceAfterUpdate) {
        resumeServiceAfterUpdate = false;
        try { fs.unlinkSync(resumeServicePath()); } catch {}
      }
    } catch {}
  };
  setTimeout(() => void attempt(), 1_500).unref();
  autoServiceTimer = setInterval(() => void attempt(), 15_000);
  autoServiceTimer.unref();
}

function defaultEndpoint() {
  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const address of addresses || []) {
      if (address.family === "IPv4" && !address.internal && address.address.startsWith("100.")) {
        return `ws://${address.address}:8765`;
      }
    }
  }
  return "ws://127.0.0.1:8765";
}

function readConnectionConfig() {
  try {
    return JSON.parse(fs.readFileSync(configPath(), "utf8"));
  } catch {
    let token = "";
    try { token = fs.readFileSync(path.join(os.homedir(), ".relay", "token"), "utf8").trim(); } catch {}
    return { endpoint: defaultEndpoint(), token };
  }
}

function saveConnectionConfig(value) {
  fs.mkdirSync(path.dirname(configPath()), { recursive: true });
  fs.writeFileSync(configPath(), JSON.stringify(value, null, 2), "utf8");
}

function localServiceEndpoint() {
  const endpoint = defaultEndpoint();
  if (endpoint.includes("127.0.0.1")) throw new Error("请先在 Windows 上连接 Tailscale，再启动远程服务。");
  return endpoint;
}

function bridgeRoot() {
  return app.isPackaged
    ? path.join(process.resourcesPath, "bridge")
    : path.resolve(__dirname, "..", "..", "Bridge");
}

function ensureServiceRuntime() {
  if (!app.isPackaged) {
    return { host: process.execPath, bridge: bridgeRoot(), helper: path.join(__dirname, "relaunch-helper.cjs") };
  }
  const root = path.join(app.getPath("userData"), "service-runtime", app.getVersion());
  const bridge = path.join(root, "bridge");
  const host = path.join(bridge, "node.exe");
  const helper = path.join(root, "relaunch-helper.cjs");
  const marker = path.join(root, ".complete");
  if (!fs.existsSync(marker) || !fs.existsSync(host)) {
    fs.rmSync(root, { recursive: true, force: true });
    fs.mkdirSync(root, { recursive: true });
    fs.cpSync(bridgeRoot(), bridge, { recursive: true, force: true });
    fs.copyFileSync(path.join(__dirname, "relaunch-helper.cjs"), helper);
    fs.writeFileSync(marker, `${app.getVersion()}\n`, "utf8");
  }
  return { host, bridge, helper };
}

function publishService() {
  publish("relay:service", {
    state: serviceState,
    message: serviceMessage,
    ...(connectionConfig ? { connection: connectionConfig } : {}),
  });
}

function publishUpdate(patch) {
  updateState = { ...updateState, ...patch };
  publish("relay:update", updateState);
  return updateState;
}

autoUpdater.autoDownload = false;
autoUpdater.autoInstallOnAppQuit = false;
autoUpdater.on("checking-for-update", () => publishUpdate({ state: "checking", message: "正在检查更新" }));
autoUpdater.on("update-available", (info) => publishUpdate({ state: "available", version: info.version, message: `Relay Desktop ${info.version} 可用` }));
autoUpdater.on("update-not-available", () => publishUpdate({ state: "current", version: app.getVersion(), message: "当前已是最新版本" }));
autoUpdater.on("download-progress", (progress) => publishUpdate({ state: "downloading", percent: Math.round(progress.percent), message: `正在下载 ${Math.round(progress.percent)}%` }));
autoUpdater.on("update-downloaded", (info) => publishUpdate({ state: "ready", version: info.version, percent: 100, message: "更新已下载，重启后安装" }));
autoUpdater.on("error", (error) => publishUpdate({ state: "error", message: error.message }));

async function inspectRemoteService() {
  let endpoint;
  try { endpoint = localServiceEndpoint(); }
  catch (error) {
    serviceState = "stopped";
    serviceMessage = error.message;
    publishService();
    return { state: serviceState, message: serviceMessage };
  }
  const health = await readHealth(endpoint).catch(() => undefined);
  serviceState = serviceStateFromHealth(health);
  serviceMessage = serviceState === "running" ? "远程服务已启动"
    : serviceState === "degraded" ? "远程服务在线，桌面端尚未接入"
    : health ? "Codex 正在初始化" : "远程服务未启动";
  publishService();
  return { state: serviceState, message: serviceMessage, endpoint, health };
}

async function startRemoteService() {
  const current = await inspectRemoteService();
  if (!current.endpoint) throw new Error(current.message || "请先连接 Tailscale。");
  if (current.health) return finalizeLocalConnection(current.endpoint, current);

  const runtime = ensureServiceRuntime();
  const entry = path.join(runtime.bridge, "dist", "index.cjs");
  if (!fs.existsSync(entry)) throw new Error("Relay 内置远程服务缺失，请重新安装 Desktop。");
  const endpoint = current.endpoint;
  const url = new URL(endpoint);
  const logDirectory = path.join(app.getPath("userData"), "logs");
  fs.mkdirSync(logDirectory, { recursive: true });
  const log = fs.openSync(path.join(logDirectory, "bridge.log"), "a");
  serviceState = "starting";
  serviceMessage = "正在启动远程服务";
  publishService();
  const child = spawn(runtime.host, [entry], {
    detached: true,
    windowsHide: true,
    stdio: ["ignore", log, log],
    env: {
      ...process.env,
      ELECTRON_RUN_AS_NODE: "1",
      RELAY_HOST: url.hostname,
      RELAY_PORT: url.port || "8765",
      RELAY_ADVERTISE_URL: endpoint,
      RELAY_DESKTOP_SYNC: "false",
      RELAY_DESKTOP_CDP_PORT: "9223",
      CODEX_BIN: path.join(runtime.bridge, "vendor", "@openai", "codex-win32-x64", "vendor", "x86_64-pc-windows-msvc", "bin", "codex.exe"),
    },
  });
  child.unref();
  fs.closeSync(log);
  fs.mkdirSync(path.join(os.homedir(), ".relay"), { recursive: true });
  fs.writeFileSync(path.join(os.homedir(), ".relay", "bridge.pid"), `${child.pid}\n`, "utf8");

  for (let attempt = 0; attempt < 50; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 200));
    const health = await readHealth(endpoint).catch(() => undefined);
    if (health?.status === "ready" || health?.status === "starting") {
      return finalizeLocalConnection(endpoint, { state: health.status === "ready" ? "running" : "starting", health });
    }
  }
  serviceState = "failed";
  serviceMessage = "远程服务启动超时，请查看设置中的诊断信息";
  publishService();
  throw new Error(serviceMessage);
}

function finalizeLocalConnection(endpoint, result) {
  let token = "";
  try { token = fs.readFileSync(path.join(os.homedir(), ".relay", "token"), "utf8").trim(); } catch {}
  if (!token) throw new Error("远程服务尚未生成连接 Token，请稍后重试。");
  connectionConfig = { endpoint, token };
  saveConnectionConfig(connectionConfig);
  serviceState = result.state === "running" ? "running" : "starting";
  serviceMessage = serviceState === "running" ? "远程服务已启动" : "Codex 正在初始化";
  openSocket(connectionConfig);
  publishService();
  return { ...result, state: serviceState, message: serviceMessage, connection: connectionConfig };
}

async function updateReadiness() {
  let endpoint;
  try { endpoint = localServiceEndpoint(); } catch { return { health: undefined, blockers: [] }; }
  const health = await readHealth(endpoint).catch(() => undefined);
  return { health, blockers: updateReadinessForService(health, serviceState) };
}

function scheduleDeferredInstall() {
  if (deferredInstallTimer) return;
  deferredInstallTimer = setInterval(async () => {
    if (checkingDeferredInstall || updateState.state !== "deferred") return;
    checkingDeferredInstall = true;
    try {
      const readiness = await updateReadiness();
      if (readiness.blockers.length === 0) performUpdateInstall(readiness.health);
      else publishUpdate({ message: `等待任务结束后更新：${readiness.blockers.join("；")}`, blockers: readiness.blockers });
    } finally {
      checkingDeferredInstall = false;
    }
  }, 3_000);
  deferredInstallTimer.unref();
}

function performUpdateInstall(health) {
  if (deferredInstallTimer) clearInterval(deferredInstallTimer);
  deferredInstallTimer = undefined;
  const runtime = ensureServiceRuntime();
  if (health) fs.writeFileSync(resumeServicePath(), `${Date.now()}\n`, "utf8");
  const helper = spawn(runtime.host, [runtime.helper, process.execPath], {
    detached: true,
    windowsHide: true,
    stdio: "ignore",
    env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
  });
  helper.on("error", (error) => publishUpdate({ message: `更新已开始；自动重启守护程序启动失败：${error.message}` }));
  helper.unref();
  publishUpdate({ state: "installing", message: "正在安装，Relay Desktop 将自动重新打开", blockers: [] });
  setImmediate(() => autoUpdater.quitAndInstall(false, true));
}

async function requestUpdateInstall() {
  const readiness = await updateReadiness();
  if (readiness.blockers.length > 0) {
    scheduleDeferredInstall();
    return publishUpdate({
      state: "deferred",
      message: `等待任务结束后更新：${readiness.blockers.join("；")}`,
      blockers: readiness.blockers,
    });
  }
  performUpdateInstall(readiness.health);
  return updateState;
}

function readHealth(endpoint) {
  return new Promise((resolve, reject) => {
    const url = new URL(endpoint);
    url.protocol = url.protocol === "wss:" ? "https:" : "http:";
    url.pathname = "/health";
    url.search = "";
    const client = url.protocol === "https:" ? https : http;
    const request = client.get(url, { timeout: 1_200 }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => {
        try { resolve(JSON.parse(body)); } catch (error) { reject(error); }
      });
    });
    request.on("timeout", () => request.destroy(new Error("timeout")));
    request.on("error", reject);
  });
}

function publish(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(channel, payload);
}

function scheduleReconnect() {
  if (intentionalClose || reconnectTimer || !connectionConfig) return;
  clearStableConnectionTimer();
  reconnectAttempt += 1;
  const delay = reconnectDelayMs(reconnectAttempt);
  publish("relay:state", { state: "reconnecting", attempt: reconnectAttempt });
  reconnectTimer = setTimeout(() => {
    reconnectTimer = undefined;
    openSocket(connectionConfig);
  }, delay);
}

function openSocket(config) {
  intentionalClose = false;
  connectionConfig = config;
  clearStableConnectionTimer();
  if (reconnectTimer) clearTimeout(reconnectTimer);
  reconnectTimer = undefined;
  if (socket) {
    socket.removeAllListeners();
    socket.terminate();
  }
  publish("relay:state", { state: reconnectAttempt ? "reconnecting" : "connecting", attempt: reconnectAttempt });
  try {
    socket = new WebSocket(config.endpoint, { headers: { Authorization: `Bearer ${config.token}` } });
  } catch (error) {
    publish("relay:state", { state: "failed", message: error.message });
    scheduleReconnect();
    return;
  }
  socket.on("open", () => publish("relay:state", { state: "handshaking" }));
  socket.on("message", (data) => {
    let message;
    try { message = JSON.parse(data.toString("utf8")); } catch { return; }
    publish("relay:message", message);
    if (message.type === "bridgeStatus" && message.status === "ready") {
      clearStableConnectionTimer();
      stableConnectionTimer = setTimeout(() => {
        stableConnectionTimer = undefined;
        if (!intentionalClose && socket?.readyState === WebSocket.OPEN) reconnectAttempt = 0;
      }, stableConnectionResetMs);
      stableConnectionTimer.unref();
      serviceState = "running";
      serviceMessage = "远程服务已启动";
      publishService();
      publish("relay:state", { state: "connected", desktopSync: message.desktopSync });
    }
  });
  socket.on("close", () => {
    publish("relay:state", { state: "disconnected" });
    scheduleReconnect();
  });
  socket.on("error", (error) => publish("relay:state", { state: "error", message: error.message }));
}

function clearStableConnectionTimer() {
  if (stableConnectionTimer) clearTimeout(stableConnectionTimer);
  stableConnectionTimer = undefined;
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1380,
    height: 900,
    minWidth: 940,
    minHeight: 660,
    backgroundColor: "#111210",
    titleBarStyle: "hidden",
    titleBarOverlay: { color: "#171816", symbolColor: "#a9aca6", height: 42 },
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  mainWindow.setMenu(null);
  if (process.env.VITE_DEV_SERVER_URL) mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL);
  else mainWindow.loadFile(path.join(__dirname, "..", "dist", "index.html"));
}

app.whenReady().then(() => {
  if (!hasSingleInstanceLock) return;
  const preferences = readPreferences();
  resumeServiceAfterUpdate = fs.existsSync(resumeServicePath());
  app.setLoginItemSettings({ openAtLogin: Boolean(preferences.autoStart), path: process.execPath });
  createWindow();
  if (preferences.autoStart || resumeServiceAfterUpdate) scheduleAutomaticServiceStart();
  app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });
app.on("before-quit", () => { intentionalClose = true; clearStableConnectionTimer(); socket?.close(); });

ipcMain.handle("relay:bootstrap", async () => {
  const service = await inspectRemoteService();
  let connection = readConnectionConfig();
  if (service.health && service.endpoint) {
    try { connection = finalizeLocalConnection(service.endpoint, service).connection; } catch {}
  }
  return { connection, version: app.getVersion(), service, preferences: readPreferences() };
});
ipcMain.handle("relay:update-status", () => updateState);
ipcMain.handle("relay:check-update", async () => {
  if (!app.isPackaged) return publishUpdate({ state: "current", message: "开发版本不检查更新" });
  await autoUpdater.checkForUpdates();
  return updateState;
});
ipcMain.handle("relay:download-update", async () => {
  await autoUpdater.downloadUpdate();
  return updateState;
});
ipcMain.handle("relay:install-update", () => requestUpdateInstall());
ipcMain.handle("relay:set-preferences", (_event, patch) => {
  const preferences = { ...readPreferences(), ...(patch || {}) };
  writePreferences(preferences);
  app.setLoginItemSettings({ openAtLogin: Boolean(preferences.autoStart), path: process.execPath });
  if (preferences.autoStart) scheduleAutomaticServiceStart();
  else if (autoServiceTimer) { clearInterval(autoServiceTimer); autoServiceTimer = undefined; }
  return preferences;
});
ipcMain.handle("relay:notify", (_event, payload) => {
  if (!readPreferences().notifications || mainWindow?.isFocused() || !Notification.isSupported()) return false;
  new Notification({ title: String(payload?.title || "Relay"), body: String(payload?.body || "") }).show();
  return true;
});
ipcMain.handle("relay:export-diagnostics", async (_event, report) => {
  const result = await dialog.showSaveDialog(mainWindow, {
    defaultPath: `Relay-Diagnostics-${Date.now()}.json`,
    filters: [{ name: "JSON", extensions: ["json"] }],
  });
  if (result.canceled || !result.filePath) return false;
  fs.writeFileSync(result.filePath, JSON.stringify(report, null, 2), "utf8");
  return true;
});
ipcMain.handle("relay:service-status", () => inspectRemoteService());
ipcMain.handle("relay:start-service", () => startRemoteService());
ipcMain.handle("relay:connect", (_event, config) => {
  if (!/^wss?:\/\//i.test(config.endpoint || "") || !(config.token || "").trim()) throw new Error("连接地址或 Token 无效。");
  saveConnectionConfig(config);
  reconnectAttempt = 0;
  openSocket(config);
  return true;
});
ipcMain.handle("relay:disconnect", () => {
  intentionalClose = true;
  clearStableConnectionTimer();
  if (reconnectTimer) clearTimeout(reconnectTimer);
  reconnectTimer = undefined;
  socket?.close();
  socket = undefined;
});
ipcMain.handle("relay:send", (_event, message) => {
  if (!socket || socket.readyState !== WebSocket.OPEN) throw new Error("Bridge 尚未连接。");
  socket.send(JSON.stringify(message));
  return true;
});
ipcMain.handle("relay:pick-files", async () => {
  const result = await dialog.showOpenDialog(mainWindow, { properties: ["openFile", "multiSelections"] });
  return result.canceled ? [] : result.filePaths;
});
ipcMain.handle("relay:show-file", async (_event, filePath) => {
  if (typeof filePath !== "string" || !path.isAbsolute(filePath)) return false;
  shell.showItemInFolder(filePath);
  return true;
});
ipcMain.handle("relay:read-image", async (_event, filePath) => {
  if (typeof filePath !== "string" || !path.isAbsolute(filePath)) return undefined;
  const mimeTypes = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
    ".webp": "image/webp", ".bmp": "image/bmp", ".heic": "image/heic", ".heif": "image/heif",
  };
  const mimeType = mimeTypes[path.extname(filePath).toLowerCase()];
  if (!mimeType) return undefined;
  try {
    const stats = fs.statSync(filePath);
    if (!stats.isFile() || stats.size > 25 * 1024 * 1024) return undefined;
    return `data:${mimeType};base64,${fs.readFileSync(filePath).toString("base64")}`;
  } catch {
    return undefined;
  }
});
