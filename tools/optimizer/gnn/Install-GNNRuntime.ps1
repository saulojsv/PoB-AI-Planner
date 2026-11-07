param(
    [string]$RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'PathOfBuilding\AIPlanner\runtime'),
    [switch]$SkipTorchInstall
)
$ErrorActionPreference = 'Stop'
$PythonVersion = '3.12.10'
$PythonZipUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
$PythonZip = Join-Path $env:TEMP "pob-python-$PythonVersion-embed.zip"
New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
$PythonExe = Join-Path $RuntimeRoot 'python.exe'
if (-not (Test-Path -LiteralPath $PythonExe)) {
    Invoke-WebRequest -Uri $PythonZipUrl -OutFile $PythonZip
    Expand-Archive -LiteralPath $PythonZip -DestinationPath $RuntimeRoot -Force
    Remove-Item -LiteralPath $PythonZip -Force
    $Pth = Join-Path $RuntimeRoot 'python312._pth'
    $PthText = Get-Content -LiteralPath $Pth -Raw
    $PthText = $PthText -replace '(?m)^#import site\s*$', 'import site'
    if ($PthText -notmatch '(?m)^Lib\\site-packages$') { $PthText += [Environment]::NewLine + 'Lib\site-packages' + [Environment]::NewLine }
    Set-Content -LiteralPath $Pth -Value $PthText -Encoding ASCII
    $GetPip = Join-Path $env:TEMP 'pob-get-pip.py'
    Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $GetPip
    & $PythonExe $GetPip --no-warn-script-location
    if ($LASTEXITCODE -ne 0) { throw "pip bootstrap failed with exit code $LASTEXITCODE" }
    Remove-Item -LiteralPath $GetPip -Force
}
if (-not $SkipTorchInstall) {
    & $PythonExe -m pip install --disable-pip-version-check 'torch==2.6.0' --index-url 'https://download.pytorch.org/whl/cpu'
    if ($LASTEXITCODE -ne 0) { throw "CPU PyTorch installation failed with exit code $LASTEXITCODE" }
    & $PythonExe -m pip install --disable-pip-version-check 'torch-geometric==2.6.1'
    if ($LASTEXITCODE -ne 0) { throw "PyTorch Geometric installation failed with exit code $LASTEXITCODE" }
}
& $PythonExe -c "import torch, torch_geometric; print({'python':__import__('sys').version,'torch':torch.__version__,'pyg':torch_geometric.__version__})"
if ($LASTEXITCODE -ne 0) { throw 'Private GNN runtime verification failed' }
