[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TunnelId,

    [Parameter(Mandatory = $false)]
    [string]$TunnelClientPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$mcpServerPath = Join-Path $repoRoot 'plugins\pob-ai-planner\server\index.js'
if (-not (Test-Path -LiteralPath $mcpServerPath -PathType Leaf)) {
    throw "PoB MCP server file was not found: $mcpServerPath"
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    throw 'Node.js was not found on PATH. Install a supported Node.js runtime, reopen PowerShell, and retry.'
}

if ([string]::IsNullOrWhiteSpace($TunnelClientPath)) {
    $tunnelCommand = Get-Command tunnel-client -ErrorAction SilentlyContinue
    if (-not $tunnelCommand) {
        throw 'tunnel-client was not found. Download it from OpenAI Platform tunnel settings, then add its folder to PATH or pass -TunnelClientPath.'
    }
    $tunnelClient = $tunnelCommand.Source
} else {
    $tunnelClient = (Resolve-Path -LiteralPath $TunnelClientPath).Path
}

if ([string]::IsNullOrWhiteSpace($TunnelId)) {
    $TunnelId = Read-Host 'OpenAI Secure MCP tunnel_id'
}
if ([string]::IsNullOrWhiteSpace($TunnelId) -or $TunnelId.Length -gt 128 -or $TunnelId -match '[\r\n\t ]') {
    throw 'TunnelId must be a non-empty tunnel ID without whitespace.'
}

$profileName = 'pob-ai-planner-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$mcpCommand = '"' + $node.Source + '" "' + $mcpServerPath + '"'
$secureKey = $null
$keyPointer = [IntPtr]::Zero
$previousProcessKey = [Environment]::GetEnvironmentVariable('CONTROL_PLANE_API_KEY', 'Process')

try {
    $secureKey = Read-Host 'OpenAI tunnel-client runtime API key (input is masked; never paste it into chat)' -AsSecureString
    if ($null -eq $secureKey -or $secureKey.Length -eq 0) {
        throw 'A runtime API key is required to run tunnel-client.'
    }
    $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
    [Environment]::SetEnvironmentVariable('CONTROL_PLANE_API_KEY', $plainKey, 'Process')
    $plainKey = $null

    Write-Host "Creating a local stdio profile named $profileName. The profile stores the tunnel ID and local MCP command, not the runtime API key."
    & $tunnelClient init --sample sample_mcp_stdio_local --profile $profileName --tunnel-id $TunnelId --mcp-command $mcpCommand
    if ($LASTEXITCODE -ne 0) {
        throw "tunnel-client init failed with exit code $LASTEXITCODE. No secret was passed as a command-line argument."
    }

    & $tunnelClient doctor --profile $profileName --explain
    if ($LASTEXITCODE -ne 0) {
        throw "tunnel-client doctor failed with exit code $LASTEXITCODE. Review the profile and tunnel permissions, then retry."
    }

    Write-Host 'Starting the private PoB MCP tunnel. Keep this window and Path of Building open while using the connector.'
    Write-Host 'In ChatGPT, add a custom MCP server with Connection: Tunnel and select this tunnel.'
    & $tunnelClient run --profile $profileName
    if ($LASTEXITCODE -ne 0) {
        throw "tunnel-client run ended with exit code $LASTEXITCODE."
    }
} finally {
    [Environment]::SetEnvironmentVariable('CONTROL_PLANE_API_KEY', $previousProcessKey, 'Process')
    if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }
    if ($secureKey) {
        $secureKey.Dispose()
    }
    $plainKey = $null
    $secureKey = $null
}
