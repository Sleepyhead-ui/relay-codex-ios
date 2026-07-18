param(
    [string]$ListenAddress = "",
    [int]$Port = 8765,
    [string]$AdvertiseAddress = "",
    [string]$WorkingDirectory = ""
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "Node.js 20 or newer is required. Install it from https://nodejs.org/."
}

$nodeMajor = [int]((node --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 20) {
    throw "Node.js 20 or newer is required. Current version: $(node --version)"
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
if ($WorkingDirectory) {
    $env:RELAY_DEFAULT_CWD = (Resolve-Path -LiteralPath $WorkingDirectory).Path
}

Push-Location $PSScriptRoot
try {
    $bundledCodex = Join-Path $PSScriptRoot "node_modules\@openai\codex\bin\codex.js"
    if (-not (Test-Path -LiteralPath $bundledCodex)) {
        Write-Host "Installing Relay Bridge dependencies..."
        npm ci
    }
    npm start
}
finally {
    Pop-Location
}
