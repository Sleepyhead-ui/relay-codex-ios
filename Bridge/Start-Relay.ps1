param(
    [string]$ListenAddress = "",
    [int]$Port = 8765,
    [string]$AdvertiseAddress = "",
    [string]$WorkingDirectory = "",
    [switch]$DesktopSync
)

$ErrorActionPreference = "Stop"

$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCommand) {
    throw "Node.js 20 or newer is required. Install it from https://nodejs.org/."
}
$nodePath = $nodeCommand.Source

$nodeMajor = [int]((& $nodePath --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 20) {
    throw "Node.js 20 or newer is required. Current version: $(& $nodePath --version)"
}

if (-not $ListenAddress) {
    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($tailscale) {
        $ListenAddress = (tailscale ip -4 | Select-Object -First 1).Trim()
    }
}

if (-not $ListenAddress) {
    $ListenAddress = "127.0.0.1"
    Write-Warning "Tailscale was not detected. Relay will only be reachable from this PC."
}

if (-not $AdvertiseAddress) {
    $AdvertiseAddress = $ListenAddress
}

$env:RELAY_HOST = $ListenAddress
$env:RELAY_PORT = "$Port"
$env:RELAY_ADVERTISE_URL = "ws://${AdvertiseAddress}:$Port"
$env:RELAY_DESKTOP_SYNC = if ($DesktopSync) { "true" } else { "false" }
if ($WorkingDirectory) {
    $env:RELAY_DEFAULT_CWD = (Resolve-Path -LiteralPath $WorkingDirectory).Path
}

Push-Location $PSScriptRoot
try {
    $bundledCodex = Join-Path $PSScriptRoot "node_modules\@openai\codex\bin\codex.js"
    if (-not (Test-Path -LiteralPath $bundledCodex)) {
        Write-Host "Installing Relay Bridge dependencies..."
        $npmCli = Join-Path (Split-Path -Parent $nodePath) "node_modules\npm\bin\npm-cli.js"
        if (-not (Test-Path -LiteralPath $npmCli)) {
            throw "npm-cli.js was not found next to Node.js. Reinstall Node.js with npm included."
        }
        & $nodePath $npmCli ci
        if ($LASTEXITCODE -ne 0) { throw "Relay dependency installation failed with exit code $LASTEXITCODE." }
    }

    $tsc = Join-Path $PSScriptRoot "node_modules\typescript\bin\tsc"
    & $nodePath $tsc -p (Join-Path $PSScriptRoot "tsconfig.json")
    if ($LASTEXITCODE -ne 0) { throw "Relay Bridge build failed with exit code $LASTEXITCODE." }

    & $nodePath (Join-Path $PSScriptRoot "dist\index.js")
    if ($LASTEXITCODE -ne 0) { throw "Relay Bridge exited with code $LASTEXITCODE." }
}
finally {
    Pop-Location
}
