<#
Run selected PoB Lua spec files inside the repository's embedded HeadlessWrapper.
The test-only assertion adapter supports the Busted-style assertions used by
the focused System specs, without modifying the active GUI installation.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string[]]$SpecPath,
	[string]$SourceRoot = (Join-Path $PSScriptRoot '../..'),
	[string]$RuntimeDirectory = (Join-Path $PSScriptRoot '../../runtime/AIPlanner-2.67.2-Full-QA-20261031-R2')
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$runtimeRoot = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$runtimeRootLua = $runtimeRoot.Replace('\', '/')
$repoRuntimeRoot = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'runtime')).Path
$specRoot = (Resolve-Path (Join-Path $repoRoot 'spec')).Path
$luaDll = Join-Path $runtimeRoot 'lua51.dll'
if (-not (Test-Path -LiteralPath $luaDll -PathType Leaf)) { throw "PoB Lua runtime not found: $luaDll" }

$specCalls = foreach ($relativePath in $SpecPath) {
	if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath.Contains('..')) {
		throw "Spec path must be relative to spec/: $relativePath"
	}
	$resolved = (Resolve-Path -LiteralPath (Join-Path $specRoot $relativePath)).Path
	if (-not $resolved.StartsWith($specRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
		throw "Spec path escaped spec/: $relativePath"
	}
	$luaPath = $resolved.Replace('\', '/').Replace('"', '\"')
	'dofile("' + $luaPath + '")'
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PoBHeadlessSpecHost {
	[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SetDllDirectory(string path);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr luaL_newstate();
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern void luaL_openlibs(IntPtr state);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)] public static extern int luaL_loadstring(IntPtr state, string code);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int lua_pcall(IntPtr state, int nargs, int nresults, int errorFunctionIndex);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr lua_tolstring(IntPtr state, int index, out UIntPtr length);
	[DllImport("lua51.dll", CallingConvention=CallingConvention.Cdecl)] public static extern void lua_close(IntPtr state);
}
'@

$env:PATH = $runtimeRoot + ';' + $repoRuntimeRoot + ';' + $env:PATH
[void][PoBHeadlessSpecHost]::SetDllDirectory($runtimeRoot)
$oldCwd = [Environment]::CurrentDirectory
$repoPathLua = $repoRoot.Replace('\', '/')
$specSource = $specCalls -join "`n"
$lua = @"
local nativeLoadfile = loadfile
function loadfile(path, ...)
	if path:gsub("\\\\", "/") == "Modules/Main.lua" then
		local file = assert(io.open(path, "rb"))
		local source = file:read("*a")
		file:close()
		local translated, count = source:gsub("count %+= 1", "count = count + 1")
		assert(count <= 1, "Unexpected MAIN compatibility expression count")
		return loadstring(translated, "@" .. path)
	end
	return nativeLoadfile(path, ...)
end
local nativeGetenv = os.getenv
os.getenv = function(name) if name == "CI" then return "1" end return nativeGetenv(name) end
arg = {}
package.path = "./?.lua;./?/init.lua;../runtime/lua/?.lua;../runtime/lua/?/init.lua;../spec/?.lua;../spec/?/init.lua;" .. package.path
package.cpath = "./?.dll;../runtime/?.dll;../runtime/lua/?.dll;" .. package.cpath
dofile("HeadlessWrapper.lua")
assert(not __mainObject__.promptMsg, "PoB startup returned an error")
__mainObject__.main.userPath = "$repoPathLua/"
local Version = require("Modules.Optimizer.Version")
local Fingerprint = require("Modules.Optimizer.ContentFingerprint")
local manifest = assert(require("xml").LoadXMLFile("../manifest.xml"), "manifest.xml is unavailable")
local inventoryFingerprint = assert(Version.ManifestFingerprint(manifest), "manifest inventory is invalid")
local rows = assert(Fingerprint.BuildEntries(manifest), "calculation file inventory is invalid")
local fingerprint, fingerprintStatus, _, _, fingerprintError = Fingerprint.Compute(rows,
	{ default = "..", program = ".", tree = ".", runtime = "$runtimeRootLua" }, inventoryFingerprint)
assert(fingerprint and fingerprintStatus == "verified", "PoB calculation fingerprint is unverified: " .. tostring(fingerprintError))
launch.manifestFingerprint, launch.manifestFingerprintStatus = fingerprint, fingerprintStatus
launch.manifestFingerprintFormat = "pob-calculation-content-v1"

local nativeAssert = assert
local function fail(message) error(message or "assertion failed", 2) end
local function deepEqual(left, right, seen)
	if left == right then return true end
	if type(left) ~= type(right) or type(left) ~= "table" then return false end
	seen = seen or {}
	seen[left] = seen[left] or {}
	if seen[left][right] then return true end
	seen[left][right] = true
	for key, value in pairs(left) do if not deepEqual(value, right[key], seen) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end
local assertion = {
	are = {
		equal = function(expected, actual, message) if expected ~= actual then fail(message or ("expected " .. tostring(expected) .. ", got " .. tostring(actual))) end end,
		same = function(expected, actual, message) if not deepEqual(expected, actual) then fail(message or "tables differ") end end,
	},
	are_not = {
		equal = function(expected, actual, message) if expected == actual then fail(message or ("did not expect " .. tostring(actual))) end end,
	},
	is_true = function(value, message) if value ~= true then fail(message or ("expected true, got " .. tostring(value))) end end,
	is_false = function(value, message) if value ~= false then fail(message or ("expected false, got " .. tostring(value))) end end,
	falsy = function(value, message) if value then fail(message or ("expected a falsy value, got " .. tostring(value))) end end,
	is_nil = function(value, message) if value ~= nil then fail(message or ("expected nil, got " .. tostring(value))) end end,
	is_table = function(value, message) if type(value) ~= "table" then fail(message or ("expected table, got " .. type(value))) end end,
	is_truthy = function(value, message) if not value then fail(message or "expected a truthy value") end end,
	is_function = function(value, message) if type(value) ~= "function" then fail(message or ("expected function, got " .. type(value))) end end,
	matches = function(pattern, actual, message, plain)
		if type(pattern) ~= "string" or type(actual) ~= "string"
			or actual:find(pattern, 1, plain == true) == nil then
			fail(message or ("expected " .. tostring(actual) .. " to match " .. tostring(pattern)))
		end
		return true
	end,
}
setmetatable(assertion, { __call = function(_, ...) return nativeAssert(...) end })
_G.assert = assertion
local suiteStack, suiteHooks, passed, failed = {}, {}, 0, 0
function describe(name, callback)
	suiteStack[#suiteStack + 1] = name
	suiteHooks[#suiteHooks + 1] = { before = {}, after = {} }
	local ok, err = xpcall(callback, debug.traceback)
	suiteHooks[#suiteHooks] = nil
	table.remove(suiteStack)
	if not ok then error(err, 0) end
end
function before_each(callback)
	assert(type(callback) == "function", "before_each requires a callback")
	table.insert(suiteHooks[#suiteHooks].before, callback)
end
function after_each(callback)
	assert(type(callback) == "function", "after_each requires a callback")
	table.insert(suiteHooks[#suiteHooks].after, callback)
end
function it(name, callback)
	local fullName = table.concat(suiteStack, " / ") .. " / " .. name
	local before, after = {}, {}
	for _, hooks in ipairs(suiteHooks) do
		for _, hook in ipairs(hooks.before) do table.insert(before, hook) end
	end
	for index = #suiteHooks, 1, -1 do
		for _, hook in ipairs(suiteHooks[index].after) do table.insert(after, hook) end
	end
	local ok, err = xpcall(function()
		for _, hook in ipairs(before) do hook() end
		callback()
	end, debug.traceback)
	local afterOk, afterErr = xpcall(function()
		for _, hook in ipairs(after) do hook() end
	end, debug.traceback)
	if not afterOk then
		if ok then ok, err = false, afterErr else err = tostring(err) .. "\nAfter hook failed: " .. tostring(afterErr) end
	end
	if ok then
		passed = passed + 1
		print("SPEC_PASS " .. fullName)
	else
		failed = failed + 1
		print("SPEC_FAIL " .. fullName .. " :: " .. tostring(err))
	end
end
$specSource
print("QA_LUA_SPECS " .. passed .. " passed / " .. failed .. " failed")
if failed > 0 then error("Focused PoB Lua specs failed", 0) end
"@

try {
	[Environment]::CurrentDirectory = (Join-Path $repoRoot 'src')
	$state = [IntPtr]::Zero
	try {
		$state = [PoBHeadlessSpecHost]::luaL_newstate()
		if ($state -eq [IntPtr]::Zero) { throw 'luaL_newstate returned null' }
		[PoBHeadlessSpecHost]::luaL_openlibs($state)
		$status = [PoBHeadlessSpecHost]::luaL_loadstring($state, $lua)
		if ($status -ne 0) {
			$length = [UIntPtr]::Zero
			$errorPointer = [PoBHeadlessSpecHost]::lua_tolstring($state, -1, [ref]$length)
			throw ('Lua bootstrap error: ' + [Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorPointer))
		}
		$status = [PoBHeadlessSpecHost]::lua_pcall($state, 0, 0, 0)
		if ($status -ne 0) {
			$length = [UIntPtr]::Zero
			$errorPointer = [PoBHeadlessSpecHost]::lua_tolstring($state, -1, [ref]$length)
			throw ('PoB Headless specs failed: ' + [Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorPointer))
		}
	}
	finally {
		if ($state -ne [IntPtr]::Zero) { [PoBHeadlessSpecHost]::lua_close($state) }
	}
}
finally {
	[Environment]::CurrentDirectory = $oldCwd
}
