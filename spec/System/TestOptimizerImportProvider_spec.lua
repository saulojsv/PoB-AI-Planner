describe("PoB native import provider resolution", function()
	local originalDownloadPage, originalLaunchSubScript, originalSubScripts

	before_each(function()
		originalDownloadPage = launch.DownloadPage
		originalLaunchSubScript = LaunchSubScript
		originalSubScripts = launch.subScripts
	end)

	after_each(function()
		launch.DownloadPage = originalDownloadPage
		LaunchSubScript = originalLaunchSubScript
		launch.subScripts = originalSubScripts
	end)

	local function resolveDownload(link, provider)
		local requestUrl, result, requestOptions
		launch.DownloadPage = function(_, url, callback, params)
			requestUrl = url
			requestOptions = params
			callback({ body = "native-export-fixture" }, nil)
			return 1
		end
		buildSites.DownloadBuild(link, provider, function(success, data, url)
			result = { success = success, data = data, url = url }
		end)
		return requestUrl, result, requestOptions
	end

	local cases = {
		{ id = "Maxroll", link = "https://maxroll.gg/poe/pob/test-build", expected = "https://maxroll.gg/poe/api/pob/test-build" },
		{ id = "PoBCodes", link = "https://pob.codes/b/test-build", expected = "https://api.pob.codes/test-build/raw" },
		{ id = "POBBin", link = "https://pobb.in/test-build", expected = "https://pobb.in/pob/test-build" },
		{ id = "PoeNinja", link = "https://poe.ninja/poe1/pob/abc123", expected = "https://poe.ninja/poe1/pob/raw/abc123" },
		{ id = "pastebin", link = "https://pastebin.com/abc123", expected = "https://pastebin.com/raw/abc123" },
		{ id = "pastebinProxy", link = "https://pastebinp.com/abc123", expected = "https://pastebinp.com/raw/abc123" },
		{ id = "rentry", link = "https://rentry.co/abc123", expected = "https://rentry.co/paste/abc123/raw" },
		{ id = "PoEDB", link = "https://poedb.tw/pob/abc123", expected = "https://poedb.tw/pob/abc123/raw" },
	}

	for _, case in ipairs(cases) do
		it("resolves " .. case.id .. " only through its native provider rule", function()
			local provider
			for _, site in ipairs(buildSites.websiteList) do if site.id == case.id then provider = site break end end
			assert.is_truthy(provider)
			local requestUrl, result = resolveDownload(case.link, provider)
			assert.are.equal(case.expected, requestUrl)
			assert.is_true(result.success)
			assert.are.equal("native-export-fixture", result.data)
			assert.are.equal(case.expected, result.url)
		end)
	end

	it("keeps encoded PoBB profile discriminators while resolving the native endpoint", function()
		local provider = assert(buildSites.websiteList[3])
		local requestUrl, result = resolveDownload("https://pobb.in/u/profile%23pc/build-1", provider)
		assert.are.equal("https://pobb.in/pob/profile%23pc:build-1", requestUrl)
		assert.is_true(result.success)
	end)

	it("resolves a pob protocol URI using the allowlisted provider host", function()
		local requestUrl, result = resolveDownload("pob://pobbin/profile%23pc:build-1", nil)
		assert.are.equal("https://pobb.in/pob/profile%23pc:build-1", requestUrl)
		assert.is_true(result.success)
	end)

	it("passes a response byte limit to PoB's native downloader", function()
		local provider = assert(buildSites.websiteList[3])
		local _, result, requestOptions = resolveDownload("https://pobb.in/test-build", provider)
		assert.is_true(result.success)
		assert.are.equal(buildSites.MAX_BUILD_CODE_BYTES, requestOptions.maxResponseBytes)
		assert.is_true(requestOptions.followRedirects, "normal PoB imports should retain their existing redirect behavior")
	end)

	it("rejects absent, malformed and empty provider response bodies", function()
		local provider = assert(buildSites.websiteList[3])
		local cases = {
			{ label = "absent response", response = false },
			{ label = "missing body", response = { } },
			{ label = "non-text body", response = { body = 42 } },
			{ label = "empty body", response = { body = "" } },
		}
		for _, case in ipairs(cases) do
			local result
			launch.DownloadPage = function(_, _, callback)
				callback(case.response == false and nil or case.response, nil)
				return 17
			end
			buildSites.DownloadBuild("https://pobb.in/test-build", provider, function(success, data, url, reason)
				result = { success = success, data = data, url = url, reason = reason }
			end)
			assert.is_false(result.success, case.label)
			assert.are.equal("download_invalid_response", result.reason, case.label)
			assert.are.equal("https://pobb.in/pob/test-build", result.url, case.label)
		end
	end)

	it("rejects an oversized response and exposes only a typed failure", function()
		local provider = assert(buildSites.websiteList[3])
		local result
		launch.DownloadPage = function(_, _, callback, params)
			assert.are.equal(buildSites.MAX_BUILD_CODE_BYTES, params.maxResponseBytes)
			callback({ body = string.rep("x", buildSites.MAX_BUILD_CODE_BYTES + 1) }, nil)
			return 18
		end
		buildSites.DownloadBuild("https://pobb.in/test-build", provider, function(success, data, url, reason)
			result = { success = success, data = data, url = url, reason = reason }
		end)
		assert.is_false(result.success)
		assert.are.equal("download_too_large", result.reason)
		assert.are.equal("Build download exceeds the size limit", result.data)
	end)

	it("reports network and request-start failures without hanging the import UI", function()
		local provider = assert(buildSites.websiteList[3])
		local networkResult
		launch.DownloadPage = function(_, _, callback) callback(nil, "Response code: 503"); return 19 end
		buildSites.DownloadBuild("https://pobb.in/test-build", provider, function(success, data, _, reason)
			networkResult = { success = success, data = data, reason = reason }
		end)
		assert.is_false(networkResult.success)
		assert.are.equal("download_failed", networkResult.reason)
		assert.are.equal("Response code: 503", networkResult.data)

		local startResult, callbackCount
		callbackCount = 0
		launch.DownloadPage = function() return nil end
		buildSites.DownloadBuild("https://pobb.in/test-build", provider, function(success, data, _, reason)
			callbackCount = callbackCount + 1
			startResult = { success = success, data = data, reason = reason }
		end)
		assert.are.equal(1, callbackCount)
		assert.is_false(startResult.success)
		assert.are.equal("download_start_failed", startResult.reason)
	end)

	it("delivers only the first provider callback", function()
		local provider = assert(buildSites.websiteList[3])
		local callbackCount, result = 0
		launch.DownloadPage = function(_, _, callback)
			callback({ body = "native-export-fixture" }, nil)
			callback({ body = "" }, nil)
			return 20
		end
		buildSites.DownloadBuild("https://pobb.in/test-build", provider, function(success, data)
			callbackCount = callbackCount + 1
			result = { success = success, data = data }
		end)
		assert.are.equal(1, callbackCount)
		assert.is_true(result.success)
		assert.are.equal("native-export-fixture", result.data)
	end)

	it("embeds an optional hard body cap in the generated download worker", function()
		local captured
		launch.subScripts = { }
		LaunchSubScript = function(script, _, _, url, _, _, _, _, _, _, maxResponseBytes)
			captured = { script = script, url = url, maxResponseBytes = maxResponseBytes }
			return 21
		end
		local id = launch:DownloadPage("https://pobb.in/pob/test-build", function() end, { maxResponseBytes = 4096 })
		assert.are.equal(21, id)
		assert.are.equal(4096, captured.maxResponseBytes)
		assert.are.equal("https://pobb.in/pob/test-build", captured.url)
		assert.is_truthy(captured.script:find("local nextSize = responseBodyBytes + #data", 1, true))
		assert.is_truthy(captured.script:find("nextSize > maxResponseBytes", 1, true))
		assert.is_truthy(captured.script:find("Response exceeded maximum allowed size", 1, true))
	end)

	it("maps study redirect refusal into the generated curl worker", function()
		local captured
		launch.subScripts = { }
		LaunchSubScript = function(script, _, _, url, _, _, _, _, _, _, maxResponseBytes, followRedirects)
			captured = { script = script, url = url, maxResponseBytes = maxResponseBytes, followRedirects = followRedirects }
			return 22
		end
		local id = launch:DownloadPage("https://pobb.in/pob/study-fixture", function() end, {
			maxResponseBytes = 4096,
			followRedirects = false,
		})

		assert.are.equal(22, id)
		assert.are.equal("https://pobb.in/pob/study-fixture", captured.url)
		assert.are.equal(4096, captured.maxResponseBytes)
		assert.is_false(captured.followRedirects)
		assert.is_truthy(captured.script:find("easy:setopt(curl.OPT_FOLLOWLOCATION, followRedirects and 1 or 0)", 1, true))
	end)

	it("preserves no-redirect behavior for authenticated TLS downloads", function()
		local captured
		launch.subScripts = { }
		LaunchSubScript = function(script, _, _, url, _, _, _, _, _, _, _, followRedirects)
			captured = { script = script, url = url, followRedirects = followRedirects }
			return 23
		end
		local id = launch:DownloadPage("https://api.example.invalid/token", function() end, { forceTLS = true })

		assert.are.equal(23, id)
		assert.are.equal("https://api.example.invalid/token", captured.url)
		assert.is_false(captured.followRedirects)
	end)

	it("rejects a link from a different or spoofed provider without starting a download", function()
		local provider
		for _, site in ipairs(buildSites.websiteList) do if site.id == "POBBin" then provider = site break end end
		local requests = 0
		local result
		launch.DownloadPage = function() requests = requests + 1 end
		buildSites.DownloadBuild("https://pobb.in.evil.example/u/profile/build", provider, function(success, message)
			result = { success = success, message = message }
		end)
		assert.are.equal(0, requests)
		assert.is_false(result.success)
		assert.are.equal("Link does not match selected provider", result.message)
	end)

	it("does not trust caller-supplied regex or destination fields", function()
		local provider = { id = "POBBin", regexURL = ".*", downloadURL = "evil.example/raw/%1", matchURL = ".*" }
		local requestUrl, result = resolveDownload("https://pobb.in/test-build", provider)
		assert.are.equal("https://pobb.in/pob/test-build", requestUrl)
		assert.is_true(result.success)
	end)

	it("keeps unknown providers distinct from network failures", function()
		local requests, result = 0
		launch.DownloadPage = function() requests = requests + 1 end
		buildSites.DownloadBuild("https://example.invalid/build", nil, function(success, message)
			result = { success = success, message = message }
		end)
		assert.are.equal(0, requests)
		assert.is_false(result.success)
		assert.are.equal("Download information not found", result.message)
	end)

	it("rejects malformed and oversized links without calling the downloader", function()
		local provider
		for _, site in ipairs(buildSites.websiteList) do if site.id == "POBBin" then provider = site break end end
		local requests, messages = 0, { }
		launch.DownloadPage = function() requests = requests + 1 end
		for _, link in ipairs({ "https://pobb.in/u/incomplete", string.rep("a", 4097), "https://pobb.in/has\ncontrol" }) do
			buildSites.DownloadBuild(link, provider, function(success, message)
				messages[#messages + 1] = { success = success, message = message }
			end)
		end
		assert.are.equal(0, requests)
		assert.are.equal(3, #messages)
		for _, result in ipairs(messages) do assert.is_false(result.success) end
		assert.are.equal("Invalid PoBB profile build URL", messages[1].message)
		assert.are.equal("Invalid build link", messages[2].message)
		assert.are.equal("Invalid build link", messages[3].message)
	end)
end)
