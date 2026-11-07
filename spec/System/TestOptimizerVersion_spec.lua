local Version = require("Modules.Optimizer.Version")
local ContentFingerprint = require("Modules.Optimizer.ContentFingerprint")
local sha = require("sha2")

describe("Optimizer engine identity", function()
	local function manifest(programHash)
		return { {
			elem = "PoBVersion",
			{ elem = "Version", attrib = { number = "2.67.2" } },
			{ elem = "File", attrib = { part = "default", name = "LICENSE.md", sha1 = string.rep("1", 40) } },
			{ elem = "File", attrib = { part = "runtime", name = "lua/sha2.lua", runtime = "win32", sha1 = string.rep("2", 40) } },
			{ elem = "File", attrib = { part = "program", name = "Modules/CalcPerform.lua", sha1 = programHash or string.rep("3", 40) } },
			{ elem = "File", attrib = { part = "tree", name = "TreeData/3_29/tree.lua", sha1 = string.rep("4", 40) } },
		} }
	end

	it("fingerprints the complete validated file inventory deterministically", function()
		local first, metadata = Version.ManifestFingerprint(manifest())
		local second = Version.ManifestFingerprint(manifest())
		assert.are.equal(first, second)
		assert.are.equal(64, #first)
		assert.are.equal("pob-manifest-inventory-v1", metadata.format)
		assert.are.equal(4, metadata.fileCount)
	end)

	it("changes identity when any declared calculation source hash changes", function()
		local before = assert(Version.ManifestFingerprint(manifest()))
		local after = assert(Version.ManifestFingerprint(manifest(string.rep("5", 40))))
		assert.are_not.equal(before, after)
	end)

	it("rejects malformed, duplicate, and incomplete manifests", function()
		local missingPart = manifest()
		missingPart[1][5] = nil
		assert.is_nil(Version.ManifestFingerprint(missingPart))

		local duplicate = manifest()
		duplicate[1][6] = { elem = "File", attrib = { part = "tree", name = "TreeData/3_29/tree.lua", sha1 = string.rep("4", 40) } }
		assert.is_nil(Version.ManifestFingerprint(duplicate))

		local invalidHash = manifest("not-a-hash")
		assert.is_nil(Version.ManifestFingerprint(invalidHash))
		assert.is_nil(Version.ManifestFingerprint({ { elem = "WrongRoot" } }))
	end)

	it("includes the loaded manifest fingerprint in the engine snapshot", function()
		local previousLaunch = launch
		launch = { versionNumber = "2.67.2", versionBranch = "dev", manifestFingerprint = string.rep("a", 64) }
		local snapshot = Version.Snapshot({ data = { version = "3.29" }, spec = { treeVersion = "3_29" } })
		assert.are.equal(string.rep("a", 64), snapshot.manifestFingerprint)
		assert.are.equal("available", snapshot.manifestFingerprintStatus)
		assert.are.equal("2.67.2", snapshot.pobVersion)
		assert.are.equal("pob_loaded_data_table_version", snapshot.dataVersionSource)
		launch = previousLaunch
	end)

	it("marks the tree version as a compatibility key when PoB exposes no separate data version", function()
		local snapshot = Version.Snapshot({ data = { }, spec = { treeVersion = "3_27" } })
		assert.are.equal("3.27", snapshot.dataVersion)
		assert.are.equal("3_27", snapshot.treeVersion)
		assert.are.equal("tree_compatibility_key", snapshot.dataVersionSource)
	end)

	it("does not expose the declared inventory as verified content while hashing is pending", function()
		local previousLaunch = launch
		launch = { versionNumber = "2.67.2", manifestInventoryFingerprint = string.rep("b", 64),
			manifestFingerprint = string.rep("a", 64), manifestFingerprintStatus = "pending" }
		local snapshot = Version.Snapshot({ data = { version = "3.29" }, spec = { treeVersion = "3_29" } })
		assert.is_nil(snapshot.manifestFingerprint)
		assert.are.equal("pending", snapshot.manifestFingerprintStatus)
		assert.are.equal(string.rep("b", 64), snapshot.manifestInventoryFingerprint)
		launch = previousLaunch
	end)

	it("fails closed for content identities that mismatch or could not be verified", function()
		local previousLaunch = launch
		for _, status in ipairs({ "mismatch", "unavailable" }) do
			launch = { manifestInventoryFingerprint = string.rep("b", 64),
				manifestFingerprint = string.rep("a", 64), manifestFingerprintStatus = status }
			local snapshot = Version.Snapshot({ data = { version = "3.29" }, spec = { treeVersion = "3_29" } })
			assert.is_nil(snapshot.manifestFingerprint)
			assert.are.equal(status, snapshot.manifestFingerprintStatus)
		end
		launch = previousLaunch
	end)

	it("selects calculation code and data while excluding presentation assets", function()
		local value = manifest()
		value[1][#value[1] + 1] = { elem = "File", attrib = {
			part = "program", name = "Assets/ai-planner-watermark.png", sha1 = string.rep("5", 40) } }
		value[1][#value[1] + 1] = { elem = "File", attrib = {
			part = "program", name = "Data/TimelessJewelData/BrutalRestraint.zip.part0", sha1 = string.rep("6", 40) } }
		local rows = assert(ContentFingerprint.BuildEntries(value))
		assert.are.equal(5, #rows)
		local serialized = assert(ContentFingerprint.SerializeEntries(rows))
		local reparsed = assert(ContentFingerprint.ParseEntries(serialized))
		assert.are.equal(#rows, #reparsed)
		for _, row in ipairs(reparsed) do
			assert.is_false(row.path:find("watermark.png", 1, true) ~= nil)
		end
		assert.is_truthy(serialized:find("BrutalRestraint.zip.part0", 1, true))
	end)

	it("builds a deterministic content identity and rejects bytes that disagree with PoB's manifest", function()
		local contents = {
			["default/LICENSE.md"] = "license bytes",
			["runtime/lua/sha2.lua"] = "runtime sha bytes",
			["program/Modules/CalcPerform.lua"] = "calculation source bytes",
			["tree/TreeData/3_29/tree.lua"] = "tree data bytes",
		}
		local value = { { elem = "PoBVersion", { elem = "Version", attrib = { number = "2.67.2" } } } }
		local function add(part, path)
			local data = contents[part .. "/" .. path]
			value[1][#value[1] + 1] = { elem = "File", attrib = { part = part, name = path, sha1 = sha.sha1(data) } }
		end
		add("default", "LICENSE.md")
		add("runtime", "lua/sha2.lua")
		add("program", "Modules/CalcPerform.lua")
		add("tree", "TreeData/3_29/tree.lua")
		local rows = assert(ContentFingerprint.BuildEntries(value))
		local roots = { default = "root-default", runtime = "root-runtime", program = "root-program", tree = "root-tree" }
		local function reader(_, row) return contents[row.part .. "/" .. row.path] end
		local first, firstStatus, fileCount, byteCount = ContentFingerprint.Compute(rows, roots, string.rep("a", 64), reader)
		local second = ContentFingerprint.Compute(rows, roots, string.rep("a", 64), reader)
		assert.are.equal("verified", firstStatus)
		assert.are.equal(#rows, fileCount)
		assert.are.equal(69, byteCount)
		assert.are.equal(first, second)
		contents["program/Modules/CalcPerform.lua"] = "different source bytes"
		local mismatch, status = ContentFingerprint.Compute(rows, roots, string.rep("a", 64), reader)
		assert.is_nil(mismatch)
		assert.are.equal("mismatch", status)
	end)

	it("uses PoB's canonical CRLF manifest bytes for text identity across line endings", function()
		local text = "first line\nsecond line\n"
		local row = { { part = "program", path = "fixture.lua", expectedSha1 = sha.sha1("first line\r\nsecond line\r\n") } }
		local function reader() return text end
		local first, status = ContentFingerprint.Compute(row, { program = "root" }, string.rep("a", 64), reader)
		assert.are.equal("verified", status)
		text = "first line\r\nsecond line\r\n"
		local second, secondStatus = ContentFingerprint.Compute(row, { program = "root" }, string.rep("a", 64), reader)
		assert.are.equal("verified", secondStatus)
		assert.are.equal(first, second)
	end)

	it("resolves the updater's {space} manifest token before reading packaged files", function()
		local row = { {
			part = "runtime", path = "Path{space}of{space}Building.exe",
			expectedSha1 = sha.sha1("official executable bytes"),
		} }
		local observedPath
		local function reader(path)
			observedPath = path
			return "official executable bytes"
		end
		local digest, status = ContentFingerprint.Compute(row, { runtime = "release-root" }, string.rep("b", 64), reader)
		assert.is_truthy(digest)
		assert.are.equal("verified", status)
		assert.is_truthy(observedPath:find("Path of Building.exe", 1, true))
		assert.is_nil(observedPath:find("{space}", 1, true))
	end)

	it("registers the worker callback before accepting a content-scan job", function()
		local previousLaunch, previousSubScript = launch, LaunchSubScript
		local registered = { }
		launch = { subScripts = registered }
		LaunchSubScript = function(script, _, _, serialized, defaultRoot, programRoot, runtimeRoot, inventoryHash)
			assert.is_truthy(script:find("ContentFingerprint", 1, true))
			assert.is_truthy(serialized:find("CalcPerform.lua", 1, true))
			assert.are.equal("root-default", defaultRoot)
			assert.are.equal("root-program", programRoot)
			assert.are.equal("root-runtime", runtimeRoot)
			assert.are.equal(string.rep("a", 64), inventoryHash)
			return "fingerprint-job"
		end
		local noop = function() end
		local id, rowCount = ContentFingerprint.Start(manifest(), {
			default = "root-default", program = "root-program", runtime = "root-runtime",
		}, string.rep("a", 64), noop, noop)
		assert.are.equal("fingerprint-job", id)
		assert.are.equal(4, rowCount)
		assert.are.equal("CUSTOM", registered[id].type)
		assert.are.equal(noop, registered[id].callback)
		assert.are.equal(noop, registered[id].errorCallback)
		launch = { }
		local rejectedId, rejectedError = ContentFingerprint.Start(manifest(), { }, string.rep("a", 64), noop, noop)
		assert.is_nil(rejectedId)
		assert.are.equal("subscript_registry_unavailable", rejectedError)
		launch, LaunchSubScript = previousLaunch, previousSubScript
	end)
end)
