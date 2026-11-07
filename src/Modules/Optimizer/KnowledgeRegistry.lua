-- Path of Building
--
-- Module: deterministic, fail-closed retrieval over explicitly allowlisted
-- repository documents. This is a local lexical reference index, not a combat
-- calculator, web crawler, or training-data source.

local sha = require("sha2")
local registry = { }

local MAX_DOCUMENT_BYTES = 262144
local MAX_QUERY_BYTES = 512
local MAX_QUERY_TERMS = 24
local MAX_RESULTS = 8
local DEFAULT_RESULTS = 3
local MAX_SNIPPET_BYTES = 4096
local DEFAULT_SNIPPET_BYTES = 1800

local LICENSE_SHA256 = "D5E0E888AAF923E4A1E85078F2AE24602BAA79D883A359C3ED928354A57BD0DB"
local sources = {
	{
		sourceId = "pob-codebase-rundown",
		path = "docs/rundown.md",
		sha256 = "36BF7A536B4395698448A46DC1EF14E537C40B7469D31DCE29683D749C1F8783",
		game = "poe1",
		patch = "3.29",
		pobVersion = "2.67.2",
		dataVersion = "3.29",
		treeVersion = "3_29",
		knowledgeScope = "pob_architecture",
		sourceDateStatus = "not_stated",
		reviewedAt = "2026-10-23",
		license = {
			id = "MIT",
			path = "LICENSE.md",
			sha256 = LICENSE_SHA256,
			verified = true,
			scope = "repository-authored software and documentation",
		},
		usageScopes = { local_retrieval = true },
		status = "reviewed",
	},
	{
		sourceId = "optimizer-build-readiness",
		path = "docs/optimizer/BUILD_READINESS.md",
		sha256 = "93AE9E36C4A57F8D5AC4FF9A8BBD36A255C05B0D6312EF173016DBF9410D68FD",
		game = "poe1",
		patch = "3.29",
		pobVersion = "2.67.2",
		dataVersion = "3.29",
		treeVersion = "3_29",
		knowledgeScope = "build_readiness",
		sourceDate = "2026-10-22",
		sourceDateStatus = "latest_dated_section",
		reviewedAt = "2026-10-23",
		license = {
			id = "MIT",
			path = "LICENSE.md",
			sha256 = LICENSE_SHA256,
			verified = true,
			scope = "repository-authored software and documentation",
		},
		usageScopes = { local_retrieval = true },
		status = "reviewed",
	},
}

local sourceById = { }
for _, source in ipairs(sources) do sourceById[source.sourceId] = source end

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = { }
	for key, child in pairs(value) do result[key] = copy(child) end
	return result
end

local function safeRelativePath(path)
	return type(path) == "string" and path ~= "" and #path <= 240
		and not path:find("[%c]") and not path:find("\\", 1, true)
		and path:sub(1, 1) ~= "/" and not path:match("^[%a]:")
		and path ~= ".." and not path:match("^%.%./")
		and not path:match("/%.%./") and not path:match("/%.%.$")
end

local function contextValues(context)
	if type(context) ~= "table" then return nil end
	local engine = type(context.engine) == "table" and context.engine or context
	return {
		game = context.game,
		patch = context.patch,
		pobVersion = engine.pobVersion,
		dataVersion = engine.dataVersion,
		treeVersion = engine.treeVersion,
		knowledgeScope = context.knowledgeScope,
		usageScope = context.usageScope,
	}
end

local function nonEmpty(value)
	return (type(value) == "string" or type(value) == "number") and tostring(value) ~= ""
end

-- Pure contract used by Search and focused tests. Hash arguments are observed
-- file hashes; callers cannot use this function to add a source to the private
-- allowlist or retrieve arbitrary paths.
function registry.ValidateSource(source, context, observedSourceHash, observedLicenseHash)
	if type(source) ~= "table" then return false, "unknown_source" end
	local current = contextValues(context)
	if not current then return false, "context_missing" end
	if not safeRelativePath(source.path) or not nonEmpty(source.sourceId) then return false, "source_identity_invalid" end
	if source.status ~= "reviewed" then return false, "source_not_reviewed" end
	if source.game ~= "poe1" or current.game ~= "poe1" then return false, "game_scope_mismatch" end
	if current.knowledgeScope ~= source.knowledgeScope or not nonEmpty(current.knowledgeScope) then
		return false, "knowledge_scope_mismatch"
	end
	local usageScope = current.usageScope or "local_retrieval"
	if type(source.usageScopes) ~= "table" or source.usageScopes[usageScope] ~= true
		or usageScope ~= "local_retrieval" then
		return false, "usage_scope_not_allowed"
	end
	local license = source.license
	if type(license) ~= "table" or license.verified ~= true or not nonEmpty(license.id)
		or not nonEmpty(license.scope) or not safeRelativePath(license.path) or type(license.sha256) ~= "string"
		or not license.sha256:match("^[%da-fA-F]+$") or #license.sha256 ~= 64 then
		return false, "license_missing_or_unverified"
	end
	if type(observedLicenseHash) ~= "string" or observedLicenseHash:upper() ~= license.sha256:upper() then
		return false, "license_hash_mismatch"
	end
	if type(source.sha256) ~= "string" or not source.sha256:match("^[%da-fA-F]+$") or #source.sha256 ~= 64
		or type(observedSourceHash) ~= "string" or observedSourceHash:upper() ~= source.sha256:upper() then
		return false, "source_hash_mismatch"
	end
	for _, key in ipairs({ "patch", "pobVersion", "dataVersion", "treeVersion" }) do
		if not nonEmpty(source[key]) or not nonEmpty(current[key]) or tostring(source[key]) ~= tostring(current[key]) then
			return false, "version_mismatch:" .. key
		end
	end
	if type(source.reviewedAt) ~= "string" or not source.reviewedAt:match("^%d%d%d%d%-%d%d%-%d%d$") then
		return false, "review_date_missing"
	end
	return true, "current"
end

function registry.ListSources()
	local result = { }
	for index, source in ipairs(sources) do result[index] = copy(source) end
	return result
end

function registry.GetSource(sourceId)
	local source = sourceById[sourceId]
	if not source then return nil, "unknown_source" end
	return copy(source)
end

local function applicationRoot()
	if type(GetScriptPath) == "function" then
		local path = GetScriptPath()
		if type(path) == "string" and path ~= "" then
			path = path:gsub("[/\\]+$", "")
			-- PoB's script path is the src directory (where Data/ lives), while
			-- repository documentation is one level above it.
			if path:match("[/\\]src$") then path = path:match("^(.*)[/\\][^/\\]+$") or path end
			return path
		end
	end
	-- HeadlessWrapper may run from the repository's src directory and its
	-- GetScriptPath stub returns an empty string. The fallback is only for the
	-- repository test/dev invocation.
	return ".."
end

local function joinRoot(root, relative)
	local separator = package.config and package.config:sub(1, 1) or "/"
	return root:gsub("[/\\]+$", "") .. separator .. relative:gsub("/", separator)
end

local function readAllowedFile(root, relative)
	if not safeRelativePath(relative) then return nil, "source_path_invalid" end
	local file, openError = io.open(joinRoot(root, relative), "rb")
	if not file then return nil, "source_unavailable:" .. tostring(openError or "open_failed") end
	local size = file:seek("end") or 0
	if size > MAX_DOCUMENT_BYTES then file:close() return nil, "source_too_large" end
	file:seek("set", 0)
	local content = file:read("*a")
	file:close()
	if type(content) ~= "string" then return nil, "source_read_failed" end
	return content, sha.sha256(content)
end

local function splitSections(text)
	local sections, stack, current = { }, { }, nil
	local lineNumber = 0
	local function finish(endLine)
		if current then
			current.endLine = endLine
			current.text = table.concat(current.lines, "\n")
			current.lines = nil
			sections[#sections + 1] = current
			current = nil
		end
	end
	for line in (text .. "\n"):gmatch("(.-)\n") do
		lineNumber = lineNumber + 1
		line = line:gsub("\r$", "")
		local hashes, title = line:match("^(#+)%s+(.+)%s*$")
		if hashes then
			finish(lineNumber - 1)
			local level = #hashes
			while #stack > 0 and stack[#stack].level >= level do table.remove(stack) end
			stack[#stack + 1] = { level = level, title = title }
			local path = { }
			for _, part in ipairs(stack) do path[#path + 1] = part.title end
			current = { section = table.concat(path, " > "), startLine = lineNumber, lines = { line } }
		elseif current then
			current.lines[#current.lines + 1] = line
		elseif lineNumber <= 20 and line ~= "" then
			current = { section = "Document preface", startLine = lineNumber, lines = { line } }
		end
	end
	finish(lineNumber - 1)
	return sections
end

local function normalizedTokens(value)
	local normalized = tostring(value or ""):lower():gsub("[^%w]+", " ")
	local seen, result = { }, { }
	for token in normalized:gmatch("%S+") do
		if #token >= 2 and not seen[token] then
			seen[token] = true
			result[#result + 1] = token
			if #result >= MAX_QUERY_TERMS then break end
		end
	end
	return result
end

local function scoreSection(text, queryTokens)
	local normalized = " " .. tostring(text):lower():gsub("[^%w]+", " ") .. " "
	local score, matched = 0, { }
	for _, token in ipairs(queryTokens) do
		local padded = " " .. token .. " "
		if normalized:find(padded, 1, true) then
			matched[#matched + 1] = token
			score = score + 1
		end
	end
	return score, matched
end

local function boundedText(text, maximum)
	if #text <= maximum then return text, false end
	if maximum <= 3 then return text:sub(1, maximum), true end
	local excerpt = text:sub(1, math.max(1, maximum - 3))
	local lastSpace = excerpt:match("^.*() ")
	if lastSpace and lastSpace > maximum * 0.7 then excerpt = excerpt:sub(1, lastSpace - 1) end
	return excerpt .. "…", true
end

local function validLimit(value, fallback, maximum)
	if value == nil then return fallback end
	if type(value) ~= "number" or value ~= math.floor(value) or value < 1 then return nil end
	return math.min(value, maximum)
end

function registry.Search(query, context, options)
	options = type(options) == "table" and options or { }
	if type(query) ~= "string" or query == "" or #query > MAX_QUERY_BYTES then
		return { status = "blocked", results = { }, reason = "query_invalid" }
	end
	local queryTokens = normalizedTokens(query)
	if #queryTokens == 0 then return { status = "blocked", results = { }, reason = "query_has_no_search_terms" } end
	local current = contextValues(context)
	if not current then return { status = "blocked", results = { }, reason = "context_missing" } end
	if current.game ~= "poe1" then return { status = "blocked", results = { }, reason = "game_scope_mismatch" } end
	if not nonEmpty(current.knowledgeScope) then return { status = "blocked", results = { }, reason = "knowledge_scope_missing" } end
	local usageScope = current.usageScope or "local_retrieval"
	if usageScope ~= "local_retrieval" then return { status = "blocked", results = { }, reason = "usage_scope_not_allowed" } end
	local limit = validLimit(options.maxResults, DEFAULT_RESULTS, MAX_RESULTS)
	local snippetLimit = validLimit(options.maxSnippetBytes, DEFAULT_SNIPPET_BYTES, MAX_SNIPPET_BYTES)
	if not limit or not snippetLimit then return { status = "blocked", results = { }, reason = "result_limit_invalid" } end
	local root = applicationRoot()
	local candidates, excluded, matchedScope = { }, { }, false
	for _, source in ipairs(sources) do
		if source.knowledgeScope == current.knowledgeScope then
			matchedScope = true
			local text, contentHashOrError = readAllowedFile(root, source.path)
			local licenseText, licenseHashOrError
			if type(source.license) == "table" then
				licenseText, licenseHashOrError = readAllowedFile(root, source.license.path)
			else
				licenseHashOrError = "license_missing_or_unverified"
			end
			if not text then
				excluded[#excluded + 1] = { sourceId = source.sourceId, reason = contentHashOrError }
			elseif not licenseText then
				excluded[#excluded + 1] = { sourceId = source.sourceId, reason = licenseHashOrError }
			else
				local valid, reason = registry.ValidateSource(source, context, contentHashOrError, licenseHashOrError)
				if not valid then
					excluded[#excluded + 1] = { sourceId = source.sourceId, reason = reason }
				else
					for _, section in ipairs(splitSections(text)) do
						local score, matchedTerms = scoreSection(section.text, queryTokens)
						if score > 0 then
							local snippet, truncated = boundedText(section.text, snippetLimit)
							candidates[#candidates + 1] = {
								sourceId = source.sourceId,
								path = source.path,
								sourceHash = source.sha256,
								patch = source.patch,
								pobVersion = source.pobVersion,
								dataVersion = source.dataVersion,
								treeVersion = source.treeVersion,
								game = source.game,
								knowledgeScope = source.knowledgeScope,
								sourceDate = source.sourceDate,
								sourceDateStatus = source.sourceDateStatus,
								reviewedAt = source.reviewedAt,
								license = copy(source.license),
								usageScope = usageScope,
								status = "current",
								evidenceKind = "repository_documentation",
								section = section.section,
								startLine = section.startLine,
								endLine = section.endLine,
								matchedTerms = matchedTerms,
								score = score,
								text = snippet,
								truncated = truncated,
							}
						end
					end
				end
			end
		end
	end
	table.sort(candidates, function(left, right)
		if left.score ~= right.score then return left.score > right.score end
		if left.sourceId ~= right.sourceId then return left.sourceId < right.sourceId end
		if left.section ~= right.section then return left.section < right.section end
		return left.startLine < right.startLine
	end)
	for index = #candidates, limit + 1, -1 do candidates[index] = nil end
	local status = #candidates > 0 and "current_matches"
		or (#excluded > 0 and "blocked") or (matchedScope and "no_match" or "scope_not_allowlisted")
	return {
		status = status,
		results = candidates,
		excluded = excluded,
		reason = status == "blocked" and excluded[1] and excluded[1].reason or nil,
		readOnly = true,
		modelUsed = false,
	}
end

registry.MAX_DOCUMENT_BYTES = MAX_DOCUMENT_BYTES
registry.MAX_QUERY_BYTES = MAX_QUERY_BYTES
registry.MAX_RESULTS = MAX_RESULTS
registry.MAX_SNIPPET_BYTES = MAX_SNIPPET_BYTES
return registry
