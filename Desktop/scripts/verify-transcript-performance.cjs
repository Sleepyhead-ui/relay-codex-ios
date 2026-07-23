const { app, BrowserWindow } = require("electron");
const { spawn } = require("node:child_process");
const http = require("node:http");
const path = require("node:path");

const desktopRoot = path.resolve(__dirname, "..");
const viteEntry = path.join(desktopRoot, "node_modules", "vite", "bin", "vite.js");
const port = 42892;
const url = `http://127.0.0.1:${port}/performance.html`;
let vite;

app.commandLine.appendSwitch("disable-gpu");
app.commandLine.appendSwitch("disable-software-rasterizer");
app.commandLine.appendSwitch("disable-background-timer-throttling");
app.commandLine.appendSwitch("disable-renderer-backgrounding");
app.commandLine.appendSwitch("disable-backgrounding-occluded-windows");

app.whenReady().then(async () => {
  try {
    vite = spawn(process.execPath, [viteEntry, "--host", "127.0.0.1", "--port", String(port), "--strictPort"], {
      cwd: desktopRoot,
      env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let viteError = "";
    vite.stderr.on("data", (chunk) => { viteError += chunk.toString(); });
    await waitForServer(url, 15_000, () => viteError);

    const rendererErrors = [];
    const window = new BrowserWindow({
      show: true,
      skipTaskbar: true,
      focusable: false,
      width: 1280,
      height: 800,
      webPreferences: { contextIsolation: true, sandbox: true, backgroundThrottling: false },
    });
    window.setIgnoreMouseEvents(true);
    window.webContents.on("console-message", (details) => {
      if (["warning", "error"].includes(details.level)) {
        rendererErrors.push(`${details.sourceId}:${details.lineNumber} ${details.message}`);
      }
    });
    window.webContents.on("render-process-gone", (_event, details) => {
      rendererErrors.push(`Renderer exited: ${details.reason} (${details.exitCode})`);
    });
    await window.loadURL(url);
    const result = await waitForHarness(window, 30_000, rendererErrors);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (!result.passed) throw new Error("Transcript performance thresholds were not met.");
    await shutdown(0);
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.stack || error.message : String(error)}\n`);
    await shutdown(1);
  }
});

app.on("window-all-closed", () => {});

function waitForServer(target, timeoutMs, errorText) {
  const startedAt = Date.now();
  return new Promise((resolve, reject) => {
    const probe = () => {
      const request = http.get(target, (response) => {
        response.resume();
        if (response.statusCode === 200) resolve();
        else retry();
      });
      request.on("error", retry);
      request.setTimeout(1_000, () => request.destroy());
    };
    const retry = () => {
      if (Date.now() - startedAt >= timeoutMs) {
        reject(new Error(`Vite did not become ready. ${errorText()}`.trim()));
      } else {
        setTimeout(probe, 100);
      }
    };
    probe();
  });
}

async function waitForHarness(window, timeoutMs, rendererErrors) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const result = await window.webContents.executeJavaScript("window.__relayHarness || null");
    if (result?.complete) return result;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const details = rendererErrors.length ? `\n${rendererErrors.join("\n")}` : "";
  throw new Error(`Transcript performance harness timed out.${details}`);
}

async function shutdown(code) {
  if (vite && !vite.killed) vite.kill();
  app.exit(code);
}
