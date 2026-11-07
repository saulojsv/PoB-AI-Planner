<#
Run each optimizer System spec in a fresh native HeadlessWrapper process.
Requires an existing LuaJIT executable. Does not download/install software,
contact build providers, select a desktop instance, or train a production model.
The portable assertion adapter is explicitly distinct from official Busted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LuaJit,
    [string[]]$Suite = @('TestOptimizer*_spec.lua'),
    [string]$EvidenceDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('pob-contracts-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [ValidateRange(10, 3600)][int]$SuiteTimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$luaExecutable = (Resolve-Path -LiteralPath $LuaJit).Path
$sourceDirectory = Join-Path $repoRoot 'src'
$runner = Join-Path $PSScriptRoot 'contract_runner.lua'
$specDirectory = Join-Path $repoRoot 'spec/System'
$specs = @($Suite | ForEach-Object { Get-ChildItem -Path (Join-Path $specDirectory $_) -File } | Sort-Object FullName -Unique)
if ($specs.Count -eq 0) { throw 'No specs matched.' }
foreach ($spec in $specs) {
    if ($spec.DirectoryName -ne $specDirectory -or $spec.Name -notmatch '^Test\w+_spec\.lua$') { throw 'Expected a System spec.' }
}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$evidenceRoot = (Resolve-Path -LiteralPath $EvidenceDirectory).Path
$mainPath = Join-Path $sourceDirectory 'Modules/Main.lua'
$mainHash = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash
$manifestPath = Join-Path $repoRoot 'manifest.xml'
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$runnerHash = (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash
$results = @()
foreach ($spec in $specs) {
    $log = Join-Path $evidenceRoot ($spec.BaseName + '.log')
    $errorLog = Join-Path $evidenceRoot ($spec.BaseName + '.stderr.log')
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $luaExecutable
    $info.Arguments = '"' + $runner + '"'
    $info.WorkingDirectory = $sourceDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['CI'] = '1'
    $info.EnvironmentVariables['POB_TEST_SPEC'] = '../spec/System/' + $spec.Name
    $info.EnvironmentVariables['LUA_PATH'] = '.\?.lua;.\?\init.lua;..\runtime\lua\?.lua;..\runtime\lua\?\init.lua'
    $info.EnvironmentVariables['LUA_CPATH'] = '.\?.dll;..\runtime\?.dll;..\runtime\lua\?.dll'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $timer = [Diagnostics.Stopwatch]::StartNew()
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($SuiteTimeoutSeconds * 1000)
    if ($timedOut) { $process.Kill(); $process.WaitForExit() }
    $outputText = $stdout.GetAwaiter().GetResult()
    $errorText = $stderr.GetAwaiter().GetResult()
    $timer.Stop()
    [IO.File]::WriteAllText($log, $outputText)
    [IO.File]::WriteAllText($errorLog, $errorText)
    $match = [regex]::Match($outputText, '(?m)^RESULT (\d+)/(\d+) passed;')
    $passed = if ($match.Success) { [int]$match.Groups[1].Value } else { 0 }
    $total = if ($match.Success) { [int]$match.Groups[2].Value } else { 0 }
    $ok = -not $timedOut -and $process.ExitCode -eq 0 -and $match.Success -and $passed -eq $total
    $engineLine = [regex]::Match($outputText, '(?m)^QA_ENGINE (.+)$')
    $engine = if ($engineLine.Success) { $engineLine.Groups[1].Value | ConvertFrom-Json } else { $null }
    $cases = @([regex]::Matches($outputText, '(?m)^QA_CASE (.+)$') | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
    $result = [pscustomobject]@{
        suite = $spec.Name; passed = $passed; total = $total; success = $ok
        exitCode = $process.ExitCode; timedOut = $timedOut
        seconds = [math]::Round($timer.Elapsed.TotalSeconds, 2); log = $log; stderr = $errorLog
        engine = $engine; cases = $cases
    }
    $results += $result
    $process.Dispose()
    $report = [ordered]@{
        runner = 'minimal_busted_adapter'; officialBusted = $false
        engine = 'native_PoE1_HeadlessWrapper'; mainSHA256Before = $mainHash
        mainSHA256After = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash
        manifestSHA256Before = $manifestHash
        manifestSHA256After = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        adapterSHA256 = $runnerHash
        generatedAt = [DateTime]::UtcNow.ToString('o'); suites = $results
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidenceRoot 'results.json') -Encoding UTF8
    Write-Output ("{0}: {1}/{2}; success={3}; timeout={4}; {5}s" -f $result.suite, $passed, $total, $ok, $timedOut, $result.seconds)
}
$mainUnchanged = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash -eq $mainHash
Write-Output ('Evidence: ' + $evidenceRoot)
if (-not $mainUnchanged -or @($results | Where-Object { -not $_.success }).Count -gt 0) { exit 1 }
exit 0
