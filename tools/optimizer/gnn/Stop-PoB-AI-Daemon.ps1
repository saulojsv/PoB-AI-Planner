param(
    [string]$RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'PathOfBuilding\AIPlanner\runtime')
)
$ErrorActionPreference = 'Stop'
$PythonExe = Join-Path $RuntimeRoot 'python.exe'
$EndpointPath = Join-Path $RuntimeRoot 'endpoint.json'
if (-not (Test-Path -LiteralPath $EndpointPath)) {
    Write-Output 'PoB AI daemon is already stopped.'
    exit 0
}
$Endpoint = Get-Content -LiteralPath $EndpointPath -Raw | ConvertFrom-Json
$DaemonPid = 0
if ($Endpoint.protocol -ne 'windows_named_pipe' -or -not [int]::TryParse([string]$Endpoint.pid, [ref]$DaemonPid)) {
    throw 'Endpoint metadata is invalid; refusing to stop an unrelated process.'
}
$Process = Get-CimInstance Win32_Process -Filter "ProcessId=$DaemonPid"
if (-not $Process) {
    Remove-Item -LiteralPath $EndpointPath -Force
    Write-Output 'Removed a stale PoB AI daemon endpoint.'
    exit 0
}
if ($Process.ExecutablePath -ne $PythonExe -or $Process.CommandLine -notmatch 'tools\.optimizer\.gnn\.daemon') {
    throw 'Endpoint PID does not identify the private PoB AI daemon; refusing to stop it.'
}
Stop-Process -Id $DaemonPid -Force
$Deadline = (Get-Date).AddSeconds(10)
while ((Get-Process -Id $DaemonPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $Deadline) {
    Start-Sleep -Milliseconds 100
}
if (Get-Process -Id $DaemonPid -ErrorAction SilentlyContinue) {
    throw 'PoB AI daemon did not stop within 10 seconds.'
}
if (Test-Path -LiteralPath $EndpointPath) {
    $CurrentEndpoint = Get-Content -LiteralPath $EndpointPath -Raw | ConvertFrom-Json
    if ($CurrentEndpoint.pid -eq $DaemonPid) { Remove-Item -LiteralPath $EndpointPath -Force }
}
Write-Output 'PoB AI daemon stopped.'
