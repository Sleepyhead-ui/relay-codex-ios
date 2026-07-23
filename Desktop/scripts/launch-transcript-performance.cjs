const { spawn } = require("node:child_process");
const path = require("node:path");
const electronPath = require("electron");

const env = { ...process.env };
delete env.ELECTRON_RUN_AS_NODE;

const child = spawn(electronPath, [path.join(__dirname, "verify-transcript-performance.cjs")], {
  env,
  stdio: "inherit",
  windowsHide: true,
});

child.on("error", (error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});
child.on("exit", (code) => process.exit(code ?? 1));
