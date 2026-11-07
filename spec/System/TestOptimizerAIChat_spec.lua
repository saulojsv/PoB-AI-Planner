local dkjson = require("dkjson")
local Auth = require("Modules.Optimizer.SIWC")
local AIChat = require("Modules.Optimizer.AIChat")
local CallbackRequest = require("Modules.Optimizer.CallbackRequest")

local function runCallbackServer(requests, expectedState)
	local captured = { pages = { }, logs = { }, openUrl = nil, requestIndex = 0 }
	local originalSocket = package.loaded.socket
	local originalOpenURL, originalConPrintf = OpenURL, ConPrintf
	local server = { }
	function server:setoption() return true end
	function server:bind(host, port)
		captured.host, captured.requestedPort = host, port
		return true
	end
	function server:listen(backlog) captured.backlog = backlog return true end
	function server:getsockname() return "127.0.0.1", 43127 end
	function server:settimeout(timeout) captured.timeout = timeout return true end
	function server:accept()
		captured.requestIndex = captured.requestIndex + 1
		local fixture = requests[captured.requestIndex]
		if not fixture then return nil, "timeout" end
		local client = { }
		function client:settimeout() return true end
		function client:getpeername() return fixture.peer or "127.0.0.1", 50000 end
		function client:receive() return fixture.line end
		function client:send(response) captured.pages[#captured.pages + 1] = response return #response end
		function client:close() return true end
		return client
	end
	function server:close() captured.closed = true return true end
	package.loaded.socket = { tcp4 = function() return server end }
	OpenURL = function(url) captured.openUrl = url end
	ConPrintf = function(message, ...)
		captured.logs[#captured.logs + 1] = select("#", ...) > 0 and string.format(message, ...) or tostring(message)
	end
	local ok, code, errorMessage, returnedState, clientId, scope, port = pcall(function()
		local callbackChunk, loadError = loadfile("LaunchServerSIWC.lua")
		assert(callbackChunk, loadError)
		return callbackChunk(expectedState, "oaiapp-synthetic", "https://auth.invalid/authorize?redirect_uri=http://127.0.0.1:__PORT__/auth/callback")
	end)
	package.loaded.socket = originalSocket
	OpenURL, ConPrintf = originalOpenURL, originalConPrintf
	if not ok then error(code) end
	return captured, code, errorMessage, returnedState, clientId, scope, port
end

describe("AI Planner ChatGPT integration contracts", function()
	it("prepares a fixed QA draft without sending, preserving existing text and busy state", function()
		local composer = { buf = "" }
		function composer:SetText(text) self.buf = text end
		local chat = setmetatable({ popup = { }, popupControls = { composer = composer }, auth = { }, pendingPrompt = "", messages = { } }, { __index = AIChat })
		local sent = false
		chat.SendMessage = function() sent = true end
		local result = assert(chat:PrepareQA())
		assert.is_true(result.prepared)
		assert.is_false(result.sent)
		assert.is_false(sent)
		assert.are.equal("Respond only QA-OK. Do not change the build.", composer.buf)
		assert.are.equal(composer.buf, chat.pendingPrompt)
		assert.is_nil(chat:PrepareQA())
		assert.are.equal(result.prompt, composer.buf)
		composer.buf, chat.pendingPrompt, chat.waitingForToken = "", "", true
		assert.is_nil(chat:PrepareQA())
		assert.are.equal("", composer.buf)
		chat.popup, chat.waitingForToken = nil, false
		assert.is_nil(chat:PrepareQA())
	end)
	it("injects the evidence-based five-part theorycraft audit policy", function()
		local policy = AIChat.AuditResponsePolicy
		assert.is_truthy(policy:find("Diagnóstico de Fraquezas", 1, true))
		assert.is_truthy(policy:find("Refatoração de Dano", 1, true))
		assert.is_truthy(policy:find("Refatoração de Defesa", 1, true))
		assert.is_truthy(policy:find("Árvore e Gemas", 1, true))
		assert.is_truthy(policy:find("Roteiro de Crafting", 1, true))
		assert.is_truthy(policy:find("opportunity cost", 1, true))
		assert.is_truthy(policy:find("mainSkillBreakdown.player.numericOutput and damageTypes", 1, true))
		assert.is_truthy(policy:find("formatted displayGroups/displayRows can be rounded", 1, true))
		assert.is_truthy(policy:find("0.165/0.132/0.099", 1, true))
		assert.is_truthy(policy:find("do not prove event generation", 1, true))
		assert.is_truthy(policy:find("generic formula", 1, true))
		assert.is_truthy(policy:find("complete legal replacement route", 1, true))
	end)

	it("requires Ask AI to distinguish exact Main Skill output from whole-build structure", function()
		local policy = AIChat.ReadinessCoveragePolicy
		assert.is_truthy(policy:find("componentCoverage.status is invalid", 1, true))
		assert.is_truthy(policy:find("secondary groups", 1, true))
		assert.is_truthy(policy:find("whole-build structural validation", 1, true))
	end)

	it("encodes OAuth state as base64url and decodes binary values", function()
		local raw = "\0Path of Building\255"
		local encoded = Auth.Base64UrlEncode(raw)
		assert.is_nil(encoded:find("=", 1, true))
		assert.is_nil(encoded:find("+", 1, true))
		assert.is_nil(encoded:find("/", 1, true))
		assert.are.equal(raw, Auth.Base64UrlDecode(encoded))
		assert.is_nil(Auth.Base64UrlDecode("invalid%token"))
	end)

	it("requires both direct model-use scopes", function()
		assert.is_true(Auth.HasScope("openid profile resource.invoke chatgpt.tokens.use.direct", "resource.invoke"))
		assert.is_true(Auth.HasScope({ "resource.invoke", "chatgpt.tokens.use.direct" }, "chatgpt.tokens.use.direct"))
		assert.is_false(Auth.HasScope("openid profile", "chatgpt.tokens.use.direct"))
	end)

	it("classifies terminal OAuth refresh errors without discarding the registered client identity", function()
		local auth = setmetatable({
			record = { credentials = {
				clientId = "oaiapp-existing",
				subject = "account-subject",
				idToken = "retained-id-token",
				accessToken = "expired-access",
				refreshToken = "rejected-refresh",
				expiresAt = 1,
			} },
		}, { __index = Auth })
		function auth:Save() return true end
		assert.is_true(Auth.TerminalRefreshErrors.invalid_grant)
		assert.is_true(auth:RequireReauthorization("Sign in again", true))
		assert.is_true(auth:NeedsReauthorization())
		assert.is_true(auth:IsConnected())
		assert.are.equal("oaiapp-existing", auth.record.credentials.clientId)
		assert.are.equal("account-subject", auth.record.credentials.subject)
		assert.are.equal("retained-id-token", auth.record.credentials.idToken)
		assert.is_nil(auth.record.credentials.accessToken)
		assert.is_nil(auth.record.credentials.refreshToken)
		assert.are.equal("Refresh token expired", Auth.ResponseError(
			'{"error":{"code":"invalid_grant","message":"Refresh token expired"}}'))
	end)

	it("clears only rejected refresh tokens and preserves the saved client for reauthorization", function()
		local originalLaunch = launch
		local auth = setmetatable({
			record = { credentials = {
				clientId = "oaiapp-existing", subject = "account-subject", idToken = "retained-id-token",
				accessToken = "expired-access", refreshToken = "rejected-refresh", expiresAt = 1,
			} },
		}, { __index = Auth })
		function auth:Save() return true end
		local token, tokenError
		launch = { DownloadPage = function(_, url, callback, params)
			assert.is_truthy(url:find("/oauth/token", 1, true))
			assert.is_truthy(params.body:find("grant_type=refresh_token", 1, true))
			callback({ body = '{"error":"invalid_grant"}' }, "Response code: 400")
		end }
		local ok, err = pcall(function()
			auth:GetAccessToken(function(value, message) token, tokenError = value, message end)
		end)
		launch = originalLaunch
		if not ok then error(err) end
		assert.is_nil(token)
		assert.is_truthy(tokenError:find("Sign in again with the same account", 1, true))
		assert.is_true(auth:NeedsReauthorization())
		assert.are.equal("oaiapp-existing", auth.record.credentials.clientId)
		assert.are.equal("retained-id-token", auth.record.credentials.idToken)
		assert.is_nil(auth.record.credentials.accessToken)
		assert.is_nil(auth.record.credentials.refreshToken)
	end)

	it("preserves tokens when a Responses authorization rejection needs account review", function()
		local auth = setmetatable({
			record = { credentials = {
				clientId = "oaiapp-existing", accessToken = "current-access", refreshToken = "current-refresh", expiresAt = 9999999999,
			} },
		}, { __index = Auth })
		function auth:Save() return true end
		assert.is_true(auth:RequireReauthorization("Check the selected account", false))
		assert.is_true(auth:NeedsReauthorization())
		assert.are.equal("current-access", auth.record.credentials.accessToken)
		assert.are.equal("current-refresh", auth.record.credentials.refreshToken)
	end)

	it("creates the protected credential directory hierarchy one level at a time", function()
		local root = "C:\\Users\\saulo\\AppData\\Local\\"
		local calls = { }
		local path, err = Auth.PrepareCredentialStorage(root, function(directory)
			calls[#calls + 1] = directory
			if #calls == 1 then return nil, "No error" end -- parent already exists
			return true
		end)
		assert.is_nil(err)
		assert.are.same({
			"C:\\Users\\saulo\\AppData\\Local\\Path of Building Community\\",
			"C:\\Users\\saulo\\AppData\\Local\\Path of Building Community\\AI Planner\\",
		}, calls)
		assert.are.equal(calls[2] .. "AIPlannerChat.dat", path)
	end)

	it("does not continue into credential storage when the parent cannot be created", function()
		local calls = 0
		local path, err = Auth.PrepareCredentialStorage("C:\\Users\\saulo\\AppData\\Local", function()
			calls = calls + 1
			return nil, "access denied"
		end)
		assert.is_nil(path)
		assert.is_truthy(err:find("access denied", 1, true))
		assert.are.equal(1, calls)
	end)

	it("builds the exact loopback callback and PKCE authorization parameters", function()
		local url, redirectUri = Auth.BuildAuthorizeUrl({ }, "dynamic_agent_client", "urn:uuid:host", "state", "nonce", "challenge", 43127)
		assert.are.equal("http://127.0.0.1:43127/auth/callback", redirectUri)
		assert.is_truthy(url:find("client_id=dynamic_agent_client", 1, true))
		assert.is_truthy(url:find("ext_agent_host_id=urn%3Auuid%3Ahost", 1, true))
		assert.is_truthy(url:find("code_challenge_method=S256", 1, true))
		assert.is_truthy(url:find("code_challenge=challenge", 1, true))
		assert.is_truthy(url:find("state=state", 1, true))
		assert.is_truthy(url:find("nonce=nonce", 1, true))
		assert.is_truthy(url:find("agent_name_hint=Path%20of%20Building%20Community%20Fork%20AI%20Planner", 1, true))
	end)

	it("parses normal and absolute browser callback request targets safely", function()
		local method, path, query = CallbackRequest.ParseRequestLine("GET /auth/callback?state=local-test&code=redacted HTTP/1.1\r", 43127)
		assert.are.equal("GET", method)
		assert.are.equal("/auth/callback", path)
		assert.are.equal("state=local-test&code=redacted", query)

		local absoluteMethod, absolutePath, absoluteQuery = CallbackRequest.ParseRequestLine("GET http://127.0.0.1:43127/auth/callback?state=x HTTP/1.1", 43127)
		assert.are.equal("GET", absoluteMethod)
		assert.are.equal("/auth/callback", absolutePath)
		assert.are.equal("state=x", absoluteQuery)

		local invalid, reason = CallbackRequest.ParseRequestLine("GET http://127.0.0.1:43128/auth/callback?state=x HTTP/1.1", 43127)
		assert.is_nil(invalid)
		assert.are.equal("authority_mismatch", reason)
		local otherMethod, otherPath = CallbackRequest.ParseRequestLine("POST /auth/callback?state=x HTTP/1.1", 43127)
		assert.are.equal("POST", otherMethod)
		assert.are.equal("/auth/callback", otherPath)
	end)

	it("accepts the browser callback line with CRLF, validates OAuth state, and decodes scope", function()
		-- LuaSocket line reads can leave the CR from an HTTP CRLF terminator.
		local callback, reason = CallbackRequest.ParseCallback(
			"GET /auth/callback?code=synthetic-code&state=expected&scope=chatgpt.tokens.use.direct+resource.invoke HTTP/1.1\r",
			43127, "expected")
		assert.is_nil(reason)
		assert.are.equal("synthetic-code", callback.code)
		assert.are.equal("expected", callback.state)
		assert.are.equal("chatgpt.tokens.use.direct resource.invoke", callback.scope)

		local mismatch, mismatchReason = CallbackRequest.ParseCallback(
			"GET /auth/callback?code=synthetic-code&state=other HTTP/1.1", 43127, "expected")
		assert.is_nil(mismatch)
		assert.are.equal("state_mismatch", mismatchReason)
		local malformed, malformedReason = CallbackRequest.ParseCallback(
			"GET /auth/callback?code=%ZZ&state=expected HTTP/1.1", 43127, "expected")
		assert.is_nil(malformed)
		assert.are.equal("invalid_or_duplicate_query_parameter", malformedReason)
	end)

	it("routes the synthetic browser callback through the loopback server and returns its code", function()
		local captured, code, callbackError, state, clientId, scope, port = runCallbackServer({ {
			line = "GET /auth/callback?code=synthetic-code&state=expected&client_id=oaiapp-issued&scope=chatgpt.tokens.use.direct+resource.invoke HTTP/1.1\r",
		} }, "expected")
		assert.are.equal("127.0.0.1", captured.host)
		assert.are.equal(0, captured.requestedPort)
		assert.are.equal(1, captured.backlog)
		assert.is_truthy(captured.openUrl:find("127.0.0.1:43127/auth/callback", 1, true))
		assert.are.equal("synthetic-code", code)
		assert.is_nil(callbackError)
		assert.are.equal("expected", state)
		assert.are.equal("oaiapp-issued", clientId)
		assert.are.equal("chatgpt.tokens.use.direct resource.invoke", scope)
		assert.are.equal(43127, port)
		assert.is_true(captured.closed)
		assert.are.equal(1, #captured.pages)
		assert.is_truthy(captured.pages[1]:find("HTTP/1.1 200 OK", 1, true))
		assert.is_truthy(captured.pages[1]:find("ChatGPT sign-in received", 1, true))
	end)

	it("keeps listening after an unrelated local route without logging query secrets", function()
		local captured, code, callbackError = runCallbackServer({
			{ line = "GET /?code=one-time-secret&state=private-state HTTP/1.1\r" },
			{ line = "GET /auth/callback?code=synthetic-code&state=expected HTTP/1.1\r" },
		}, "expected")
		assert.are.equal("synthetic-code", code)
		assert.is_nil(callbackError)
		assert.are.equal(2, #captured.pages)
		assert.is_truthy(captured.pages[1]:find("HTTP/1.1 404 Not Found", 1, true))
		assert.is_truthy(captured.pages[1]:find("Sign-in callback not recognized", 1, true))
		assert.is_truthy(captured.pages[2]:find("HTTP/1.1 200 OK", 1, true))
		assert.are.equal(1, #captured.logs)
		assert.is_truthy(captured.logs[1]:find("GET other-path", 1, true))
		assert.is_nil(captured.logs[1]:find("one-time-secret", 1, true))
		assert.is_nil(captured.logs[1]:find("private-state", 1, true))
	end)

	it("explains a mismatched callback state without ending a valid sign-in attempt", function()
		local captured, code, callbackError, state = runCallbackServer({
			{ line = "GET /auth/callback?code=stale-code-secret&state=stale-state-secret HTTP/1.1\r" },
			{ line = "GET /auth/callback?code=synthetic-code&state=expected HTTP/1.1\r" },
		}, "expected")

		assert.are.equal("synthetic-code", code)
		assert.is_nil(callbackError)
		assert.are.equal("expected", state)
		assert.are.equal(2, #captured.pages)
		assert.is_truthy(captured.pages[1]:find("HTTP/1.1 400 Bad Request", 1, true))
		assert.is_truthy(captured.pages[1]:find("did not match this sign-in", 1, true))
		assert.is_truthy(captured.pages[1]:find("different or expired sign-in", 1, true))
		assert.is_nil(captured.pages[1]:find("stale-code-secret", 1, true))
		assert.is_nil(captured.pages[1]:find("stale-state-secret", 1, true))
		assert.is_truthy(captured.pages[2]:find("HTTP/1.1 200 OK", 1, true))
		assert.is_truthy(captured.logs[1]:find("mismatched OAuth state", 1, true))
		assert.is_nil(captured.logs[1]:find("stale-code-secret", 1, true))
		assert.is_nil(captured.logs[1]:find("stale-state-secret", 1, true))
	end)

	it("returns provider denial through the callback result without exposing it in the web response", function()
		local captured, code, callbackError, state = runCallbackServer({ {
			line = "GET /auth/callback?error=access_denied&error_description=synthetic-denial&state=expected HTTP/1.1\r",
		} }, "expected")
		assert.is_nil(code)
		assert.are.equal("synthetic-denial", callbackError)
		assert.are.equal("expected", state)
		assert.is_truthy(captured.pages[1]:find("HTTP/1.1 200 OK", 1, true))
		assert.is_truthy(captured.pages[1]:find("sign-in was not completed", 1, true))
		assert.is_nil(captured.pages[1]:find("synthetic-denial", 1, true))
	end)

	it("describes callback routing failures without logging OAuth values or arbitrary paths", function()
		local summary = CallbackRequest.DescribeRequestSafely(
			"GET /wrong/path?code=one-time-secret&state=private-state HTTP/1.1", 43127)
		assert.are.equal("GET other-path", summary)
		assert.is_nil(summary:find("one-time-secret", 1, true))
		assert.is_nil(summary:find("private-state", 1, true))

		local methodSummary = CallbackRequest.DescribeRequestSafely(
			"POST /auth/callback?code=one-time-secret&state=private-state HTTP/1.1", 43127)
		assert.are.equal("POST /auth/callback", methodSummary)
		assert.is_nil(methodSummary:find("one-time-secret", 1, true))

		local malformedSummary = CallbackRequest.DescribeRequestSafely(
			"GET http://127.0.0.1:43128/auth/callback?code=one-time-secret HTTP/1.1", 43127)
		assert.are.equal("invalid request (authority_mismatch)", malformedSummary)
		assert.is_nil(malformedSummary:find("43128", 1, true))
	end)

	it("uses the retained identity hints for a previously registered client", function()
		local url = Auth.BuildAuthorizeUrl({ }, "oaiapp_issued", "urn:uuid:host", "state", "nonce", "challenge", 43127, {
			idToken = "retained.jwt.token",
			email = "player@example.com",
		})
		assert.is_truthy(url:find("client_id=oaiapp_issued", 1, true))
		assert.is_truthy(url:find("id_token_hint=retained.jwt.token", 1, true))
		assert.is_truthy(url:find("login_hint=player%40example.com", 1, true))
		assert.is_nil(url:find("agent_name_hint", 1, true))
	end)

	it("serializes a namespaced, typed tool catalog with strict argument objects", function()
		local encoded, encodeError = dkjson.encode(AIChat.ToolDefinitions)
		assert.is_truthy(encoded, encodeError)
		local decoded = assert(dkjson.decode(encoded))
		assert.are.equal(1, #decoded)
		assert.are.equal("namespace", decoded[1].type)
		assert.are.equal("pob", decoded[1].name)
		local names = { }
		for _, entry in ipairs(decoded[1].tools) do
			names[entry.name] = entry
			assert.are.equal("object", entry.parameters.type)
			assert.is_false(entry.parameters.additionalProperties)
		end
		assert.is_truthy(names.apply_passive_delta)
		assert.is_truthy(names.list_study_records.description:find("learningCoverage", 1, true))
		assert.is_truthy(names.list_study_records.description:find("does not measure all skill/support combinations", 1, true))
		assert.is_truthy(names.list_study_records.description:find("graph stays report-only", 1, true))
		local optimizerStart = names.optimizer_start
		assert.is_truthy(optimizerStart)
		local optimizerStatus = names.optimizer_status
		assert.is_truthy(optimizerStatus.description:find("support-package counts by arity", 1, true),
			"Ask AI must explain the exact support-package coverage returned by the local MCP bridge")
		local matrixSchema = optimizerStart.parameters.properties.matrix
		assert.are.equal("string", optimizerStart.parameters.properties.studyId.type)
		assert.are.equal(96, optimizerStart.parameters.properties.studyId.maxLength)
		assert.is_truthy(optimizerStart.description:find("read-only job", 1, true))
		assert.is_truthy(optimizerStart.description:find("stores only sanitized exact outcomes in local path-learning memory", 1, true))
		assert.is_truthy(optimizerStart.description:find("read-only job that optimizer_apply cannot apply", 1, true))
		assert.is_false(matrixSchema.additionalProperties)
		for _, key in ipairs({ "FireResistOverCap", "ColdResistOverCap", "LightningResistOverCap", "ChaosResistOverCap" }) do
			local field = matrixSchema.properties[key]
			assert.is_truthy(field, key .. " must be exposed to Ask AI")
			assert.is_truthy(field.description:find("percentage points above the matching resistance maximum", 1, true), key .. " must define the strict overcap unit")
		end
		assert.is_nil(matrixSchema.properties.unrecognizedMatrixField)
		assert.are.equal("boolean", matrixSchema.properties.searchAllClasses.type)
		assert.is_truthy(matrixSchema.properties.searchAllClasses.description:find("equal exact-PoB evaluation budgets", 1, true))
		assert.is_truthy(matrixSchema.properties.ascendancyId)
		assert.is_truthy(matrixSchema.properties.ascendancyId.description:find("Locks tree search", 1, true))
		assert.are.equal("boolean", matrixSchema.properties.searchStoredItems.type)
		assert.is_truthy(matrixSchema.properties.searchStoredItems.description:find("already stored in the active PoB Items tab", 1, true))
		assert.are.same({ "Active", "None", "Boss", "Pinnacle", "Uber" }, matrixSchema.properties.scenarioEnemyPreset.enum)
		assert.is_truthy(matrixSchema.properties.scenarioEnemyPreset.description:find("Native PoB enemyIsBoss preset", 1, true))
		assert.is_truthy(matrixSchema.properties.scenarioEnemyLevel)
		assert.is_truthy(matrixSchema.properties.scenarioEnemyLevel.description:find("does not recreate area-specific monster", 1, true))
		assert.are.equal("integer", matrixSchema.properties.scenarioEnemyLevel.anyOf[1].type)
		assert.are.equal(85, matrixSchema.properties.scenarioEnemyLevel.anyOf[1].maximum)
		assert.is_truthy(matrixSchema.properties.currencyBudgetAmount)
		assert.are.same({ "Chaos", "Divine" }, matrixSchema.properties.currencyBudgetUnit.enum)
		assert.are.same({ "Trade", "SSF" }, matrixSchema.properties.currencyBudgetMode.enum)
		assert.are.equal(300, matrixSchema.properties.manualItemPrices.maxProperties)
		assert.are.equal("string", matrixSchema.properties.targetSkillGemId.type)
		assert.are.equal(100, matrixSchema.properties.targetSkillGemId.maxLength)
		assert.is_truthy(matrixSchema.properties.targetSkillGemId.description:find("loaded active-skill gem database", 1, true))
		local gemCatalog = names.list_optimizer_skill_gems
		assert.is_truthy(gemCatalog)
		assert.are.same({ "query" }, gemCatalog.parameters.required)
		assert.are.equal(2, gemCatalog.parameters.properties.query.minLength)
		assert.are.equal(100, gemCatalog.parameters.properties.limit.maximum)
		assert.is_truthy(gemCatalog.parameters.properties.groupIndex)
		assert.is_truthy(gemCatalog.parameters.properties.skillIndex)
		local skillSeed = names.create_optimizer_skill_seed
		assert.is_truthy(skillSeed, "Ask AI must be able to start a build from a loaded PoB gem")
		assert.are.same({ "gemId" }, skillSeed.parameters.required)
		assert.are.equal(100, skillSeed.parameters.properties.gemId.maxLength)
		assert.are.equal(0, skillSeed.parameters.properties.baseClassId.minimum)
		assert.are.equal(6, skillSeed.parameters.properties.baseClassId.maximum)
		assert.is_truthy(skillSeed.description:find("equipped item's next unused socket", 1, true))
		assert.is_truthy(skillSeed.description:find("otherwise it remains unlinked", 1, true))
		assert.is_nil(names.market_prices, "the in-app Ask AI tool set must not claim direct live market access")
		assert.is_truthy(names.connection_health)
		assert.is_truthy(names.progression_options)
		assert.is_truthy(names.progression_start)
		assert.is_truthy(names.progression_compare)
		local baseClassSchema = names.progression_start.parameters.properties.baseClassId
		assert.are.equal("integer", baseClassSchema.type)
		assert.are.equal(1, baseClassSchema.minimum)
		assert.are.equal(2147483647, baseClassSchema.maximum)
		assert.is_truthy(baseClassSchema.description:find("native tree root", 1, true))
		assert.are.equal(4, names.progression_start.parameters.properties.stages.minItems)
		assert.are.equal(4, names.progression_start.parameters.properties.stages.maxItems)
		assert.is_false(names.progression_start.parameters.properties.stages.items.additionalProperties)
		local compareSchema = names.progression_compare.parameters.properties
		assert.are.equal(2, compareSchema.plans.minItems)
		assert.are.equal(4, compareSchema.plans.maxItems)
		assert.is_false(compareSchema.plans.items.additionalProperties)
		assert.are.same({ "CombinedDPS", "FullDPS", "FullDotDPS", "TotalEHP", "Speed" }, compareSchema.objective.enum)
		assert.are.equal(4, compareSchema.plans.items.properties.stages.maxItems)
		local stageSchema = names.progression_start.parameters.properties.stages.items.properties
		assert.are.equal("array", stageSchema.addNodeIds.type)
		assert.are.equal(64, stageSchema.addNodeIds.maxItems)
		assert.are.equal("string", stageSchema.gemVariants.items.properties.gemId.type)
		assert.are.equal(32, stageSchema.hardConstraints.maxItems)
		assert.is_truthy(stageSchema.conversion)
		assert.are.equal(1000, stageSchema.requiredTriggerRate.maximum)
		assert.is_truthy(names.progression_status)
		assert.is_truthy(names.progression_cancel)
		assert.is_truthy(names.qa_start)
		assert.are.same({ "integration", "planner", "build", "optimizer_smoke" }, names.qa_start.parameters.properties.suite.enum)
		assert.is_truthy(names.get_build_snapshot.description:find("loaded gem tags", 1, true))
		assert.is_truthy(names.get_build_snapshot.description:find("native active-effect skill types", 1, true))
		assert.is_truthy(names.get_build_snapshot.description:find("distinct for variants such as Vaal gems", 1, true))
		assert.is_truthy(names.get_build_snapshot.description:find("CalcOffence conversion", 1, true))
		assert.is_truthy(names.get_build_snapshot.description:find("allowlisted native CalcOffence breakdown", 1, true))
		assert.is_truthy(names.get_build_snapshot.description:find("may be rounded", 1, true))
		assert.is_truthy(names.evaluate_passive_delta.description:find("per-type Main Skill damage outputs", 1, true))
		assert.is_truthy(names.evaluate_passive_delta.description:find("not reconstructed damage formulas", 1, true))
		assert.is_truthy(names.qa_status)
		assert.is_truthy(names.qa_cancel)
		assert.is_truthy(names.apply_gem_variant)
		assert.is_truthy(names.import_build_url)
		assert.is_truthy(names.import_build_status)
		assert.is_truthy(names.get_study_build_snapshot)
		assert.is_truthy(names.list_comparison_builds)
		assert.is_truthy(names.get_comparison_build_snapshot)
		assert.are.same({ "comparisonId" }, names.get_comparison_build_snapshot.parameters.required)
		assert.is_truthy(names.analyze_comparison_skill)
		assert.are.same({ "groupIndex", "skillIndex" }, names.analyze_comparison_skill.parameters.required)
		assert.is_truthy(names.analyze_comparison_skill.parameters.properties.studyId)
		assert.is_truthy(names.analyze_comparison_skill.parameters.properties.comparisonId)
		assert.is_truthy(names.skill_catalog_coverage)
		assert.are.same({ }, names.skill_catalog_coverage.parameters.required)
		assert.is_truthy(names.get_synergy_graph)
		assert.are.same({ }, names.get_synergy_graph.parameters.required)
		assert.are.equal(1, names.get_synergy_graph.parameters.properties.limit.minimum)
		assert.are.equal(25, names.get_synergy_graph.parameters.properties.limit.maximum)
		assert.is_truthy(names.get_synergy_graph.description:find("report-only", 1, true))
		assert.is_truthy(names.get_synergy_graph.description:find("do not prove causation", 1, true))
		assert.is_truthy(names.search_local_knowledge)
		assert.are.same({ "query", "knowledgeScope" }, names.search_local_knowledge.parameters.required)
		assert.are.same({ "pob_architecture", "build_readiness" }, names.search_local_knowledge.parameters.properties.knowledgeScope.enum)
		assert.is_truthy(names.search_local_knowledge.description:find("does not calculate build mechanics", 1, true))
		assert.is_truthy(names.export_skill_catalog_coverage)
		assert.are.same({ }, names.export_skill_catalog_coverage.parameters.required)
		assert.is_truthy(names.export_skill_catalog_coverage.description:find("does not calculate skill/support combinations", 1, true))
		assert.is_truthy(names.list_study_records)
		assert.is_truthy(names.export_study_dataset)
		assert.are.same({ }, names.export_study_dataset.parameters.required)
		assert.is_truthy(names.export_study_dataset.description:find("blocked readiness creates no export", 1, true))
		assert.is_truthy(names.get_study_record)
		assert.are.same({ "recordId", "confirm" }, names.delete_study_record.parameters.required)
		assert.are.equal("boolean", names.delete_study_record.parameters.properties.confirm.type)
		assert.is_truthy(names.delete_study_record.description:find("user explicitly requests", 1, true))
		assert.are.same({ "olderThanDays", "confirm" }, names.prune_study_records.parameters.required)
		assert.are.equal(1, names.prune_study_records.parameters.properties.olderThanDays.minimum)
		assert.are.equal(3650, names.prune_study_records.parameters.properties.olderThanDays.maximum)
		assert.is_truthy(names.prune_study_records.description:find("Missing or malformed timestamps are preserved", 1, true))
		assert.is_truthy(names.remove_study_build)
		assert.is_truthy(names.evaluate_passive_delta)
		assert.is_truthy(names.evaluate_passive_delta.parameters.properties.comparisonId)
		assert.is_truthy(names.evaluate_activity_schedule)
		assert.is_truthy(names.evaluate_activity_schedule.parameters.properties.comparisonId)
		assert.are.same({ "activities" }, names.evaluate_activity_schedule.parameters.required)
		assert.are.equal(64, names.evaluate_activity_schedule.parameters.properties.activities.maxItems)
		assert.are.equal(8, names.evaluate_activity_schedule.parameters.properties.activities.items.properties.requires.maxItems)
		assert.are.equal(256, names.evaluate_activity_schedule.parameters.properties.activities.items.properties.requires.items.maxLength)
		assert.are.same({ "main_skill", "full_dps", "all_enabled_skills" }, names.evaluate_activity_schedule.parameters.properties.scope.enum)
		assert.is_truthy(names.evaluate_activity_schedule.description:find("resource-only", 1, true))
		assert.is_truthy(names.record_passive_experiment)
		assert.is_truthy(names.record_passive_experiment.parameters.properties.comparisonId)
		assert.are.equal(1, names.record_passive_experiment.parameters.properties.addNodeIds.maxItems)
		assert.is_truthy(names.record_passive_factorial_experiment)
		assert.are.same({ "factorANodeId", "factorBNodeId" }, names.record_passive_factorial_experiment.parameters.required)
		assert.is_truthy(names.record_passive_factorial_experiment.description:find("four-cell", 1, true))
		assert.is_truthy(names.record_passive_factorial_experiment.description:find("A+B - A - B + baseline", 1, true))
		assert.is_truthy(names.record_passive_factorial_status)
		assert.are.same({ "jobId" }, names.record_passive_factorial_status.parameters.required)
		assert.is_truthy(names.record_passive_factorial_cancel)
		assert.are.same({ "jobId" }, names.record_passive_factorial_cancel.parameters.required)
		assert.is_truthy(names.record_passive_item_slot_factorial_experiment)
		assert.are.same({ "nodeId", "slot", "itemId" }, names.record_passive_item_slot_factorial_experiment.parameters.required)
		assert.is_truthy(names.record_passive_item_slot_factorial_experiment.description:find("four-cell", 1, true))
		assert.is_truthy(names.record_passive_item_slot_factorial_status)
		assert.are.same({ "jobId" }, names.record_passive_item_slot_factorial_status.parameters.required)
		assert.is_truthy(names.record_passive_item_slot_factorial_cancel)
		assert.are.same({ "jobId" }, names.record_passive_item_slot_factorial_cancel.parameters.required)
		assert.is_truthy(names.list_active_skills)
		assert.is_truthy(names.list_active_skills.parameters.properties.studyId)
		assert.is_truthy(names.list_active_skills.parameters.properties.comparisonId)
		assert.are.same({ }, names.list_active_skills.parameters.required)
		assert.is_truthy(names.record_skill_support_factorial_experiment)
		assert.are.same({ "groupIndex", "skillGemIndex", "skillGemId", "skillEffectId", "supportGemIndex", "supportGemId" }, names.record_skill_support_factorial_experiment.parameters.required)
		assert.is_truthy(names.record_skill_support_factorial_experiment.parameters.properties.comparisonId)
		assert.is_truthy(names.record_skill_support_factorial_experiment.description:find("four-cell", 1, true))
		assert.is_truthy(names.record_skill_support_factorial_status)
		assert.are.same({ "jobId" }, names.record_skill_support_factorial_status.parameters.required)
		assert.is_truthy(names.record_skill_support_factorial_cancel)
		assert.are.same({ "jobId" }, names.record_skill_support_factorial_cancel.parameters.required)
		assert.is_truthy(names.record_skill_skill_factorial_experiment)
		assert.are.same({ "groupAIndex", "skillGemAIndex", "skillGemAId", "skillEffectAId", "groupBIndex", "skillGemBIndex", "skillGemBId", "skillEffectBId" }, names.record_skill_skill_factorial_experiment.parameters.required)
		assert.is_truthy(names.record_skill_skill_factorial_experiment.description:find("Full DPS", 1, true))
		assert.is_truthy(names.record_skill_skill_factorial_status)
		assert.are.same({ "jobId" }, names.record_skill_skill_factorial_status.parameters.required)
		assert.is_truthy(names.record_skill_skill_factorial_cancel)
		assert.are.same({ "jobId" }, names.record_skill_skill_factorial_cancel.parameters.required)
		assert.is_truthy(names.record_passive_support_factorial_experiment)
		assert.are.same({ "groupIndex", "skillGemIndex", "supportGemIndex", "supportGemId", "nodeId" }, names.record_passive_support_factorial_experiment.parameters.required)
		assert.are.equal(2147483647, names.record_passive_support_factorial_experiment.parameters.properties.nodeId.maximum)
		assert.is_truthy(names.record_passive_support_factorial_experiment.description:find("four-cell", 1, true))
		assert.is_truthy(names.record_passive_support_factorial_experiment.description:find("path repair", 1, true))
		assert.is_truthy(names.record_passive_support_factorial_status)
		assert.are.same({ "jobId" }, names.record_passive_support_factorial_status.parameters.required)
		assert.is_truthy(names.record_passive_support_factorial_cancel)
		assert.are.same({ "jobId" }, names.record_passive_support_factorial_cancel.parameters.required)
		assert.is_truthy(names.record_gem_experiment)
		assert.is_truthy(names.record_gem_experiment.parameters.properties.comparisonId)
		assert.are.equal("groupIndex", names.record_gem_experiment.parameters.required[1])
		assert.are.equal("gemIndex", names.record_gem_experiment.parameters.required[2])
		assert.are.equal(23, names.record_gem_experiment.parameters.properties.quality.maximum)
		assert.is_truthy(names.record_mastery_experiment)
		assert.are.same({ "masteryNodeId", "effectId" }, names.record_mastery_experiment.parameters.required)
		assert.are.equal(1, names.record_mastery_experiment.parameters.properties.masteryNodeId.minimum)
		assert.are.equal(1, names.record_mastery_experiment.parameters.properties.effectId.minimum)
		assert.is_truthy(names.evaluate_gem_swap)
		assert.is_truthy(names.evaluate_gem_swap.parameters.properties.comparisonId)
		assert.is_truthy(names.evaluate_item_swap.parameters.properties.comparisonId)
		assert.is_truthy(names.record_item_experiment)
		assert.is_truthy(names.record_item_experiment.parameters.properties.comparisonId)
		assert.are.same({ "slot", "itemId" }, names.record_item_experiment.parameters.required)
		assert.are.equal(0, names.record_item_experiment.parameters.properties.itemId.minimum)
		assert.is_nil(names.execute_lua)
		assert.is_nil(names.run_shell)
	end)

	it("keeps the Responses stream worker syntactically valid", function()
		assert.is_truthy(loadstring(AIChat.StreamScript))
	end)

	it("shows completed Responses text and refusals in the transcript", function()
		local chat = setmetatable({
			currentTurn = { input = { { role = "user", content = "QA" } } },
			messages = { }, draft = "",
		}, { __index = AIChat })
		chat:HandleCompletedResponse('{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"QA-OK"}]}]}')
		assert.are.equal("assistant", chat.messages[1].role)
		assert.are.equal("QA-OK", chat.messages[1].text)
		assert.is_truthy(chat.statusMessage:find("response complete", 1, true))
		assert.is_nil(chat.currentTurn)

		local refusal = setmetatable({
			currentTurn = { input = { { role = "user", content = "QA" } } },
			messages = { }, draft = "",
		}, { __index = AIChat })
		refusal:HandleCompletedResponse('{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"Request declined"}]}]}')
		assert.are.equal("assistant", refusal.messages[1].role)
		assert.are.equal("Request declined", refusal.messages[1].text)
	end)

	it("fails visibly when a completed Responses event contains no displayable reply", function()
		local chat = setmetatable({
			currentTurn = { input = { { role = "user", content = "QA" } } },
			messages = { }, draft = "",
		}, { __index = AIChat })
		chat:HandleCompletedResponse('{"status":"completed","output":[{"type":"reasoning"}]}')
		assert.are.equal("tool", chat.messages[1].role)
		assert.is_truthy(chat.messages[1].text:find("completed without a visible reply", 1, true))
		assert.is_truthy(chat.messages[1].text:find("reasoning", 1, true))
		assert.is_nil(chat.messages[1].text:find("response complete", 1, true))
		assert.is_nil(chat.currentTurn)

		local topLevel = setmetatable({
			currentTurn = { input = { { role = "user", content = "QA" } } },
			messages = { }, draft = "",
		}, { __index = AIChat })
		topLevel:HandleCompletedResponse('{"status":"completed","output":[],"output_text":"QA-OK"}')
		assert.are.equal("assistant", topLevel.messages[1].role)
		assert.are.equal("QA-OK", topLevel.messages[1].text)
	end)

	it("includes response metadata when a completed Responses event has empty output", function()
		local chat = setmetatable({
			currentTurn = { input = { { role = "user", content = "QA" } } },
			messages = { }, draft = "", model = { slug = "gpt-test", displayName = "QA model" },
		}, { __index = AIChat })
		chat:HandleCompletedResponse('{"id":"resp_empty_test","model":"gpt-test","pob_request_id":"req_empty_test","usage":{"input_tokens":12,"output_tokens":0},"status":"completed","output":[]}')
		local diagnostic = chat.messages[1].text
		assert.is_truthy(diagnostic:find("output: empty output", 1, true))
		assert.is_truthy(diagnostic:find("Model: gpt-test", 1, true))
		assert.is_truthy(diagnostic:find("Response ID: resp_empty_test", 1, true))
		assert.is_truthy(diagnostic:find("Request ID: req_empty_test", 1, true))
		assert.is_truthy(diagnostic:find("Tokens: input 12, output 0", 1, true))
	end)

	it("maps each exposed local operation to the fixed PoB allowlist", function()
		local methods = AIChat.ToolMethods
		assert.are.equal("connection_health", methods.pob_connection_health)
		assert.are.equal("progression_options", methods.pob_progression_options)
		assert.are.equal("progression_start", methods.pob_progression_start)
		assert.are.equal("progression_compare", methods.pob_progression_compare)
		assert.are.equal("progression_status", methods.pob_progression_status)
		assert.are.equal("progression_cancel", methods.pob_progression_cancel)
		assert.are.equal("qa_start", methods.pob_qa_start)
		assert.are.equal("qa_status", methods.pob_qa_status)
		assert.are.equal("qa_cancel", methods.pob_qa_cancel)
		assert.are.equal("apply_passive_delta", methods.pob_apply_passive_delta)
		assert.are.equal("apply_gem_variant", methods.pob_apply_gem_variant)
		assert.are.equal("get_build_snapshot", methods.pob_get_build_snapshot)
		assert.are.equal("import_build_url", methods.pob_import_build_url)
		assert.are.equal("import_build_status", methods.pob_import_build_status)
		assert.are.equal("get_study_build_snapshot", methods.pob_get_study_build_snapshot)
		assert.are.equal("get_synergy_graph", methods.pob_get_synergy_graph)
		assert.are.equal("list_study_records", methods.pob_list_study_records)
		assert.are.equal("export_study_dataset", methods.pob_export_study_dataset)
		assert.are.equal("get_study_record", methods.pob_get_study_record)
		assert.are.equal("delete_study_record", methods.pob_delete_study_record)
		assert.are.equal("prune_study_records", methods.pob_prune_study_records)
		assert.are.equal("remove_study_build", methods.pob_remove_study_build)
		assert.are.equal("record_passive_experiment", methods.pob_record_passive_experiment)
		assert.are.equal("record_passive_factorial_experiment", methods.pob_record_passive_factorial_experiment)
		assert.are.equal("record_passive_factorial_status", methods.pob_record_passive_factorial_status)
		assert.are.equal("record_passive_factorial_cancel", methods.pob_record_passive_factorial_cancel)
		assert.are.equal("record_passive_item_slot_factorial_experiment", methods.pob_record_passive_item_slot_factorial_experiment)
		assert.are.equal("record_passive_item_slot_factorial_status", methods.pob_record_passive_item_slot_factorial_status)
		assert.are.equal("record_passive_item_slot_factorial_cancel", methods.pob_record_passive_item_slot_factorial_cancel)
		assert.are.equal("record_skill_support_factorial_experiment", methods.pob_record_skill_support_factorial_experiment)
		assert.are.equal("record_skill_support_factorial_status", methods.pob_record_skill_support_factorial_status)
		assert.are.equal("record_skill_support_factorial_cancel", methods.pob_record_skill_support_factorial_cancel)
		assert.are.equal("record_skill_skill_factorial_experiment", methods.pob_record_skill_skill_factorial_experiment)
		assert.are.equal("record_skill_skill_factorial_status", methods.pob_record_skill_skill_factorial_status)
		assert.are.equal("record_skill_skill_factorial_cancel", methods.pob_record_skill_skill_factorial_cancel)
		assert.are.equal("record_passive_support_factorial_experiment", methods.pob_record_passive_support_factorial_experiment)
		assert.are.equal("record_passive_support_factorial_status", methods.pob_record_passive_support_factorial_status)
		assert.are.equal("record_passive_support_factorial_cancel", methods.pob_record_passive_support_factorial_cancel)
		assert.are.equal("record_gem_experiment", methods.pob_record_gem_experiment)
		assert.are.equal("record_mastery_experiment", methods.pob_record_mastery_experiment)
		assert.are.equal("record_item_experiment", methods.pob_record_item_experiment)
		assert.are.equal("evaluate_activity_schedule", methods.pob_evaluate_activity_schedule)
		assert.is_nil(methods.pob_execute_lua)
		assert.is_nil(methods.pob_read_file)
	end)

	it("routes Ask AI synergy reads through the typed local PoB bridge", function()
		local originalMain = main
		local capturedMethod, capturedArguments
		main = { optimizerMCP = { CallLocal = function(_, method, arguments)
			capturedMethod, capturedArguments = method, arguments
			return { status = "report_only", edges = { }, activeBuildPreserved = true }
		end } }
		local chat = setmetatable({ }, { __index = AIChat })
		local callOk, result, callError = pcall(chat.DispatchTool, chat, "pob_get_synergy_graph", { limit = 7 })
		main = originalMain
		assert.is_true(callOk, callError)
		assert.are.equal("get_synergy_graph", capturedMethod)
		assert.are.equal(7, capturedArguments.limit)
		assert.are.equal("report_only", result.status)
		assert.is_true(result.activeBuildPreserved)
	end)

	it("fails closed when a selected study or comparison is not confirmed by PoB", function()
		local originalMain = main
		local confirmation = nil
		main = { optimizerMCP = { CallLocal = function() return confirmation or { isActiveBuild = true } end } }
		local chat = setmetatable({ }, { __index = AIChat })
		local result, err = chat:DispatchTool("pob_get_passive_node", { nodeId = 123, comparisonId = "pob-comparison-fixture" })
		main = originalMain
		assert.is_nil(result)
		assert.is_truthy(err and err:find("did not confirm the requested build reference", 1, true))

		main = { optimizerMCP = { CallLocal = function() return {
			isActiveBuild = false,
			buildReference = { type = "native_comparison_build", comparisonId = "pob-comparison-fixture" },
		} end } }
		local confirmed = chat:DispatchTool("pob_get_passive_node", { nodeId = 123, comparisonId = "pob-comparison-fixture" })
		main = originalMain
		assert.is_truthy(confirmed)
	end)

	it("shows the latest multiline diagnostic including the final warnings", function()
		local originalMain = main
		main = { unicode = false, WrapString = function(_, text) return { text } end }
		local lines = { }
		for index = 1, 40 do lines[index] = "check " .. index end
		lines[40] = "final sustain warning"
		local chat = setmetatable({ messages = { { role = "tool", text = table.concat(lines, "\n") } }, draft = "" }, { __index = AIChat })
		local text = chat:RenderTranscript(800, 240)
		main = originalMain
		assert.is_truthy(text:find("final sustain warning", 1, true))
		assert.is_nil(text:find("check 1\n", 1, true))
	end)

	it("keeps the Ask AI controls separated at the narrowest supported popup size", function()
		local function overlaps(a, b)
			return a.x < b.x + b.width and b.x < a.x + a.width
				and a.y < b.y + b.height and b.y < a.y + a.height
		end
		for _, size in ipairs({ { 650, 520 }, { 870, 610 } }) do
			local width, height = size[1], size[2]
			local layout = AIChat.PopupLayout(width, height)
			local send = { x = width - 120, y = layout.actionY, width = 100, height = 22 }
			local queue = { x = 184, y = layout.actionY, width = 126, height = 22 }
			local modelLabel = layout.modelLabel
			local model = layout.model
			local refresh = layout.refreshModels
			assert.is_false(overlaps(layout.close, layout.status))
			assert.is_false(overlaps(layout.close, layout.model))
			assert.is_false(overlaps(queue, send))
			assert.is_false(overlaps(layout.transcript, layout.composer))
			assert.is_false(overlaps(layout.composer, send))
			assert.is_false(overlaps(modelLabel, model))
			assert.is_false(overlaps(model, refresh))
			assert.are.equal(height - 140, layout.composer.y)
			assert.are.equal(height - 56, layout.actionY)
		end
	end)

	it("measures and clips long status text before the Close button at the actual draw font size", function()
		local nativeMain, nativeWidth, nativeDraw, nativeViewport = main, DrawStringWidth, DrawString, SetViewport
		local sizes, drawn, viewport = { }, nil, nil
		main = { screenW = 1026, screenH = 607, unicode = false,
			WrapString = nativeMain.WrapString,
			OpenPopup = function(_, width, height, _, controls) return { width = width, height = height, controls = controls } end }
		DrawStringWidth = function(size, _, text) return #text:gsub("%^%d", "") * size / 2 end
		DrawString = function(_, _, _, size, _, text) sizes[#sizes + 1] = size drawn = text end
		SetViewport = function(x, y, width, height) if width then viewport = { width = width, height = height } end end
		local chat = setmetatable({ auth = { IsConnected = function() return true end }, models = { }, messages = { },
			statusMessage = string.rep("diagnostic detail ", 100), pendingPrompt = "" }, { __index = AIChat })
		local ok, err = pcall(function()
			chat:OpenPopup()
			local status = chat.popupControls.status
			local label = status:GetProperty("label")
			assert.is_true(DrawStringWidth(16, "VAR", label) <= status:GetProperty("width"))
			-- GetPos depends on the native popup anchor, unnecessary for this
			-- text boundary contract. Keep the actual Draw and GetSize methods.
			status.GetPos = function() return 0, 0 end
			status:Draw()
			assert.are.equal(16, sizes[1])
			assert.are.equal(status:GetProperty("width"), viewport.width)
			assert.is_truthy(drawn)
		end)
		main, DrawStringWidth, DrawString, SetViewport = nativeMain, nativeWidth, nativeDraw, nativeViewport
		if not ok then error(err) end
	end)

	it("offers partner-trial reauthorization and keeps MCP queue available after a grant rejection", function()
		local originalMain = main
		local app = { screenW = 650, screenH = 520, popups = { }, unicode = false }
		function app:OpenPopup(width, height, title, controls, enterControl, defaultControl, escapeControl)
			return { width = width, height = height, controls = controls, defaultControl = defaultControl }
		end
		function app:ClosePopup() return true end
		main = app
		local auth = {
			pending = nil,
			IsConnected = function() return true end,
			NeedsReauthorization = function() return true end,
			GetStatus = function() return "ChatGPT authorization was rejected" end,
		}
		local chat = setmetatable({
			auth = auth, models = { { slug = "gpt-6.1-sol", displayName = "GPT-6.1-Sol" } },
			model = { slug = "gpt-6.1-sol", displayName = "GPT-6.1-Sol" },
			messages = { }, draft = "", statusMessage = auth:GetStatus(), pendingPrompt = "retry",
			qaJobId = nil, activeScriptId = nil, waitingForToken = false,
		}, { __index = AIChat })
		chat:OpenPopup()
		assert.is_true(chat.popupControls.signIn:IsShown())
		assert.is_true(chat.popupControls.signIn:IsEnabled())
		assert.are.equal("Reconnect (trial)", chat.popupControls.signIn:GetProperty("label"))
		assert.is_false(chat.popupControls.send:IsEnabled())
		assert.is_false(chat.popupControls.modelPicker:IsEnabled())
		assert.are.equal("composer", chat.popup.defaultControl)
		assert.is_true(chat.popupControls.mcpSetup:IsShown())
		main = originalMain
	end)

	it("opens the native popup with a clickable close control and non-overlapping footer", function()
		local originalMain = main
		local app = { screenW = 650, screenH = 520, popups = { }, unicode = false }
		function app:OpenPopup(width, height, title, controls, enterControl, defaultControl, escapeControl)
			local popup = new("PopupDialog"):PopupDialog(width, height, title, controls, enterControl, defaultControl, escapeControl)
			table.insert(self.popups, 1, popup)
			return popup
		end
		function app:ClosePopup(popup)
			if popup then
				for index, current in ipairs(self.popups) do
					if current == popup then table.remove(self.popups, index) return true end
				end
				return false
			end
			table.remove(self.popups, 1)
			return true
		end
		main = app
		local chat = setmetatable({
			auth = { pending = nil, IsConnected = function() return false end, GetStatus = function() return "Not connected" end },
			models = { }, messages = { }, draft = "", statusMessage = "Ready", pendingPrompt = "",
			qaJobId = nil, activeScriptId = nil, waitingForToken = false,
		}, { __index = AIChat })
		chat:OpenPopup()
		assert.are.equal("Ask AI", chat.popup.title, "the modal title should stay short and leave the connection status readable")
		local closeX, closeY = chat.popupControls.close:GetPos()
		local queueX, queueY = chat.popupControls.queue:GetPos()
		local sendX, sendY = chat.popupControls.send:GetPos()
		assert.are.equal(550, closeX)
		assert.are.equal(184, queueX)
		assert.are.equal(530, sendX)
		assert.are.equal(queueY, sendY)
		local setupX, setupY = chat.popupControls.mcpSetup:GetPos()
		assert.are.equal(320, setupX)
		assert.are.equal(queueY, setupY)
		assert.is_true(chat.popupControls.modelHint:IsShown())
		assert.is_false(chat.popupControls.modelPicker:IsShown())
		chat.popupControls.close:Click()
		main = originalMain
		assert.are.equal(0, #app.popups)
		assert.is_nil(chat.popup)
	end)

	it("queues an external ChatGPT MCP request and displays its returned answer", function()
		local originalMain = main
		local build = { marker = "active" }
		local requestStatus = { status = "processing", message = nil }
		local app = {
			modes = { BUILD = build },
			optimizerMCP = {
				QueueUserRequest = function(_, requestedBuild, prompt)
					assert.are.equal(build, requestedBuild)
					assert.are.equal("Add a legal passive route", prompt)
					return "ai-test-1"
				end,
				GetUserRequestStatus = function(_, requestId, requestedBuild)
					assert.are.equal("ai-test-1", requestId)
					assert.are.equal(build, requestedBuild)
					return { id = requestId, status = requestStatus.status, message = requestStatus.message, buildChanged = requestStatus.buildChanged }
				end,
			},
		}
		main = app
		local composer = { buf = "Add a legal passive route" }
		function composer:SetText(value) self.buf = value end
		local chat = setmetatable({
			auth = { }, models = { }, messages = { }, pendingPrompt = "Add a legal passive route",
			popupControls = { composer = composer }, mcpRequestId = nil, mcpPollAt = 0, mcpPollFailures = 0,
		}, { __index = AIChat })
		local ok, err = pcall(function()
			assert.are.equal("ai-test-1", chat:QueueToMCP())
			assert.are.equal("", chat.pendingPrompt)
			assert.are.equal("", composer.buf)
			assert.are.equal("ai-test-1", chat.mcpRequestId)
			assert.is_truthy(chat.statusMessage:find("Message ChatGPT to fetch", 1, true))
			chat:Tick()
			assert.is_truthy(chat.statusMessage:find("reading and updating", 1, true))
			requestStatus = { status = "completed", message = "PoB applied the requested reversible tree variation.", buildChanged = true }
			chat.mcpPollAt = 0
			chat:Tick()
			assert.is_nil(chat.mcpRequestId)
			assert.are.equal("assistant", chat.messages[#chat.messages].role)
			assert.is_truthy(chat.messages[#chat.messages].text:find("review the resulting build variation", 1, true))
			assert.are.equal("ChatGPT MCP request completed", chat.statusMessage)
		end)
		main = originalMain
		if not ok then error(err) end
	end)

	it("shows the official tunnel setup requirements without exposing credentials", function()
		local originalMain = main
		local opened = nil
		main = { OpenMessagePopup = function(_, title, message) opened = { title = title, message = message } end }
		local chat = setmetatable({ statusMessage = "Ready" }, { __index = AIChat })
		local message = chat:OpenMCPSetup()
		main = originalMain
		assert.is_truthy(opened)
		assert.are.equal("Connect ChatGPT to Path of Building", opened.title)
		assert.is_truthy(message:find("partner trial", 1, true))
		assert.is_truthy(message:find("runtime API key", 1, true))
		assert.is_truthy(message:find("does not wake an inactive ChatGPT conversation", 1, true))
		assert.is_truthy(message:find("Fetch the pending AI Planner request", 1, true))
		assert.is_truthy(message:find("pob.get_pending_ai_request", 1, true))
		assert.is_truthy(message:find("pob.complete_ai_request", 1, true))
		assert.is_nil(message:find("sk-", 1, true), "setup guidance must never contain a credential")
	end)

	it("shows an authenticated empty-state message instead of asking the user to sign in again", function()
		local chat = setmetatable({
			auth = { IsConnected = function() return true end, NeedsReauthorization = function() return false end },
			messages = { }, draft = "",
		}, { __index = AIChat })
		local emptyState = chat:RenderTranscript(500, 250)
		assert.is_truthy(emptyState:find("No messages yet", 1, true))
		assert.is_nil(emptyState:find("Sign in", 1, true))
	end)

	it("draws disclosure and transcript at fixed readable sizes clipped to their panels", function()
		local originalMain = main
		local originalDrawString = DrawString
		local originalDrawStringWidth = DrawStringWidth
		local originalSetViewport = SetViewport
		local originalSetDrawColor = SetDrawColor
		local originalDrawImage = DrawImage
		local originalNewImageHandle = NewImageHandle
		local drawCalls, viewports, imageCalls, colorCalls = { }, { }, { }, { }
		local logoLoads, loadedPath = 0, nil
		local logoImage = { }
		local app = { screenW = 870, screenH = 610, popups = { }, unicode = false }
		function app:WrapString(text, fontSize, width)
			assert.is_true(fontSize == 13 or fontSize == 14)
			return { text }
		end
		function app:OpenPopup(width, height, title, controls, enterControl, defaultControl, escapeControl)
			return { }
		end
		function app:ClosePopup() return true end
		main = app
		DrawStringWidth = function(_, _, text) return #tostring(text or "") end
		DrawString = function(x, y, align, fontSize, font, text)
			drawCalls[#drawCalls + 1] = { x = x, y = y, fontSize = fontSize, text = text }
		end
		SetViewport = function(x, y, width, height)
			viewports[#viewports + 1] = { x = x, y = y, width = width, height = height }
		end
		SetDrawColor = function(...)
			colorCalls[#colorCalls + 1] = { ... }
		end
		DrawImage = function(...)
			imageCalls[#imageCalls + 1] = { ... }
		end
		NewImageHandle = function()
			return logoImage
		end
		function logoImage:Load(path) logoLoads = logoLoads + 1 loadedPath = path end
		local ok, err = pcall(function()
			local chat = setmetatable({
				auth = { IsConnected = function() return false end }, models = { }, messages = { }, draft = "",
				statusMessage = "Ready", pendingPrompt = "", qaJobId = nil, activeScriptId = nil, waitingForToken = false,
			}, { __index = AIChat })
			chat:OpenPopup()
			local disclosure = chat.popupControls.disclosure
			local transcript = chat.popupControls.transcript
			disclosure:Draw()
			transcript:Draw()
			assert.are.equal(13, drawCalls[1].fontSize)
			assert.are.equal(13, drawCalls[2].fontSize)
			assert.are.equal(14, drawCalls[3].fontSize)
			assert.is_true(drawCalls[1].fontSize < disclosure:GetProperty("height"))
			assert.is_true(drawCalls[3].fontSize < transcript:GetProperty("height"))
			local disclosureX, disclosureY = disclosure:GetPos()
			local disclosureWidth, disclosureHeight = disclosure:GetSize()
			assert.are.equal(disclosureX, viewports[1].x)
			assert.are.equal(disclosureY, viewports[1].y)
			assert.are.equal(disclosureWidth, viewports[1].width)
			assert.are.equal(disclosureHeight, viewports[1].height)
			assert.are.equal(nil, viewports[2].x) -- viewport restored after the disclosure
			local transcriptX, transcriptY = transcript:GetPos()
			local transcriptWidth, transcriptHeight = transcript:GetSize()
			assert.are.equal(transcriptX + 8, viewports[3].x)
			assert.are.equal(transcriptY + 8, viewports[3].y)
			assert.are.equal(transcriptWidth - 16, viewports[3].width)
			assert.are.equal(transcriptHeight - 16, viewports[3].height)
			assert.are.equal(nil, viewports[4].x) -- viewport restored after the transcript
			assert.are.equal(1, logoLoads)
			assert.is_truthy(loadedPath:match("Assets/ai%-planner%-watermark%.png$"))
			local logoDrawn = false
			for _, call in ipairs(imageCalls) do
				if call[1] == logoImage then logoDrawn = true end
			end
			assert.is_true(logoDrawn)
			local logoOpacity = false
			local panelOpacity = false
			for _, color in ipairs(colorCalls) do
				if color[4] == 0.13 then logoOpacity = true end
				if color[1] == 0.07 and color[4] == 0.9 then panelOpacity = true end
			end
			assert.is_true(logoOpacity)
			assert.is_true(panelOpacity)

			local fallbackStart = #imageCalls
			NewImageHandle = function()
				return { Load = function() error("simulated watermark load failure") end }
			end
			local fallbackChat = setmetatable({
				auth = { IsConnected = function() return false end }, models = { }, messages = { }, draft = "",
				statusMessage = "Ready", pendingPrompt = "", qaJobId = nil, activeScriptId = nil, waitingForToken = false,
			}, { __index = AIChat })
			fallbackChat:OpenPopup()
			fallbackChat.popupControls.transcript:Draw()
			assert.is_nil(fallbackChat.brandLogo)
			assert.is_true(#imageCalls - fallbackStart >= 14) -- native graph fallback remains visible
		end)
		main = originalMain
		DrawString = originalDrawString
		DrawStringWidth = originalDrawStringWidth
		SetViewport = originalSetViewport
		SetDrawColor = originalSetDrawColor
		DrawImage = originalDrawImage
		NewImageHandle = originalNewImageHandle
		if not ok then error(err) end
	end)

	it("preserves structured Responses failure details and identifies rejected authorization", function()
		local failure = AIChat.FormatRequestFailure(
			'{"http_status":401,"request_id":"req_pob_test","response_id":"resp_pob_test","error":{"code":"invalid_grant","message":"The ChatGPT authorization was rejected","param":"model"}}',
			nil, nil)
		assert.is_true(failure.requiresReauthorization)
		assert.are.equal(401, failure.httpCode)
		assert.are.equal("invalid_grant", failure.code)
		assert.are.equal("model", failure.param)
		assert.are.equal("req_pob_test", failure.requestId)
		assert.are.equal("resp_pob_test", failure.responseId)
		assert.is_truthy(failure.transcript:find("The ChatGPT authorization was rejected", 1, true))
		assert.is_truthy(failure.transcript:find("Request ID: req_pob_test", 1, true))

		local temporary = AIChat.FormatRequestFailure('{"detail":"Direct route temporarily unavailable"}', nil, 503)
		assert.is_false(temporary.requiresReauthorization)
		assert.are.equal(503, temporary.httpCode)
		assert.is_truthy(temporary.transcript:find("Direct route temporarily unavailable", 1, true))
	end)

	it("normalizes account and standard model catalogs to text chat models", function()
		local accountModels = Auth.NormalizeModelCatalog({ models = {
			{ slug = "gpt-fast", display_name = "Fast model", visibility = "list" },
			{ slug = "gpt-hidden", display_name = "Hidden model", visibility = "hidden" },
			{ slug = "gpt-fast", display_name = "Duplicate", visibility = "list" },
			{ slug = "text-embedding-3-small", display_name = "Embedding", visibility = "list" },
		} })
		assert.are.equal(1, #accountModels)
		assert.are.equal("gpt-fast", accountModels[1].slug)
		assert.are.equal("Fast model", accountModels[1].displayName)

		local standardModels = Auth.NormalizeModelCatalog({ object = "list", data = {
			{ id = "gpt-4.1", owned_by = "openai" },
			{ id = "o3-mini", owned_by = "openai" },
			{ id = "gpt-4o-realtime-preview", owned_by = "openai" },
			{ id = "whisper-1", owned_by = "openai" },
			{ id = "future-chat-model", supported_endpoints = { "/responses" } },
		} })
		assert.are.equal(3, #standardModels)
		assert.are.equal("gpt-4.1", standardModels[1].slug)
		assert.are.equal("o3-mini", standardModels[2].slug)
		assert.are.equal("future-chat-model", standardModels[3].slug)
		assert.is_nil(Auth.NormalizeModelCatalog({ object = "list", models = "invalid" }))
	end)

	it("populates the native selector with the account's model catalog and keeps the selected slug", function()
		local actualOptions, selectedSlug
		local chat = setmetatable({
			models = {
				{ slug = "model-fast", displayName = "Fast model" },
				{ slug = "model-reasoning", displayName = "Reasoning model" },
			},
			model = { slug = "model-reasoning", displayName = "Reasoning model" },
			popupControls = {
				modelPicker = {
					SetList = function(_, options) actualOptions = options end,
					SelByValue = function(_, value) selectedSlug = value end,
				},
			},
		}, { __index = AIChat })

		chat:UpdateModelPicker()
		assert.are.equal(2, #actualOptions)
		assert.are.equal("Fast model", actualOptions[1].label)
		assert.are.equal("model-fast", actualOptions[1].slug)
		assert.are.equal("model-reasoning", selectedSlug)
	end)

	it("keeps model refresh retryable after a catalog failure", function()
		local callbacks, options, selectedSlug = { }, nil, nil
		local auth = {
			IsConnected = function() return true end,
			FetchModels = function(_, callback) callbacks[#callbacks + 1] = callback end,
		}
		local chat = setmetatable({
			auth = auth, models = { }, messages = { }, statusMessage = "Ready", fetchingModels = false,
			popupControls = { modelPicker = {
				SetList = function(_, value) options = value end,
				SelByValue = function(_, value) selectedSlug = value end,
			} },
		}, { __index = AIChat })
		assert.is_true(chat:FetchModels())
		assert.is_true(chat.fetchingModels)
		assert.is_false(chat:FetchModels())
		callbacks[1](nil, "temporary model catalog error")
		assert.is_false(chat.fetchingModels)
		assert.is_truthy(chat.statusMessage:find("temporary model catalog error", 1, true))

		assert.is_true(chat:FetchModels())
		callbacks[2]({ { slug = "gpt-4.1", displayName = "GPT-4.1" } })
		assert.is_false(chat.fetchingModels)
		assert.are.equal("gpt-4.1", chat.model.slug)
		assert.are.equal("gpt-4.1", selectedSlug)
		assert.are.equal("GPT-4.1", options[1].label)
	end)

	it("attaches local QA results only when their source build still matches the active snapshot", function()
		local current = AIChat.DiagnosticContext("QA passed", "same-build", "same-build")
		local historical = AIChat.DiagnosticContext("QA passed", "old-build", "new-build")
		assert.is_truthy(current:find("same source%-build signature"))
		assert.is_false(current:find("Historical PoB QA results", 1, true) ~= nil)
		assert.is_truthy(historical:find("Historical PoB QA results", 1, true))
		assert.is_truthy(historical:find("Do not use them to claim", 1, true))
	end)

	it("runs read-only PoB diagnostics from the Ask AI panel and records every suite result", function()
		local originalMain = main
		local startedSuites = { }
		local bridge = { }
		function bridge:CallLocal(method, arguments)
			if method == "qa_start" then
				startedSuites[#startedSuites + 1] = arguments.suite
				return { jobId = "qa-" .. arguments.suite, suite = arguments.suite, status = "running" }
			end
			assert.are.equal("qa_status", method)
			local suite = arguments.jobId:sub(4)
			return {
				jobId = arguments.jobId,
				suite = suite,
				status = suite == "build" and "passed_with_warnings" or "passed",
				readOnly = true,
				activeBuildPreserved = true,
				checks = suite == "build"
					and { { name = "Native recurring activity sustain", status = "warning", detail = "Exact PoB recovery 1.7/s is below recurring activity cost 6.66667/s" } }
					or { { name = "fixture check", status = "pass", detail = "exact local result" } },
			}
		end
		main = { optimizerMCP = bridge }
		local chat = setmetatable({
			auth = { pending = nil, GetStatus = function() return "Connected" end },
			messages = { }, qaResults = { }, qaJobId = nil, qaSuiteIndex = nil, qaNextPoll = 0,
			statusMessage = "Ready", draft = "", turns = { },
		}, { __index = AIChat })

		local ok = chat:RunDiagnostics()
		assert.is_true(ok)
		assert.are.equal("integration", startedSuites[1])
		for _ = 1, 3 do chat:Tick() end
		main = originalMain

		assert.are.same({ "integration", "planner", "build" }, startedSuites)
		assert.are.equal(3, #chat.qaResults)
		assert.is_truthy(chat.lastDiagnosticSummary:find("fixture check", 1, true))
		assert.is_truthy(chat.lastDiagnosticSummary:find("passed_with_warnings", 1, true))
		assert.is_truthy(chat.lastDiagnosticSummary:find("Exact PoB recovery 1.7/s is below recurring activity cost 6.66667/s", 1, true))
		assert.is_truthy(chat.messages[1].text:find("Read%-only PoB diagnostics completed"))
	end)

	it("closes the Ask AI popup and cancels hidden in-flight work", function()
		local originalMain = main
		local popupClosed, closedPopup, requestCancelled, diagnosticsCancelled = false, nil, false, false
		main = { ClosePopup = function(_, popup) popupClosed, closedPopup = true, popup return true end }
		local chat = setmetatable({
			auth = { pending = nil },
			popup = { id = "ask-ai" },
			activeScriptId = "active-request",
			waitingForToken = false,
			currentTurn = nil,
			CancelRequest = function() requestCancelled = true end,
			CancelDiagnostics = function() diagnosticsCancelled = true end,
		}, { __index = AIChat })

		chat:Close()
		main = originalMain

		assert.is_true(requestCancelled)
		assert.is_true(diagnosticsCancelled)
		assert.is_true(popupClosed)
		assert.are.equal("ask-ai", closedPopup.id)
		assert.is_nil(chat.popup)
	end)

	it("removes only the requested popup instance from the native popup stack", function()
		local nativeMain = main
		local olderPopup, requestedPopup, topPopup = { id = "older" }, { id = "ask-ai" }, { id = "top" }
		local app = setmetatable({ popups = { topPopup, requestedPopup, olderPopup } }, { __index = nativeMain })
		local ok, err = pcall(function()
			assert.is_true(app:ClosePopup(requestedPopup))
			assert.are.equal(2, #app.popups)
			assert.are.equal(topPopup, app.popups[1])
			assert.are.equal(olderPopup, app.popups[2])
			assert.is_false(app:ClosePopup(requestedPopup))
		end)
		main = nativeMain
		if not ok then error(err) end
	end)

	it("Escape closes the Ask AI instance without removing a different popup", function()
		local originalMain = main
		local otherPopup = { id = "other" }
		local app = { screenW = 650, screenH = 520, popups = { otherPopup }, unicode = false }
		function app:OpenPopup(width, height, title, controls, enterControl, defaultControl, escapeControl)
			local popup = new("PopupDialog"):PopupDialog(width, height, title, controls, enterControl, defaultControl, escapeControl)
			table.insert(self.popups, 1, popup)
			return popup
		end
		function app:ClosePopup(popup)
			for index, current in ipairs(self.popups) do
				if current == popup then table.remove(self.popups, index) return true end
			end
			return false
		end
		main = app
		local chat = setmetatable({
			auth = { pending = nil, IsConnected = function() return false end, GetStatus = function() return "Not connected" end },
			models = { }, messages = { }, draft = "", statusMessage = "Ready", pendingPrompt = "",
			qaJobId = nil, activeScriptId = nil, waitingForToken = false,
		}, { __index = AIChat })
		chat:OpenPopup()
		local askPopup = chat.popup
		assert.are.equal(2, #app.popups)
		askPopup:SelectControl(chat.popupControls.composer)
		askPopup:ProcessInput({ { type = "KeyDown", key = "ESCAPE" } }, { x = 0, y = 0, width = 650, height = 520 })
		main = originalMain
		assert.are.equal(1, #app.popups)
		assert.are.equal(otherPopup, app.popups[1])
		assert.is_nil(chat.popup)
	end)
end)
