param(
    [string]$TaskName = "Relay Codex Bridge",
    [string]$WorkingDirectory = "",
    [switch]$DesktopSync,
    [int]$DesktopCdpPort = 9223
)

$ErrorActionPreference = "Stop"
$startScript = Join-Path $PSScriptRoot "Start-Relay.ps1"
$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startScript`""
if ($WorkingDirectory) {
    $arguments += " -WorkingDirectory `"$WorkingDirectory`""
}
if ($DesktopSync) {
    $arguments += " -DesktopSync -DesktopCdpPort $DesktopCdpPort"
}

try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments -ErrorAction Stop
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME -ErrorAction Stop
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ErrorAction Stop
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Starts Relay Bridge for remote Codex access." -Force -ErrorAction Stop

    Write-Host "Installed scheduled task: $TaskName"
    Write-Host "Run it now from Task Scheduler, or sign out and back in."
}
catch {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runName = "RelayCodexBridge"
    $command = "powershell.exe $arguments"
    New-Item -Path $runKey -Force | Out-Null
    New-ItemProperty -Path $runKey -Name $runName -Value $command -PropertyType String -Force | Out-Null

    Write-Warning "Task Scheduler was unavailable; installed a current-user login startup entry instead."
    Write-Host "Sign out and back in once to verify automatic startup."
}
