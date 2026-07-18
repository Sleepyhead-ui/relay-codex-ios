param(
    [string]$ListenAddress = "",
    [int]$Port = 8765,
    [string]$AdvertiseAddress = "",
    [string]$WorkingDirectory = "",
    [switch]$DesktopSync,
    [int]$DesktopCdpPort = 9223
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
$env:RELAY_DESKTOP_CDP_PORT = "$DesktopCdpPort"
if ($WorkingDirectory) {
    $env:RELAY_DEFAULT_CWD = (Resolve-Path -LiteralPath $WorkingDirectory).Path
}

if ($DesktopSync) {
    $package = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue | Select-Object -First 1
    $chatGptExe = if ($package) { Join-Path $package.InstallLocation "app\ChatGPT.exe" } else { "" }
    $env:RELAY_DESKTOP_APP_PATH = if ($chatGptExe -and (Test-Path -LiteralPath $chatGptExe)) { $chatGptExe } else { "" }
    $cdpReady = $false
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$DesktopCdpPort/json/version" -TimeoutSec 1
        $cdpReady = $response.StatusCode -eq 200
    }
    catch {}

    if (-not $cdpReady) {
        $runningCodex = Get-Process -Name ChatGPT -ErrorAction SilentlyContinue
        if ($runningCodex) {
            Write-Warning "Enhanced desktop sync will activate after Codex is fully closed and reopened. Deep-link fallback remains active for this session."
        }
        else {
            if ($chatGptExe -and (Test-Path -LiteralPath $chatGptExe)) {
                Write-Host "Starting Codex with enhanced desktop sync on localhost:$DesktopCdpPort..."
                Start-Process -FilePath $chatGptExe -ArgumentList "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=$DesktopCdpPort"
            }
            else {
                Write-Warning "Codex desktop app was not found. Deep-link desktop sync will be used."
            }
        }
    }
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
