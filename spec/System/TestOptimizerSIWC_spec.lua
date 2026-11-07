local Auth = require("Modules.Optimizer.SIWC")
local dkjson = require("dkjson")

local SIGNED_ID_TOKEN = "eyJhbGciOiJSUzI1NiIsImtpZCI6InFhLW9hdXRoLWZpeHR1cmUifQ.eyJpc3MiOiJodHRwczovL2F1dGgub3BlbmFpLmNvbSIsImF1ZCI6Im9haWFwcC1zeW50aGV0aWMiLCJzdWIiOiJmaXh0dXJlLXN1YmplY3QiLCJlbWFpbCI6InFhQGV4YW1wbGUuaW52YWxpZCIsImV4cCI6NDEwMjQ0NDgwMCwibm9uY2UiOiJmaXh0dXJlLW5vbmNlIn0.GwWK5KSmvd0j7tJFIn0QLE4TeHlpe2KJIbSBeygZzJNfOfmJGWPjGb5gXsp-74BS_6-1FKVvoGkt0-awFZLtzBHBrgQrOkfI7dN5QgRrS1KQ5uzpnwR-90QcwK2SL9dV37OrGiKMQWuP08sknbIumVDe4mDpunA8YONGukSsE4YJBZHbWwbIxUS0znjn_JUgEXZjtHhEPO9CXCP3O4x-BrR4aAY1r0TD_7i1zMbPowqcoD9lyAIJDkHkuN6eKT8bGcCyNcp-ITVnxR5adc93d33QnY7AF4t8i0t-ColIxTuMPgJqcGnMS5cMRFdwOiHz8zv8Lwn9IKFE1eW0rbl8XQ"
local SIGNING_KEY = {
	kty = "RSA", use = "sig", alg = "RS256", kid = "qa-oauth-fixture",
	n = "mhUYpTr_JMeGJKdXbBOftmTtuCb1VMlzsFlqmwyjUcfosTU4uz53zamkxoxWar7HcuNpEgmFHilm_JneJyu767T4lgmBWo0eIsexh8rLdqlKpsMaLUboN0bWE4BoZEMNRWAp1wgy0Lrbg19NZz6uhex_lkhXQGZ9Uin2G2QjTrupTDV7EGHt7J6-je4dkzd9yGgHPRiHZ_NdPiwJaLXrEDwkJ-eo1xjJsrTo8nWZ_JFsqpWtbs_H9Pk5N_HYt9C2EXlsxBuBbZTpmCOKS4AsXJZ5WC0FeryWQa1JIHwpc2WjkZh5-L2gjUZGHKsie3xFILzVc4O1uhLBI2CJFvJK4Q",
	e = "AQAB",
}

local function withAuthGlobals(callback)
	local originalLaunch, originalLaunchSubScript = launch, LaunchSubScript
	local fakeLaunch = { subScripts = { } }
	local launchInfo
	launch = fakeLaunch
	LaunchSubScript = function(source, arguments, globals, state, clientId, authorizeUrl)
		launchInfo = {
			source = source, arguments = arguments, globals = globals,
			state = state, clientId = clientId, authorizeUrl = authorizeUrl,
		}
		return "qa-oauth-subscript"
	end
	local ok, err = xpcall(function() callback(fakeLaunch, function() return launchInfo end) end, debug.traceback)
	launch, LaunchSubScript = originalLaunch, originalLaunchSubScript
	if not ok then error(err) end
end

local function newAuth()
	return setmetatable({ record = { hostId = "urn:uuid:qa-oauth-host" }, status = "not connected" }, { __index = Auth })
end

local function startAuth(auth, fakeLaunch)
	local outcome
	local started, startError = auth:Begin(function(ok, message) outcome = { ok = ok, message = message } end)
	assert.is_true(started, startError)
	local callbackScript = assert(fakeLaunch.subScripts["qa-oauth-subscript"])
	assert.are.equal("DOWNLOAD", callbackScript.type)
	return callbackScript.callback, outcome
end

describe("AI Planner ChatGPT OAuth contracts", function()
	it("routes Begin through the callback, code exchange, ID claim gate, and credential save", function()
		withAuthGlobals(function(fakeLaunch, getLaunchInfo)
			local auth = newAuth()
			local saved = false
			function auth:ValidateIDToken(idToken, clientId, nonce, callback)
				assert.are.equal("synthetic-id-token", idToken)
				assert.are.equal("oaiapp-issued-qa", clientId)
				assert.is_truthy(nonce)
				callback({ sub = "qa-subject", email = "qa@example.invalid" })
			end
			function auth:Save()
				saved = true
				return true
			end
			fakeLaunch.DownloadPage = function(_, url, callback, params)
				assert.are.equal("https://auth.openai.com/api/accounts/oauth/token", url)
				assert.is_true(params.forceTLS)
				assert.is_truthy(params.body:find("grant_type=authorization_code", 1, true))
				assert.is_truthy(params.body:find("client_id=oaiapp%-issued%-qa"))
				assert.is_truthy(params.body:find("code=synthetic%-code"))
				assert.is_truthy(params.body:find("code_verifier="))
				assert.is_truthy(params.body:find("redirect_uri=http%%3A%%2F%%2F127%.0%.0%.1%%3A43127%%2Fauth%%2Fcallback"))
				assert.is_truthy(params.body:find("resource=https%%3A%%2F%%2Fapi%.openai%.com%%2Fv1"))
				callback({ body = dkjson.encode({
					scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
					id_token = "synthetic-id-token", access_token = "synthetic-access", refresh_token = "synthetic-refresh",
					token_type = "Bearer", expires_in = 3600,
				}) })
			end
			local callback = startAuth(auth, fakeLaunch)
			local launchInfo = getLaunchInfo()
			assert.is_truthy(launchInfo.authorizeUrl:find("%2Fauth%2Fcallback", 1, true))
			assert.are.equal("dynamic_agent_client", launchInfo.clientId)
			callback("synthetic-code", nil, launchInfo.state, "oaiapp-issued-qa", "openid profile", 43127)
			assert.is_true(saved)
			assert.are.equal("qa-subject", auth.record.credentials.subject)
			assert.are.equal("synthetic-refresh", auth.record.credentials.refreshToken)
			assert.is_true(auth:IsConnected())
		end)
	end)

	it("rejects a mismatched callback state before making a token request", function()
		withAuthGlobals(function(fakeLaunch)
			local auth = newAuth()
			local requests, result = 0, nil
			auth:Begin(function(ok, message) result = { ok = ok, message = message } end)
			fakeLaunch.DownloadPage = function() requests = requests + 1 end
			local launchInfo = fakeLaunch.subScripts["qa-oauth-subscript"]
			launchInfo.callback("synthetic-code", nil, "wrong-state", "oaiapp-issued-qa", "openid", 43127)
			assert.are.equal(0, requests)
			assert.is_false(result.ok)
			assert.is_truthy(result.message:find("state did not match", 1, true))
			assert.is_nil(auth.record.credentials)
		end)
	end)

	for _, invalidToken in ipairs({
		{ field = "refresh_token", value = "", label = "empty refresh token" },
		{ field = "refresh_token", value = "   ", label = "whitespace-only refresh token" },
		{ field = "access_token", value = "", label = "empty access token" },
		{ field = "access_token", value = "   ", label = "whitespace-only access token" },
	}) do
		it("does not persist an " .. invalidToken.label, function()
			withAuthGlobals(function(fakeLaunch)
				local auth = newAuth()
				local saveCalls, outcome = 0, nil
				auth.ValidateIDToken = function(_, _, _, _, callback) callback({ sub = "qa-subject" }) end
				function auth:Save() saveCalls = saveCalls + 1 return true end
				fakeLaunch.DownloadPage = function(_, _, callback)
					local response = {
						scope = "resource.invoke chatgpt.tokens.use.direct", id_token = "synthetic-id-token",
						access_token = "synthetic-access", refresh_token = "synthetic-refresh", expires_in = 3600,
					}
					response[invalidToken.field] = invalidToken.value
					callback({ body = dkjson.encode(response) })
				end
				auth:Begin(function(ok, message) outcome = { ok = ok, message = message } end)
				local launchInfo = fakeLaunch.subScripts["qa-oauth-subscript"]
				launchInfo.callback("synthetic-code", nil, auth.pending.state, "oaiapp-issued-qa", "openid", 43127)
				assert.are.equal(0, saveCalls)
				assert.is_false(outcome.ok)
				assert.is_truthy(outcome.message:find("required credentials", 1, true))
				assert.is_nil(auth.record.credentials)
			end)
		end)
	end

	it("restores the prior credentials when protected persistence fails", function()
		withAuthGlobals(function(fakeLaunch)
			local oldCredential = { clientId = "oaiapp-old", subject = "old-subject", accessToken = "old-access", refreshToken = "old-refresh" }
			local auth = setmetatable({ record = { hostId = "urn:uuid:qa-oauth-host", credentials = oldCredential } }, { __index = Auth })
			auth.ValidateIDToken = function(_, _, _, _, callback) callback({ sub = "old-subject" }) end
			function auth:Save() return false, "synthetic protected-store failure" end
			local outcome
			fakeLaunch.DownloadPage = function(_, _, callback)
				callback({ body = dkjson.encode({
					scope = "resource.invoke chatgpt.tokens.use.direct", id_token = "synthetic-id-token",
					access_token = "new-access", refresh_token = "new-refresh", expires_in = 3600,
				}) })
			end
			auth:Begin(function(ok, message) outcome = { ok = ok, message = message } end)
			local launchInfo = fakeLaunch.subScripts["qa-oauth-subscript"]
			launchInfo.callback("synthetic-code", nil, auth.pending.state, "oaiapp-old", "openid", 43127)
			assert.is_false(outcome.ok)
			assert.are.equal("synthetic protected-store failure", outcome.message)
			assert.are.equal(oldCredential, auth.record.credentials)
			assert.are.equal("old-access", auth.record.credentials.accessToken)
		end)
	end)

	it("verifies a synthetic RS256 ID token against the native Windows CNG verifier", function()
		withAuthGlobals(function(fakeLaunch)
			local auth, claims, validationError = newAuth(), nil, nil
			fakeLaunch.DownloadPage = function(_, url, callback, params)
				assert.are.equal("https://auth.openai.com/.well-known/jwks.json", url)
				assert.is_true(params.forceTLS)
				callback({ body = dkjson.encode({ keys = { SIGNING_KEY } }) })
			end
			auth:ValidateIDToken(SIGNED_ID_TOKEN, "oaiapp-synthetic", "fixture-nonce", function(value, err)
				claims, validationError = value, err
			end)
			assert.is_nil(validationError)
			assert.are.equal("fixture-subject", claims.sub)
			assert.are.equal("qa@example.invalid", claims.email)
		end)
	end)

	it("rejects a modified RS256 signature and a mismatched nonce", function()
		withAuthGlobals(function(fakeLaunch)
			local auth = newAuth()
			fakeLaunch.DownloadPage = function(_, _, callback) callback({ body = dkjson.encode({ keys = { SIGNING_KEY } }) }) end
			local tampered = SIGNED_ID_TOKEN:gsub(".$", "A")
			local signatureError
			auth:ValidateIDToken(tampered, "oaiapp-synthetic", "fixture-nonce", function(claims, err) signatureError = err end)
			assert.is_nil(signatureError:find("issuer, audience", 1, true))
			local nonceError
			auth:ValidateIDToken(SIGNED_ID_TOKEN, "oaiapp-synthetic", "wrong-nonce", function(claims, err) nonceError = err end)
			assert.is_truthy(nonceError:find("nonce", 1, true))
		end)
	end)
end)
