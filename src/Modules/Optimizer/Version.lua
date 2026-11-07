-- Path of Building
--
-- Module: Stable optimizer engine-version identity.
-- PoB's shared game-data table does not currently expose a distinct game-data
-- version field. The loaded tree's patch display is used as a conservative
-- compatibility key; it is not proof that every gem/item/LUT dataset matches.

local version = { }
local sha = require("sha2")

local manifestParts = { default = true, runtime = true, program = true, tree = true }

local function boundedManifestText(value, maximum)
	return type(value) == "string" and value ~= "" and #value <= maximum and not value:find("[%c]")
end

local function safeManifestPath(value)
	if not boundedManifestText(value, 512) or value:sub(1, 1) == "/" or value:find("\\", 1, true)
		or value:match("^[%a]:") then return false end
	for segment in value:gmatch("[^/]+") do if segment == ".." then return false end end
	return true
end

-- The native PoB manifest is the updater's inventory of SHA-1 file hashes.
-- Hash the validated inventory, rather than scanning hundreds of megabytes of
-- game data on every launch. This identifies the declared app/data/tree set;
-- it does not independently prove the installed bytes still match that set.
function version.ManifestFingerprint(manifest)
	local root = type(manifest) == "table" and manifest[1]
	if type(root) ~= "table" or root.elem ~= "PoBVersion" then return nil, "manifest_root_invalid" end
	local release, rows, seen, parts = nil, { }, { }, { }
	for _, node in ipairs(root) do
		if type(node) == "table" and node.elem == "Version" then
			local number = node.attrib and node.attrib.number
			if boundedManifestText(number, 40) then release = number end
		elseif type(node) == "table" and node.elem == "File" then
			local attributes = node.attrib or { }
			local part, name, digest = attributes.part, attributes.name, attributes.sha1
			if not manifestParts[part] or not safeManifestPath(name)
				or type(digest) ~= "string" or #digest ~= 40 or not digest:match("^%x+$") then
				return nil, "manifest_file_entry_invalid"
			end
			if attributes.runtime ~= nil and not boundedManifestText(attributes.runtime, 40) then
				return nil, "manifest_runtime_invalid"
			end
			local key = part .. "\0" .. name
			if seen[key] then return nil, "manifest_file_entry_duplicate" end
			seen[key], parts[part] = true, true
			rows[#rows + 1] = key .. "\0" .. (attributes.runtime or "") .. "\0" .. digest:lower()
		end
	end
	if not release then return nil, "manifest_version_missing" end
	if #rows == 0 then return nil, "manifest_file_inventory_empty" end
	for part in pairs(manifestParts) do
		if not parts[part] then return nil, "manifest_part_missing:" .. part end
	end
	table.sort(rows)
	local payload = "pob-manifest-inventory-v1\0" .. release .. "\0" .. tostring(#rows) .. "\0" .. table.concat(rows, "\n")
	return sha.sha256(payload), { format = "pob-manifest-inventory-v1", fileCount = #rows }
end

function version.Data(build, versions)
	local value = build and build.data and build.data.version
	if type(value) == "string" or type(value) == "number" then return tostring(value) end
	local treeVersion = build and build.spec and build.spec.treeVersion
	local treeInfo = treeVersion and (versions or treeVersions or { })[treeVersion]
	if treeInfo and treeInfo.display then return tostring(treeInfo.display) end
	return treeVersion and tostring(treeVersion) or nil
end

function version.DataSource(build)
	local value = build and build.data and build.data.version
	if type(value) == "string" or type(value) == "number" then return "pob_loaded_data_table_version" end
	if version.Tree(build) then return "tree_compatibility_key" end
	return "unavailable"
end

function version.Tree(build)
	return build and build.spec and build.spec.treeVersion or nil
end

function version.Branch()
	if not launch then return nil end
	local branch = launch.versionBranch
	if type(branch) == "string" and branch ~= "" and branch ~= "?" then return branch end
	-- Source checkouts may have a local manifest without a published branch.
	-- Keep their records versioned while ensuring they cannot be mistaken for a
	-- release/dev/beta dataset when the exact source branch is unknown.
	if launch.devMode then return "local" end
	return nil
end

function version.Snapshot(build)
	local manifestFingerprintStatus = launch and launch.manifestFingerprintStatus
	if launch and manifestFingerprintStatus == nil then
		manifestFingerprintStatus = launch.manifestFingerprint and "available" or "unavailable"
	end
	local manifestFingerprint = launch and launch.manifestFingerprint or nil
	if manifestFingerprintStatus == "pending" or manifestFingerprintStatus == "mismatch"
		or manifestFingerprintStatus == "unavailable" then
		manifestFingerprint = nil
	end
	return {
		dataVersion = version.Data(build),
		dataVersionSource = version.DataSource(build),
		treeVersion = version.Tree(build),
		pobVersion = launch and launch.versionNumber or nil,
		pobBranch = version.Branch(),
		manifestFingerprint = manifestFingerprint,
		manifestFingerprintStatus = manifestFingerprintStatus,
		manifestFingerprintFormat = launch and launch.manifestFingerprintFormat or nil,
		manifestInventoryFingerprint = launch and launch.manifestInventoryFingerprint or nil,
	}
end

return version
