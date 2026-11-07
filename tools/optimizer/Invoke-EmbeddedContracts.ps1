<#
Run PoB System contract specs with the repository's minimal Busted adapter and
the bundled PoB Lua 5.1/JIT DLL. This is not official Busted. It avoids requiring
a separately installed LuaJIT executable on developer hosts.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string[]]$Suite,
	[string]$RuntimeDirectory = (Join-Path $PSScriptRoot '../../runtime'),
	[string]$ProgramDirectory = (Join-Path $PSScriptRoot '../../src')
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$runtimeRoot = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$programRoot = (Resolve-Path -LiteralPath $ProgramDirectory).Path
$luaDll = Join-Path $runtimeRoot 'lua51.dll'
if (-not (Test-Path -LiteralPath $luaDll -PathType Leaf)) { throw "PoB Lua runtime not found: $luaDll" }
foreach ($suiteName in $Suite) {
	if ($suiteName -notmatch '^Test\w+_spec\.lua$') { throw "Invalid System spec name: $suiteName" }
	if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'spec/System' $suiteName) -PathType Leaf)) {
		throw "System spec not found: $suiteName"
	}
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PoBEmbeddedLuaContractHost {
	[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SetDllDirectory(string path);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr luaL_newstate();
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern void luaL_openlibs(IntPtr state);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)] public static extern int luaL_loadstring(IntPtr state, string code);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int lua_pcall(IntPtr state, int nargs, int nresults, int errorFunctionIndex);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr lua_tolstring(IntPtr state, int index, out UIntPtr length);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern void lua_close(IntPtr state);
}
'@
[void][PoBEmbeddedLuaContractHost]::SetDllDirectory($runtimeRoot)
$env:PATH = $runtimeRoot + ';' + (Join-Path $repoRoot 'runtime') + ';' + $env:PATH
$sourceHeadlessWrapper = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'src/HeadlessWrapper.lua')).Path.Replace('\', '/')
$absoluteSpecDirectory = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'spec')).Path.Replace('\', '/')
$repoRootLua = $repoRoot.Replace('\', '/')
$contractRunner = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'tools/optimizer/contract_runner.lua')).Path.Replace('\', '/')
$programRootLua = $programRoot.Replace('\', '/')
$oldCwd = [Environment]::CurrentDirectory
$failureCount = 0
$temporaryHarnessFiles = [System.Collections.Generic.List[string]]::new()
$simpleGraphicDefinition = Join-Path $programRoot '_SimpleGraphic.def.lua'
if (-not (Test-Path -LiteralPath $simpleGraphicDefinition -PathType Leaf)) {
	Copy-Item -LiteralPath (Join-Path $repoRoot 'src/_SimpleGraphic.def.lua') -Destination $simpleGraphicDefinition
	$temporaryHarnessFiles.Add($simpleGraphicDefinition)
}
try {
	[Environment]::CurrentDirectory = $programRoot
	foreach ($suiteName in $Suite) {
		$specPath = (Join-Path $repoRoot ('spec/System/' + $suiteName))
		$luaSpecPath = $specPath.Replace('\', '/')
		$lua = @"
local previousGetenv = os.getenv
os.getenv = function(name)
	if name == 'CI' then return '1' end
	if name == 'POB_TEST_SPEC' then return '$luaSpecPath' end
	if name == 'POB_HEADLESS_WRAPPER' then return '$sourceHeadlessWrapper' end
	if name == 'POB_TEST_REPO_ROOT' then return '$repoRootLua' end
	return previousGetenv(name)
end
local previousExit = os.exit
os.exit = function(code) error('__POB_CONTRACT_EXIT__' .. tostring(code or 0), 0) end
local nativePrint = print
print = function(...)
	local first = tostring(select(1, ...))
	if first:match('^QA_ENGINE ') or first:match('^PASS ') or first:match('^FAIL ')
		or first:match('^ADAPTER ') or first:match('^RESULT ') then nativePrint(...) end
end
local nativeWrite = io.write
io.write = function(...)
	local first = tostring(select(1, ...))
	if first:match('^RUN ') then return end
	return nativeWrite(...)
end
arg = {}
package.path = './?.lua;./?/init.lua;./lua/?.lua;./lua/?/init.lua;./runtime/lua/?.lua;./runtime/lua/?/init.lua;../runtime/lua/?.lua;../runtime/lua/?/init.lua;$absoluteSpecDirectory/?.lua;$absoluteSpecDirectory/?/init.lua;' .. package.path
package.cpath = '$runtimeRootLua/?.dll;$runtimeRootLua/lua/?.dll;./?.dll;./runtime/?.dll;./runtime/lua/?.dll;../runtime/?.dll;../runtime/lua/?.dll;' .. package.cpath
dofile('$contractRunner')
"@
		$state = [IntPtr]::Zero
		try {
			$state = [PoBEmbeddedLuaContractHost]::luaL_newstate()
			if ($state -eq [IntPtr]::Zero) { throw 'luaL_newstate returned null' }
			[PoBEmbeddedLuaContractHost]::luaL_openlibs($state)
			$status = [PoBEmbeddedLuaContractHost]::luaL_loadstring($state, $lua)
			if ($status -ne 0) {
				$length = [UIntPtr]::Zero
				$errorPointer = [PoBEmbeddedLuaContractHost]::lua_tolstring($state, -1, [ref]$length)
				throw ('Lua bootstrap error: ' + [Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorPointer))
			}
			$status = [PoBEmbeddedLuaContractHost]::lua_pcall($state, 0, -1, 0)
			if ($status -ne 0) {
				$length = [UIntPtr]::Zero
				$errorPointer = [PoBEmbeddedLuaContractHost]::lua_tolstring($state, -1, [ref]$length)
				$errorText = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorPointer)
				if ($errorText -match '__POB_CONTRACT_EXIT__(\d+)') {
					if ([int]$Matches[1] -ne 0) { $failureCount++ }
				} else {
					$failureCount++
					Write-Error $errorText
				}
			}
		} finally {
			if ($state -ne [IntPtr]::Zero) { [PoBEmbeddedLuaContractHost]::lua_close($state) }
		}
	}
} finally {
	[Environment]::CurrentDirectory = $oldCwd
	foreach ($temporaryHarnessFile in $temporaryHarnessFiles) {
		if (Test-Path -LiteralPath $temporaryHarnessFile -PathType Leaf) {
			Remove-Item -LiteralPath $temporaryHarnessFile -Force
		}
	}
}
if ($failureCount -gt 0) { exit 1 }
exit 0
