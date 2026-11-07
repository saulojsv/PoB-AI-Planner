local KnowledgeRegistry = require("Modules.Optimizer.KnowledgeRegistry")

local function context(scope)
	return {
		game = "poe1",
		patch = "3.29",
		pobVersion = "2.67.2",
		dataVersion = "3.29",
		treeVersion = "3_29",
		knowledgeScope = scope or "build_readiness",
		usageScope = "local_retrieval",
	}
end

describe("Optimizer local versioned knowledge registry", function()
	it("retrieves a grounded local section with exact provenance and line reference", function()
		local result = KnowledgeRegistry.Search("selected main skill setup", context())
		assert.are.equal("current_matches", result.status)
		assert.is_true(result.readOnly)
		assert.is_false(result.modelUsed)
		assert.is_truthy(#result.results >= 1)
		local snippet = result.results[1]
		assert.are.equal("optimizer-build-readiness", snippet.sourceId)
		assert.are.equal("docs/optimizer/BUILD_READINESS.md", snippet.path)
		assert.are.equal("3.29", snippet.patch)
		assert.are.equal("3.29", snippet.dataVersion)
		assert.are.equal("3_29", snippet.treeVersion)
		assert.are.equal("MIT", snippet.license.id)
		assert.is_true(snippet.license.verified)
		assert.are.equal("local_retrieval", snippet.usageScope)
		assert.are.equal("current", snippet.status)
		assert.is_truthy(snippet.section:find("Scope and states", 1, true))
		assert.is_truthy(snippet.startLine >= 1)
		assert.is_truthy(snippet.endLine >= snippet.startLine)
		assert.is_truthy(snippet.text:find("selected Main Skill setup", 1, true))
	end)

	it("rejects source-content and version mismatches before retrieval", function()
		local source = assert(KnowledgeRegistry.GetSource("optimizer-build-readiness"))
		local valid, reason = KnowledgeRegistry.ValidateSource(source, context(), string.rep("0", 64), source.license.sha256)
		assert.is_false(valid)
		assert.are.equal("source_hash_mismatch", reason)
		local staleContext = context()
		staleContext.patch = "3.28"
		valid, reason = KnowledgeRegistry.ValidateSource(source, staleContext, source.sha256, source.license.sha256)
		assert.is_false(valid)
		assert.are.equal("version_mismatch:patch", reason)
		staleContext = context()
		staleContext.dataVersion = "3.28"
		valid, reason = KnowledgeRegistry.ValidateSource(source, staleContext, source.sha256, source.license.sha256)
		assert.is_false(valid)
		assert.are.equal("version_mismatch:dataVersion", reason)
		valid, reason = KnowledgeRegistry.ValidateSource(source, context(), source.sha256, string.rep("0", 64))
		assert.is_false(valid)
		assert.are.equal("license_hash_mismatch", reason)
		staleContext = context()
		staleContext.patch = "3.28"
		local result = KnowledgeRegistry.Search("selected main skill setup", staleContext)
		assert.are.equal("blocked", result.status)
		assert.are.equal(0, #result.results)
		assert.are.equal("version_mismatch:patch", result.excluded[1].reason)
	end)

	it("rejects missing license or an unauthorized usage scope", function()
		local source = assert(KnowledgeRegistry.GetSource("optimizer-build-readiness"))
		local license, licenseScope = source.license, source.license.scope
		source.license = nil
		local valid, reason = KnowledgeRegistry.ValidateSource(source, context(), source.sha256, license.sha256)
		assert.is_false(valid)
		assert.are.equal("license_missing_or_unverified", reason)
		source.license = license
		source.license.scope = nil
		valid, reason = KnowledgeRegistry.ValidateSource(source, context(), source.sha256, license.sha256)
		assert.is_false(valid)
		assert.are.equal("license_missing_or_unverified", reason)
		source.license.scope = licenseScope
		source.usageScopes = { }
		valid, reason = KnowledgeRegistry.ValidateSource(source, context(), source.sha256, license.sha256)
		assert.is_false(valid)
		assert.are.equal("usage_scope_not_allowed", reason)
		local trainingContext = context()
		trainingContext.usageScope = "training"
		valid, reason = KnowledgeRegistry.ValidateSource(source, trainingContext, source.sha256, license.sha256)
		assert.is_false(valid)
		assert.are.equal("usage_scope_not_allowed", reason)
	end)

	it("excludes PoE 2, unknown source IDs, and unallowlisted knowledge scopes", function()
		local result = KnowledgeRegistry.Search("selected main skill setup", setmetatable({ game = "poe2" }, { __index = context() }))
		assert.are.equal("blocked", result.status)
		assert.are.equal("game_scope_mismatch", result.reason)
		local source, unknownError = KnowledgeRegistry.GetSource("unlisted-external-source")
		assert.is_nil(source)
		assert.are.equal("unknown_source", unknownError)
		local unknownScope = context("external_build_guides")
		result = KnowledgeRegistry.Search("guide build", unknownScope)
		assert.are.equal("scope_not_allowlisted", result.status)
		assert.are.equal(0, #result.results)
	end)

	it("bounds result count and snippet size deterministically", function()
		local options = { maxResults = 1, maxSnippetBytes = 256 }
		local result = KnowledgeRegistry.Search("the native build skill", context(), options)
		assert.are.equal("current_matches", result.status)
		assert.are.equal(1, #result.results)
		assert.is_true(#result.results[1].text <= 256)
		assert.is_truthy(result.results[1].section)
		local invalid = KnowledgeRegistry.Search("build", context(), { maxResults = 0 })
		assert.are.equal("blocked", invalid.status)
		assert.are.equal("result_limit_invalid", invalid.reason)
	end)

	it("returns detached metadata so callers cannot mutate the private allowlist", function()
		local source = assert(KnowledgeRegistry.GetSource("optimizer-build-readiness"))
		source.license.id = "unknown"
		source.usageScopes.local_retrieval = false
		local again = assert(KnowledgeRegistry.GetSource("optimizer-build-readiness"))
		assert.are.equal("MIT", again.license.id)
		assert.is_true(again.usageScopes.local_retrieval)
	end)
end)
