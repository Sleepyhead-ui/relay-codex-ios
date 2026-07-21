const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const esbuild = require("esbuild");

const desktopRoot = path.resolve(__dirname, "..");
const relayRoot = path.resolve(desktopRoot, "..");
const bridgeRoot = path.join(relayRoot, "Bridge");
const runtimeRoot = path.join(desktopRoot, "bridge-runtime");
const npmCli = path.join(path.dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js");

run(process.execPath, [npmCli, "run", "build"], bridgeRoot);
fs.rmSync(runtimeRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(runtimeRoot, "dist"), { recursive: true });
esbuild.buildSync({
  entryPoints: [path.join(bridgeRoot, "src", "index.ts")],
  outfile: path.join(runtimeRoot, "dist", "index.cjs"),
  bundle: true,
  platform: "node",
  format: "cjs",
  target: "node22",
  sourcemap: false,
  logOverride: { "empty-import-meta": "silent" },
});
fs.copyFileSync(path.join(bridgeRoot, "package.json"), path.join(runtimeRoot, "package.json"));
fs.copyFileSync(path.join(bridgeRoot, "package-lock.json"), path.join(runtimeRoot, "package-lock.json"));
run(process.execPath, [npmCli, "ci", "--omit=dev", "--prefer-offline", "--no-audit", "--no-fund"], runtimeRoot);
fs.renameSync(path.join(runtimeRoot, "node_modules"), path.join(runtimeRoot, "vendor"));

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, stdio: "inherit", windowsHide: true });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status || 1);
}
