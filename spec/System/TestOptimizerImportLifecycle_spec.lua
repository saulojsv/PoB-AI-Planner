local Lifecycle = require("Modules.Optimizer.ImportLifecycle")
local BoundedInflate = require("Modules.Optimizer.BoundedInflate")
local Candidate = require("Modules.Optimizer.Candidate")
local Readiness = require("Modules.Optimizer.BuildReadiness")
local MCP = require("Modules.Optimizer.MCPBridge")
local json = require("dkjson")

describe("Native import lifecycle and scoped provenance", function()
	local originalBoundedInflate, originalDownload, originalAutoSave, originalNew, originalCharacterDownload, originalPage, originalBuildInit, originalBuildSaveDB, originalBuildShutdown, originalAdoptLoaded, originalMaxBuildCodeBytes
	local sourceXML, pending
	before_each(function()
		originalBoundedInflate, originalDownload, originalAutoSave = BoundedInflate.inflate, buildSites.DownloadBuild, main.disableDevAutoSave
		originalNew, originalCharacterDownload, originalPage = new, main.api.DownloadCharacter, launch.DownloadPage
		main.disableDevAutoSave = true
		newBuild()
		originalBuildInit = build.Init
		originalBuildSaveDB = build.SaveDB
		originalBuildShutdown = build.Shutdown
		originalAdoptLoaded = Lifecycle.AdoptLoaded
		originalMaxBuildCodeBytes = buildSites.MAX_BUILD_CODE_BYTES
		build.characterLevel, build.characterLevelAutoMode = 90, false
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		build.calcsTab:BuildOutput()
		build.buildFlag = false
		sourceXML = assert(build:SaveDB("Import lifecycle fixture"))
		-- HeadlessWrapper stubs compression. Only the bounded inflate boundary
		-- is replaced; base64, XML, native loaders and calculators remain real.
		BoundedInflate.inflate = function(bytes) return bytes end
		pending = { }
		buildSites.DownloadBuild = function(url, provider, callback)
			pending[#pending + 1] = { url = url, provider = provider, callback = callback }
		end
	end)
	after_each(function()
		BoundedInflate.inflate, buildSites.DownloadBuild = originalBoundedInflate, originalDownload
		new, main.api.DownloadCharacter, launch.DownloadPage = originalNew, originalCharacterDownload, originalPage
		if originalBuildInit then build.Init = originalBuildInit end
		if originalBuildSaveDB then build.SaveDB = originalBuildSaveDB end
		if originalBuildShutdown then build.Shutdown = originalBuildShutdown end
		if originalAdoptLoaded then Lifecycle.AdoptLoaded = originalAdoptLoaded end
		buildSites.MAX_BUILD_CODE_BYTES = originalMaxBuildCodeBytes
		originalBuildInit = nil
		originalBuildSaveDB = nil
		originalBuildShutdown = nil
		originalAdoptLoaded = nil
		originalMaxBuildCodeBytes = nil
		while main.popups[1] do main:ClosePopup() end
		main.disableDevAutoSave = originalAutoSave
	end)
	local function code(xml) return common.base64.encode(xml) end
	local function preview(xml)
		local owner = build.importTab
		owner.controls.importCodeIn:SetText(code(xml), true)
		return owner
	end
	local function request(url, mode)
		local owner = build.importTab
		owner.controls.importCodeIn:SetText(url, true)
		owner.controls.importCodeMode.selIndex = mode or 2
		owner.controls.importCodeGo:Click()
		assert.is_true(owner.importCodeFetching)
		return owner
	end
	it("decodes build codes through the shared bounded and framed import path", function()
		local xmlText, previewData = Lifecycle.DecodeBuildCode(code(sourceXML))
		assert.are.equal(sourceXML, xmlText)
		assert.is_true(previewData.sectionCoverage.Tree)
	end)
	it("rejects oversized encoded build data before decoding it", function()
		local previousLimit = buildSites.MAX_BUILD_CODE_BYTES
		buildSites.MAX_BUILD_CODE_BYTES = 4
		local xmlText, reason = Lifecycle.DecodeBuildCode("oversized")
		buildSites.MAX_BUILD_CODE_BYTES = previousLimit
		assert.is_nil(xmlText)
		assert.are.equal("payload_too_large", reason)
	end)
	it("rejects non-PoB XML before shared import callers can consume it", function()
		local xmlText, reason = Lifecycle.DecodeBuildCode(code("<Other/>"))
		assert.is_nil(xmlText)
		assert.are.equal("wrong_root", reason)
	end)
	it("recognizes current, partial and legacy framing without certifying full build integrity", function()
		local full = assert(Lifecycle.ValidateXML(sourceXML))
		assert.are.equal(liveTargetVersion, full.targetVersion)
		assert.is_false(full.requiresConversion)
		for _, key in ipairs({ "Build", "Tree", "Skills", "Items", "Config" }) do assert.is_true(full.sectionCoverage[key]) end
		local partial = assert(Lifecycle.ValidateXML('<PathOfBuilding><Build targetVersion="' .. liveTargetVersion .. '"/></PathOfBuilding>'))
		assert.is_false(partial.sectionCoverage.Skills)
		assert.are.equal("pob1_xml_structure_only", partial.validationScope)
		local legacy = assert(Lifecycle.ValidateXML('<PathOfBuilding><Build targetVersion="' .. legacyTargetVersion .. '"/></PathOfBuilding>'))
		assert.is_true(legacy.requiresConversion)
		assert.is_true(assert(Lifecycle.ValidateXML('<PathOfBuilding/>')).requiresConversion)
	end)
	it("rejects malformed, wrong-root, duplicate-Build and unknown-game-version payloads", function()
		for _, xml in ipairs({ "not XML", "<Other/>", '<PathOfBuilding><Build/><Build/></PathOfBuilding>',
			'<PathOfBuilding><Build targetVersion="unknown-game-family"/></PathOfBuilding>' }) do
			assert.is_nil(Lifecycle.ValidateXML(xml))
		end
	end)
	it("rejects oversized XML before invoking the native parser", function()
		local coverage, reason = Lifecycle.ValidateXML(string.rep(" ", Lifecycle.MAX_POB_XML_BYTES + 1))
		assert.is_nil(coverage)
		assert.are.equal("payload_too_large", reason)
	end)
	it("does not accept decompressed non-XML as a valid preview or replace the active build", function()
		local signature = Candidate.BuildSignature(build)
		local owner = preview("not a PoB XML")
		assert.is_false(owner.importCodeValid)
		assert.are.equal("invalid_preview", Lifecycle.Snapshot(owner).status)
		owner.controls.importCodeGo:Click()
		assert.are.equal(owner, build.importTab)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("rejects an oversized pasted build code before decompression", function()
		local inflateCalls = 0
		buildSites.MAX_BUILD_CODE_BYTES = 16
		BoundedInflate.inflate = function() inflateCalls = inflateCalls + 1; return sourceXML end
		local owner = preview(string.rep("A", 17))
		assert.are.equal(0, inflateCalls)
		assert.is_false(owner.importCodeValid)
		assert.are.equal("download_too_large", Lifecycle.Snapshot(owner).reasonCode)
		assert.is_truthy(owner.importCodeDetail:find(Lifecycle.FailureMessage("download_too_large"), 1, true))
	end)
	it("uses the bounded zlib inflater in the real build-code input path", function()
		BoundedInflate.inflate = originalBoundedInflate
		local compressed = ("789cb309482cc9f04f732acdcc49c9cc4bb7b301b3144a128bd2534bc2528b8a33f3f36c958ce30d94f4ed6cf4d1140300a266156d"):gsub("..", function(pair)
			return string.char(tonumber(pair, 16))
		end)
		local expectedXML = '<PathOfBuilding><Build targetVersion="3_0"/></PathOfBuilding>'
		local signature = Candidate.BuildSignature(build)
		local owner = build.importTab
		owner.controls.importCodeIn:SetText(common.base64.encode(compressed), true)
		assert.is_true(owner.importCodeValid, owner.importCodeDetail)
		assert.are.equal(expectedXML, owner.importCodeXML)
		assert.are.equal("valid_preview", Lifecycle.Snapshot(owner).status)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("catches decode errors and keeps raw failure details out of readiness and MCP", function()
		local signature = Candidate.BuildSignature(build)
		BoundedInflate.inflate = function() error("https://private.invalid/?token=SECRET") end
		local owner = preview(sourceXML)
		assert.are.equal("decode_failed", Lifecycle.Snapshot(owner).status)
		local snapshot = assert(MCP:CallLocal("get_build_snapshot", { }))
		assert.are.equal("invalid_code", snapshot.buildReadiness.importAttempt.reasonCode)
		assert.is_nil(json.encode(snapshot.buildReadiness):find("SECRET", 1, true))
		assert.is_false(snapshot.buildReadiness.importAttempt.affectsLoadedBuild)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("ignores an old download after editing the source input", function()
		local signature = Candidate.BuildSignature(build)
		local owner = request("https://pobb.in/qa-first")
		owner.controls.importCodeIn:SetText("", true)
		pending[1].callback(true, code(sourceXML))
		assert.are.equal("empty", Lifecycle.Snapshot(owner).status)
		assert.is_false(owner.importCodeFetching)
		assert.are.equal(owner, build.importTab)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("ignores callbacks from a replaced native build", function()
		local old = request("https://pobb.in/qa-first")
		newBuild()
		local signature = Candidate.BuildSignature(build)
		pending[1].callback(true, code(sourceXML))
		assert.are_not.equal(old, build.importTab)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("does not let out-of-order downloads replace the newer request", function()
		local owner = request("https://pobb.in/qa-first", 3)
		request("https://pobb.in/qa-second", 3)
		local signature = Candidate.BuildSignature(build)
		pending[1].callback(true, code(sourceXML))
		assert.is_true(owner.importCodeFetching)
		assert.are.equal(0, #build.compareTab.compareEntries)
		pending[2].callback(true, code(sourceXML))
		assert.are.equal(1, #build.compareTab.compareEntries)
		assert.are.equal("comparison", Lifecycle.Snapshot(owner).target)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("does not import a delayed download into a different mode", function()
		local owner = request("https://pobb.in/qa-first", 3)
		owner.controls.importCodeMode.selIndex = 2
		local signature = Candidate.BuildSignature(build)
		pending[1].callback(true, code(sourceXML))
		assert.are.equal("valid_preview", Lifecycle.Snapshot(owner).status)
		assert.are.equal(owner, build.importTab)
		assert.is_false(owner.importCodeFetching)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("reports a failed provider attempt independently of a still-calculable active build", function()
		local signature = Candidate.BuildSignature(build)
		local owner = request("https://pobb.in/qa-failure")
		pending[1].callback(false, "https://private.invalid/?token=SECRET")
		local report = Readiness.Evaluate(build)
		assert.are.equal("download_failed", report.importAttempt.status)
		assert.is_false(report.importAttempt.affectsLoadedBuild)
		assert.is_true(report.capabilities.exactMetrics)
		assert.is_nil(json.encode(report):find("SECRET", 1, true))
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("shows a typed provider response failure without retaining server text", function()
		local owner = request("https://pobb.in/qa-empty-response")
		pending[1].callback(false, "secret server body", "https://pobb.in/pob/qa-empty-response", "download_invalid_response")
		local report = Readiness.Evaluate(build)
		assert.are.equal("download_failed", report.importAttempt.status)
		assert.are.equal("download_invalid_response", report.importAttempt.reasonCode)
		assert.are.equal("O provedor não devolveu um export de build utilizável.", report.importAttempt.message)
		assert.is_nil(json.encode(report):find("secret server body", 1, true))
		assert.are.equal(owner, build.importTab)
	end)
	it("retains native provider identity and URL only in the existing native import-link path", function()
		local url = "https://pobb.in/qa-provider"
		local owner = request(url)
		pending[1].callback(true, code(sourceXML))
		assert.are_not.equal(owner, build.importTab)
		local report = Lifecycle.Snapshot(build.importTab)
		assert.are.equal("loaded", report.status)
		assert.is_true(report.affectsLoadedBuild)
		assert.are.equal("POBBin", report.providerId)
		assert.are.equal(url, build.importLink)
		assert.is_nil(json.encode(report):find(url, 1, true))
		assert.are.equal("observed_import_event", report.origins[1].evidence)
	end)
	it("does not promote a downloaded malformed payload to loaded", function()
		local signature = Candidate.BuildSignature(build)
		local owner = request("https://pobb.in/qa-bad")
		pending[1].callback(true, code("not XML"))
		assert.is_false(owner.importCodeValid)
		assert.are.equal("invalid_preview", Lifecycle.Snapshot(owner).status)
		assert.are.equal(owner, build.importTab)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("invalidates a confirmation when the code changes before approval", function()
		local owner = preview(sourceXML)
		owner.controls.importCodeMode.selIndex = 1
		owner.controls.importCodeGo:Click()
		assert.are.equal("Build Import", main.popups[1].title)
		local popup = main.popups[1]
		owner.controls.importCodeIn:SetText(code(sourceXML:gsub('level="90"', 'level="42"', 1)), true)
		local signature = Candidate.BuildSignature(build)
		popup.controls.confirm:Click()
		assert.are.equal(owner, build.importTab)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("applies the confirmed captured XML through native Init and records loaded only after completion", function()
		local owner = preview(sourceXML:gsub('level="90"', 'level="42"', 1))
		owner.controls.importCodeMode.selIndex = 1
		owner.controls.importCodeGo:Click()
		assert.are.equal("valid_preview", Lifecycle.Snapshot(owner).status)
		main.popups[1].controls.confirm:Click()
		assert.are.equal(42, build.characterLevel)
		assert.are_not.equal(owner, build.importTab)
		assert.are.equal("loaded", Lifecycle.Snapshot(build.importTab).status)
		assert.are.equal("current", Lifecycle.Snapshot(build.importTab).target)
		assert.is_false(build.abortSave)
	end)
	it("does not start an import if a recovery snapshot cannot be serialized", function()
		local originalSignature = Candidate.BuildSignature(build)
		local owner = preview(sourceXML:gsub('level="90"', 'level="42"', 1))
		owner.controls.importCodeMode.selIndex = 1
		owner.controls.importCodeGo:Click()
		local initCount = 0
		build.SaveDB = function() error("injected recovery snapshot serialization failure") end
		build.Init = function(instance, ...)
			initCount = initCount + 1
			return originalBuildInit(instance, ...)
		end
		main.popups[1].controls.confirm:Click()
		assert.are.equal(0, initCount, "native Init must not run without a recoverable source snapshot")
		assert.are.equal(originalSignature, Candidate.BuildSignature(build))
		assert.are.equal(90, build.characterLevel)
		assert.are.equal(owner, build.importTab)
		local attempt = Lifecycle.Snapshot(owner)
		assert.are.equal("native_load_unconfirmed", attempt.status)
		assert.are.equal("source_snapshot_failed", attempt.reasonCode)
	end)
	it("restores the exact source build if native Init throws after replacing it", function()
		local originalSignature = Candidate.BuildSignature(build)
		local originalViewMode = build.viewMode
		local originalFileName, originalBuildName = build.dbFileName, build.buildName
		local targetXML = sourceXML:gsub('level="90"', 'level="42"', 1)
		local owner = preview(targetXML)
		owner.controls.importCodeMode.selIndex = 1
		owner.controls.importCodeGo:Click()
		local originalInit = originalBuildInit
		local injected = false
		build.Init = function(instance, fileName, buildName, buildXML, convertBuild, importLink)
			local result = originalInit(instance, fileName, buildName, buildXML, convertBuild, importLink)
			if not injected and buildXML == targetXML then
				injected = true
				error("injected failure after target build initialization")
			end
			return result
		end
		main.popups[1].controls.confirm:Click()
		assert.is_true(injected)
		assert.are.equal(90, build.characterLevel, "the source character level must be restored after the injected post-Init failure")
		local restoredSignature = Candidate.BuildSignature(build)
		local mismatch = 1
		while mismatch <= #originalSignature and originalSignature:sub(mismatch, mismatch) == restoredSignature:sub(mismatch, mismatch) do
			mismatch = mismatch + 1
		end
		assert.are.equal(originalSignature, restoredSignature,
			string.format("source mismatch at %d: before=%s after=%s", mismatch,
				originalSignature:sub(math.max(1, mismatch - 100), mismatch + 90),
				restoredSignature:sub(math.max(1, mismatch - 100), mismatch + 90)))
		assert.are.equal(90, build.characterLevel)
		assert.are.equal(originalFileName, build.dbFileName)
		assert.are.equal(originalBuildName, build.buildName)
		assert.are.equal(originalViewMode, build.viewMode)
		assert.is_false(build.abortSave)
		local attempt = Lifecycle.Snapshot(build.importTab)
		assert.are.equal("native_load_unconfirmed", attempt.status)
		assert.are.equal("native_load_failed", attempt.reasonCode)
	end)
	it("restores the exact source build if native Shutdown throws during replacement", function()
		local originalSignature = Candidate.BuildSignature(build)
		local originalViewMode = build.viewMode
		local originalFileName, originalBuildName = build.dbFileName, build.buildName
		local targetXML = sourceXML:gsub('level="90"', 'level="42"', 1)
		local owner = preview(targetXML)
		owner.controls.importCodeMode.selIndex = 1
		owner.controls.importCodeGo:Click()
		local shutdownCalls = 0
		build.Shutdown = function(instance)
			shutdownCalls = shutdownCalls + 1
			originalBuildShutdown(instance)
			if shutdownCalls == 1 then error("injected shutdown failure after native cleanup") end
		end
		main.popups[1].controls.confirm:Click()
		assert.are.equal(2, shutdownCalls, "the rollback cleanup should run after the first shutdown error")
		assert.are.equal(originalSignature, Candidate.BuildSignature(build))
		assert.are.equal(90, build.characterLevel)
		assert.are.equal(originalFileName, build.dbFileName)
		assert.are.equal(originalBuildName, build.buildName)
		assert.are.equal(originalViewMode, build.viewMode)
		assert.is_false(build.abortSave)
		local attempt = Lifecycle.Snapshot(build.importTab)
		assert.are.equal("native_load_unconfirmed", attempt.status)
		assert.are.equal("native_shutdown_failed", attempt.reasonCode)
	end)
	it("restores the exact source build if import lifecycle adoption fails after native calculation", function()
		local originalSignature = Candidate.BuildSignature(build)
		local targetXML = sourceXML:gsub('level="90"', 'level="42"', 1)
		local owner = preview(targetXML)
		owner.controls.importCodeMode.selIndex = 1
		owner.controls.importCodeGo:Click()
		Lifecycle.AdoptLoaded = function(...)
			originalAdoptLoaded(...)
			error("injected lifecycle adoption failure")
		end
		main.popups[1].controls.confirm:Click()
		assert.are.equal(originalSignature, Candidate.BuildSignature(build))
		assert.are.equal(90, build.characterLevel)
		assert.is_false(build.abortSave)
		local attempt = Lifecycle.Snapshot(build.importTab)
		assert.are.equal("native_load_unconfirmed", attempt.status)
		assert.are.equal("native_commit_failed", attempt.reasonCode)
	end)
	it("does not claim source recovery when native restoration itself fails", function()
		local targetXML = sourceXML:gsub('level="90"', 'level="42"', 1)
		local owner = preview(targetXML)
		owner.controls.importCodeMode.selIndex = 1
		owner.controls.importCodeGo:Click()
		build.Init = function(instance, fileName, buildName, buildXML, convertBuild, importLink)
			if buildXML == sourceXML then error("injected source restoration failure") end
			local result = originalBuildInit(instance, fileName, buildName, buildXML, convertBuild, importLink)
			if buildXML == targetXML then error("injected target failure after native load") end
			return result
		end
		main.popups[1].controls.confirm:Click()
		local attempt = Lifecycle.Snapshot(build.importTab)
		assert.are.equal("native_load_unconfirmed", attempt.status)
		assert.are.equal("source_restore_failed", attempt.reasonCode)
		assert.is_truthy(attempt.message:find("Não trate o estado atual como íntegro", 1, true))
	end)
	it("asks for native legacy conversion before shutting down the source", function()
		local legacy = sourceXML:gsub('targetVersion="' .. liveTargetVersion .. '"', 'targetVersion="' .. legacyTargetVersion .. '"', 1)
		local signature = Candidate.BuildSignature(build)
		local owner = preview(legacy)
		owner.controls.importCodeGo:Click()
		assert.are.equal(owner, build.importTab)
		assert.are.equal("Build Import", main.popups[1].title)
		assert.are.equal(signature, Candidate.BuildSignature(build))
		main.popups[1].controls.confirm:Click()
		assert.are.equal(liveTargetVersion, build.targetVersion)
		assert.are.equal("loaded", Lifecycle.Snapshot(build.importTab).status)
	end)
	it("keeps comparison provenance separate from the primary build", function()
		local signature = Candidate.BuildSignature(build)
		local owner = request("https://pobb.in/qa-comparison", 3)
		pending[1].callback(true, code(sourceXML))
		assert.are.equal(owner, build.importTab)
		assert.is_false(Lifecycle.Snapshot(owner).affectsLoadedBuild)
		assert.are.equal(0, #Lifecycle.Snapshot(owner).origins)
		local entry = build.compareTab.compareEntries[1]
		local report = Readiness.Evaluate(entry)
		assert.are.equal("loaded", report.importAttempt.status)
		assert.are.equal("comparison", report.importAttempt.target)
		assert.are.equal("POBBin", report.importAttempt.origins[1].providerId)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	it("reclassifies saved provenance as unverified metadata and discards unknown fields", function()
		local owner = build.importTab
		Lifecycle.Observe(owner, "tree", { kind = "character_payload", url = "SECRET-LINK" }, "replace", {
			league = "Fixture League", account = "SECRET-ACCOUNT", name = "SECRET-CHARACTER" }, "pc")
		local saved = { }
		Lifecycle.Save(owner, saved)
		assert.are.equal(1, #saved)
		saved[1].attrib.evidence = "observed_import_event"
		saved[1].attrib.account = "SECRET-ACCOUNT"
		saved[#saved + 1] = { elem = "PlannerOrigin", attrib = { schemaVersion = "99", component = "items" } }
		local restored = { }
		Lifecycle.Load(restored, saved)
		local report = Lifecycle.Snapshot(restored)
		assert.are.equal(1, #report.origins)
		assert.are.equal("saved_metadata_unverified", report.origins[1].evidence)
		assert.is_false(report.origins[1].currentStateCertified)
		assert.are.equal("Fixture League", report.origins[1].league)
		assert.are.equal("pc", report.origins[1].realm)
		assert.is_nil(json.encode(report):find("SECRET", 1, true))
	end)
	it("reports mixed component league metadata as conflicting instead of inferring a whole-build league", function()
		local owner = build.importTab
		owner.lastLeague, owner.lastRealm = "SAVED-SELECTION", "XBOX"
		Lifecycle.Observe(owner, "tree", { kind = "character_payload" }, "replace", { league = "First League" }, "pc")
		Lifecycle.Observe(owner, "items", { kind = "character_payload" }, "merge", { league = "Other League" }, "xbox")
		local report = Readiness.Evaluate(build)
		assert.are.equal("conflicting_sources", report.identity.leagueStatus)
		assert.are.equal("conflicting_sources", report.identity.sourceRealmStatus)
		assert.are.equal(2, #report.importAttempt.origins)
		assert.is_nil(report.identity.sourceMetadata.league.value)
		assert.is_nil(report.identity.sourceMetadata.sourceRealm.value)
		assert.is_false(report.identity.sourceMetadata.currentBuildIdentityCertified)
		assert.is_nil(report.identity.league)
		assert.is_nil(report.identity.platform)
	end)
	it("refreshes the cached diagnosis when only lifecycle revision/status changes", function()
		local tab = build.optimizerTab
		tab.width, tab.height = 800, 520
		tab:Layout({ width = 800, height = 520 })
		local first = tab:RefreshReadiness(true)
		local owner = request("https://pobb.in/qa-cache")
		local fetching = tab:RefreshReadiness(false)
		assert.are_not.equal(first, fetching)
		assert.are.equal("fetching", fetching.importAttempt.status)
		pending[1].callback(false, "Download information not found")
		local failed = tab:RefreshReadiness(false)
		assert.are.equal("provider_unresolved", failed.importAttempt.reasonCode)
		assert.are.equal("download_failed", Lifecycle.Snapshot(owner).status)
	end)
	it("reports provider mismatch and malformed profile URLs without network access or build mutation", function()
		local originalSignature = Candidate.BuildSignature(build)
		local owner = build.importTab
		buildSites.DownloadBuild = originalDownload
		local downloadRequests = 0
		launch.DownloadPage = function() downloadRequests = downloadRequests + 1 end
		local cases = {
			{ url = "https://pob.codes/b/not-pobb", reason = "provider_link_mismatch", selectedSite = "POBBin" },
			{ url = "https://pobb.in/u/incomplete", reason = "provider_link_invalid", selectedSite = "POBBin" },
			{ url = "https://pobb.in/" .. string.rep("x", 4097), reason = "provider_link_invalid", selectedSite = "POBBin" },
		}
		for _, case in ipairs(cases) do
			owner.controls.importCodeIn:SetText(case.url, true)
			for index, site in ipairs(buildSites.websiteList) do
				if site.id == case.selectedSite then owner.importCodeSite = index break end
			end
			owner.controls.importCodeMode.selIndex = 2
			owner.controls.importCodeGo:Click()
			local report = Lifecycle.Snapshot(owner)
			assert.are.equal("download_failed", report.status)
			assert.are.equal(case.reason, report.reasonCode)
			assert.is_truthy(owner.importCodeDetail:find(Lifecycle.FailureMessage(case.reason), 1, true))
		end
		assert.are.equal(0, downloadRequests)
		assert.are.equal(originalSignature, Candidate.BuildSignature(build))
	end)
	it("uses the native global import callback to reject decoded wrong-root XML", function()
		local result
		assert.is_true(ImportBuild(code("<Other/>"), function(xml, source, err) result = { xml = xml, err = err } end))
		assert.is_nil(result.xml)
		assert.is_truthy(result.err)
	end)
	it("keeps the source intact when the isolated native loader raises before import", function()
		local signature = Candidate.BuildSignature(build)
		local owner = preview(sourceXML)
		new = function(class, ...)
			if class == "CompareEntry" then error("injected native loader failure") end
			return originalNew(class, ...)
		end
		owner.controls.importCodeGo:Click()
		assert.are.equal("native_load_unconfirmed", Lifecycle.Snapshot(owner).status)
		assert.are.equal(owner, build.importTab)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
	local function characterFixture()
		local file = assert(io.open("../spec/System/SampleCharacter.json", "r"))
		local sample = assert(json.decode(file:read("*a"))).character
		file:close()
		return sample
	end
	it("records successful native character imports by component and preserves unknown realm when omitted", function()
		local owner, sample = build.importTab, characterFixture()
		owner:ImportItemsAndSkills(sample, false, true, false, "sony")
		owner:ImportPassiveTreeAndJewels(sample, false)
		local report = Lifecycle.Snapshot(owner)
		assert.are.equal(3, #report.origins)
		local byComponent = { }
		for _, origin in ipairs(report.origins) do byComponent[origin.component] = origin end
		assert.are.equal("replace_tree_keep_jewels", byComponent.tree.operation)
		assert.is_nil(byComponent.tree.realm)
		assert.are.equal("merge", byComponent.items.operation)
		assert.are.equal("replace", byComponent.skills.operation)
		assert.are.equal("sony", byComponent.items.realm)
		assert.are.equal(sample.league, byComponent.tree.league)
		assert.is_nil(byComponent.tree.account)
		assert.is_nil(byComponent.tree.name)
	end)
	it("persists only bounded metadata through native build XML and reloads it as unverified", function()
		Lifecycle.Observe(build.importTab, "tree", { kind = "character_payload" }, "replace", { league = "Fixture League" }, "pc")
		local xml = assert(build:SaveDB("Provenance fixture"))
		assert.is_truthy(xml:find("PlannerOrigin", 1, true))
		loadBuildFromXML(xml, "Provenance fixture")
		local origins = Lifecycle.Snapshot(build.importTab).origins
		assert.are.equal(1, #origins)
		assert.are.equal("saved_metadata_unverified", origins[1].evidence)
		assert.are.equal("Fixture League", origins[1].league)
	end)
	it("ignores an OAuth character response after the selected character changes", function()
		local owner = build.importTab
		owner.controls.charSelect.list = { { label = "Fixture A" }, { label = "Fixture B" } }
		owner.controls.charSelect.selIndex = 1
		local callback
		main.api.DownloadCharacter = function(_, _, _, cb) callback = cb end
		owner.controls.charImportTree.onClick()
		assert.is_function(callback)
		owner.controls.charSelect.selIndex = 2
		local signature = Candidate.BuildSignature(build)
		callback({ character = characterFixture() })
		assert.are.equal(signature, Candidate.BuildSignature(build))
		assert.are.equal(0, #Lifecycle.Snapshot(owner).origins)
		assert.is_false(owner.oauthLoading)
	end)
	it("ignores out-of-order OAuth responses for the same component", function()
		local owner = build.importTab
		owner.controls.charSelect.list = { { label = "Fixture A" } }
		owner.controls.charSelect.selIndex = 1
		local callbacks = { }
		main.api.DownloadCharacter = function(_, _, _, cb) callbacks[#callbacks + 1] = cb end
		owner.controls.charImportItems.onClick()
		owner.controls.charImportItems.onClick()
		local signature = Candidate.BuildSignature(build)
		callbacks[1]({ character = characterFixture() })
		assert.are.equal(signature, Candidate.BuildSignature(build))
		assert.are.equal(0, #Lifecycle.Snapshot(owner).origins)
		callbacks[2]({ character = characterFixture() })
		assert.are.equal(2, #Lifecycle.Snapshot(owner).origins)
		assert.are.equal("pc", Lifecycle.Snapshot(owner).origins[1].realm)
	end)
	it("ignores an account-name tree response after replacing its source build", function()
		local owner = build.importTab
		owner.controls.siteAccountName:SetText("Fixture Account", false)
		owner.controls.siteCharSelect.list = { { char = { name = "Fixture A" } } }
		owner.controls.siteCharSelect.selIndex = 1
		local callback
		-- Native launch.DownloadPage is called with colon and URL/callback.
		launch.DownloadPage = function(_, _, cb) callback = cb end
		owner:DownloadPassiveTree(owner.controls.siteAccountRealm:GetSelValue())
		assert.is_function(callback)
		newBuild()
		local signature = Candidate.BuildSignature(build)
		callback({ body = "{}" })
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
end)
