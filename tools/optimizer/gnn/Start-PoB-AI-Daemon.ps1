param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
    [string]$RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'PathOfBuilding\AIPlanner\runtime'),
    [string]$ApprovedRoot = 'G:\O meu disco\00 - Projetos\PoB - IA\04_Models_Approved'
)
$ErrorActionPreference = 'Stop'
$PythonExe = Join-Path $RuntimeRoot 'python.exe'
if (-not (Test-Path -LiteralPath $PythonExe)) { throw "Private runtime not found. Run Install-GNNRuntime.ps1 first." }
$EndpointPath = Join-Path $RuntimeRoot 'endpoint.json'
if (Test-Path -LiteralPath $EndpointPath) {
    try { $ExistingEndpoint = Get-Content -LiteralPath $EndpointPath -Raw | ConvertFrom-Json } catch { throw 'Existing daemon endpoint is malformed; inspect it before starting another worker.' }
    $ExistingPid = 0
    if ($ExistingEndpoint.protocol -ne 'windows_named_pipe' -or -not [int]::TryParse([string]$ExistingEndpoint.pid, [ref]$ExistingPid)) {
        throw 'Existing daemon endpoint metadata is invalid; refusing to overwrite it.'
    }
    $ExistingProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$ExistingPid"
    if ($ExistingProcess -and $ExistingProcess.ExecutablePath -eq $PythonExe -and $ExistingProcess.CommandLine -match 'tools\.optimizer\.gnn\.daemon') {
        throw "The per-user PoB AI daemon is already running (PID $ExistingPid). Run Stop-PoB-AI-Daemon.ps1 before restarting it."
    }
    if (-not $ExistingProcess) { Remove-Item -LiteralPath $EndpointPath -Force }
}
$SitePackages = Join-Path $RuntimeRoot 'Lib\site-packages'
$PackageTarget = Join-Path $SitePackages 'tools\optimizer\gnn'
New-Item -ItemType Directory -Force -Path $PackageTarget | Out-Null
Copy-Item -Path (Join-Path $RepoRoot 'tools\optimizer\gnn\*') -Destination $PackageTarget -Recurse -Exclude '__pycache__' -Force
foreach ($PackageInit in @((Join-Path $SitePackages 'tools\__init__.py'), (Join-Path $SitePackages 'tools\optimizer\__init__.py'))) {
    if (-not (Test-Path -LiteralPath $PackageInit)) { New-Item -ItemType File -Path $PackageInit -Force | Out-Null }
}
Set-Location -LiteralPath $RepoRoot
$env:OMP_NUM_THREADS = '1'
$env:MKL_NUM_THREADS = '1'
$env:OPENBLAS_NUM_THREADS = '1'
$env:NUMEXPR_NUM_THREADS = '1'
& $PythonExe -m tools.optimizer.gnn.daemon --approved-dir $ApprovedRoot
exit $LASTEXITCODE
