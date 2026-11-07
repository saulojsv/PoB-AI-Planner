-- Portable focused contract runner for hosts without Busted. This is not the
-- official Busted runner; unsupported assertions/hooks fail rather than skip.
-- Run from src through Invoke-Contracts.ps1. No production source is rewritten.
local nativeLoadfile = loadfile
local compatibilityTranslations = 0
function loadfile(path, ...)
	if path:gsub("\\", "/") == "Modules/Main.lua" then
		local file = assert(io.open(path, "rb"))
		local source = file:read("*a")
		file:close()
		-- The pinned native PoB parser supports +=; stock LuaJIT does not.
		local translated, count = source:gsub("count %+= 1", "count = count + 1")
		assert(count <= 1, "Unexpected MAIN compatibility expression count")
		compatibilityTranslations = count
		return loadstring(translated, "@" .. path)
	end
	return nativeLoadfile(path, ...)
end

assert(os.getenv("CI") == "1", "CI=1 is required to isolate the headless runtime")
local headlessWrapper = os.getenv("POB_HEADLESS_WRAPPER") or "HeadlessWrapper.lua"
dofile(headlessWrapper)
assert(not __mainObject__.promptMsg, "PoB startup returned an error: " .. tostring(__mainObject__.promptMsg))
package.path = package.path .. ";../spec/?.lua;../spec/?/init.lua"
print("QA_ENGINE " .. require("dkjson").encode(require("Modules.Optimizer.Version").Snapshot(build)))

-- Windows' system CRT exposes the same file helpers used by these fixtures.
-- Use real CRT calls, not shell commands or mocked filesystem outcomes.
local ffi = require("ffi")
local nativeFfiLoad = ffi.load
local crtFallbacks = 0
ffi.load = function(name, ...)
	if name ~= "msvcr100" then return nativeFfiLoad(name, ...) end
	local ok, library = pcall(nativeFfiLoad, name, ...)
	if ok then return library end
	crtFallbacks = crtFallbacks + 1
	return nativeFfiLoad("msvcrt", ...)
end

local nativeAssert = assert
local function equalTables(a, b, seen)
	if a == b then return true end
	if type(a) ~= type(b) or type(a) ~= "table" then return false end
	seen = seen or { }
	if seen[a] == b then return true end
	seen[a] = b
	for key, value in pairs(a) do if not equalTables(value, b[key], seen) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end
local checks = setmetatable({ }, { __call = function(_, ...) return nativeAssert(...) end })
for name, expected in pairs({ is_true = "true", is_false = "false", is_nil = "nil", is_table = "table", is_function = "function" }) do
	local assertionName, expectedType = name, expected
	checks[assertionName] = function(value, message)
		local valid = expectedType == "true" and value == true
			or expectedType == "false" and value == false
			or expectedType == "nil" and value == nil
			or (expectedType == "table" or expectedType == "function") and type(value) == expectedType
		if not valid then error(message or (assertionName .. ": got " .. tostring(value)), 2) end
	end
end
checks.is_truthy = function(value, message) if not value then error(message or "Expected truthy value", 2) end end
checks.is_not_nil = function(value, message) if value == nil then error(message or "Expected non-nil value", 2) end end
checks.matches = function(pattern, actual, message, plain)
	if type(pattern) ~= "string" or type(actual) ~= "string" then
		error(message or "Expected string pattern and actual value", 2)
	end
	local found
	if plain then found = actual:find(pattern, 1, true) else found = actual:find(pattern) end
	if not found then error(message or ("Expected " .. string.format("%q", actual) .. " to match " .. string.format("%q", pattern)), 2) end
end
checks.are = {
	equal = function(a, b, message) if a ~= b then error(message or ("Expected " .. tostring(a) .. ", got " .. tostring(b)), 2) end end,
	same = function(a, b, message) if not equalTables(a, b) then error(message or "Tables differ", 2) end end,
}
checks.are.equals = checks.are.equal
checks.are_not = { equal = function(a, b, message) if a == b then error(message or "Values must differ", 2) end end }
checks.are.not_equal = checks.are_not.equal
checks.equals = checks.are.equal
checks.truthy = checks.is_truthy
checks.falsy = function(value, message) if value then error(message or "Expected falsy value", 2) end end
_G.assert = checks

local tests, scopes = { }, { }
function describe(name, callback)
	scopes[#scopes + 1] = { name = name }
	callback()
	scopes[#scopes] = nil
end
function before_each(callback) scopes[#scopes].before = callback end
function after_each(callback) scopes[#scopes].after = callback end
function it(name, callback)
	local ancestors = { }
	for index, scope in ipairs(scopes) do ancestors[index] = scope end
	tests[#tests + 1] = { name = name, run = callback, scopes = ancestors }
end

local spec = assert(os.getenv("POB_TEST_SPEC"), "POB_TEST_SPEC missing")
local normalizedSpec = spec:gsub("\\", "/")
local validRelativeSpec = normalizedSpec:match("^%.%./spec/System/Test[%w_]+_spec%.lua$")
local validAbsoluteSpec = normalizedSpec:match("^[%a]:/.*/spec/System/Test[%w_]+_spec%.lua$")
assert(validRelativeSpec or validAbsoluteSpec, "Expected an absolute or source-relative System test spec path")
dofile(spec)
assert(#tests > 0, "The suite registered no tests")
local failures = 0
for _, test in ipairs(tests) do
	io.write("RUN " .. test.name .. "\n")
	io.flush()
	local ok, err = xpcall(function()
		for _, scope in ipairs(test.scopes) do if scope.before then scope.before() end end
		test.run()
	end, debug.traceback)
	for index = #test.scopes, 1, -1 do
		local cleanup = test.scopes[index].after
		if cleanup then
			local cleanupOK, cleanupError = xpcall(cleanup, debug.traceback)
			if not cleanupOK then ok, err = false, tostring(err or "") .. "\nCleanup: " .. cleanupError end
		end
	end
	if ok then print("PASS " .. test.name) else failures = failures + 1; print("FAIL " .. test.name .. ": " .. tostring(err)) end
	io.flush()
end
print(string.format("ADAPTER minimal; MAIN in-memory translations=%d; system CRT fallbacks=%d", compatibilityTranslations, crtFallbacks))
print(string.format("RESULT %d/%d passed; minimal Busted adapter; source untouched", #tests - failures, #tests))
if failures > 0 then os.exit(1) end
