-- Read-only native coverage snapshot, intended for Read-BuildCoverageSummary.ps1.
local nativeLoadfile = loadfile
function loadfile(path, ...)
	if path:gsub("\\", "/") == "Modules/Main.lua" then
		local file = assert(io.open(path, "rb"))
		local source = file:read("*a")
		file:close()
		-- Match the portable contract runner's compatibility shim for LuaJIT.
		local translated, count = source:gsub("count %+= 1", "count = count + 1")
		assert(count <= 1, "Unexpected MAIN compatibility expression count")
		return loadstring(translated, "@" .. path)
	end
	return nativeLoadfile(path, ...)
end
assert(os.getenv("CI") == "1", "CI=1 is required to isolate the HeadlessWrapper")
dofile("HeadlessWrapper.lua")
assert(not __mainObject__.promptMsg, "PoB startup returned an error")

local json = require("dkjson")
local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local userPath = assert(os.getenv("POB_USER_DATA"), "POB_USER_DATA is required")
local summary, summaryError = StudyBuilds.Summary(userPath, build)
assert(summary, summaryError)

local output = {
	storage = summary.storage,
	catalog = summary.catalog,
	patches = { },
	model = summary.model,
	penanceBrand329Normal = nil,
	penanceBrand329Transfigured = nil,
}
for _, patch in ipairs(summary.patchSkillCatalog.patches or { }) do
	output.patches[#output.patches + 1] = { patch = patch.patch, counts = patch.counts, skills = patch.skills }
	if patch.patch == "3.29" then
		for _, skill in ipairs(patch.skills or { }) do
			if skill.name == "Penance Brand" and skill.category == "normal" then
				output.penanceBrand329Normal = {
					name = skill.name,
					variantKey = skill.variantKey,
					uniqueBuilds = skill.uniqueBuilds,
					remainingToTarget = skill.remainingToTarget,
					target = skill.sampleTarget,
				}
			elseif skill.name == "Penance Brand of Dissipation" and skill.category == "transfigured" then
				output.penanceBrand329Transfigured = {
					name = skill.name,
					variantKey = skill.variantKey,
					uniqueBuilds = skill.uniqueBuilds,
					remainingToTarget = skill.remainingToTarget,
					target = skill.sampleTarget,
				}
			end
		end
	end
end

print("BUILD_COVERAGE_SUMMARY " .. json.encode(output))
