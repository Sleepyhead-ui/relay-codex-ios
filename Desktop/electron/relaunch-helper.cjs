const { execFile, spawn } = require("node:child_process");
const path = require("node:path");

const target = process.argv[2];
if (!target) process.exit(1);

const imageName = path.basename(target);
let attempts = 0;

function desktopIsRunning(callback) {
  execFile("tasklist.exe", ["/FI", `IMAGENAME eq ${imageName}`, "/FO", "CSV", "/NH"], { windowsHide: true }, (_error, stdout) => {
    callback(String(stdout).toLowerCase().includes(`"${imageName.toLowerCase()}"`));
  });
}

function ensureRelaunched() {
  desktopIsRunning((running) => {
    if (running) process.exit(0);
    attempts += 1;
    try {
      const child = spawn(target, ["--relay-after-update"], {
        detached: true,
        windowsHide: true,
        stdio: "ignore",
      });
      child.once("error", retry);
      child.unref();
      setTimeout(() => desktopIsRunning((started) => started ? process.exit(0) : retry()), 5_000);
    } catch {
      retry();
    }
  });
}

function retry() {
  if (attempts >= 12) process.exit(1);
  setTimeout(ensureRelaunched, 5_000);
}

setTimeout(ensureRelaunched, 15_000);
