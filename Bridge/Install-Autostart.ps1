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

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Starts Relay Bridge for remote Codex access." -Force

Write-Host "Installed scheduled task: $TaskName"
Write-Host "Run it now from Task Scheduler, or sign out and back in."
