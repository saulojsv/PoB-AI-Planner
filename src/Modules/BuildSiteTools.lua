-- Path of Building
--
-- Module: Build Site Tools
-- Functions used to import and export PoB build codes from external websites
--

buildSites = { }
local MAX_BUILD_CODE_BYTES = 16777216
buildSites.MAX_BUILD_CODE_BYTES = MAX_BUILD_CODE_BYTES

-- Import/Export websites list used in dropdowns
-- label: What a user sees in the export dropdown and when the import box recognizes the website
-- id: Protocol handler id used to load builds with the pob: URL scheme e.g. pob://Maxroll/siteSpecificBuildId
-- matchURL: A pattern to match URLs belonging to this website to show a valid url message in ImportTab
-- regexURL: Copied link from website to extract the build ID and pass to downloadURL to get the raw build XML
-- downloadURL: The URL to download the raw build code
-- codeOut: Gets prepended to returned code from postUrl.  Needed to enable export in ImportTab
-- postUrl: The URL to upload a build code.  Needed to enable export in ImportTab
-- postFields: The POST fields prepended to base64-encoded XML.  Needed to enable export in ImportTab
-- linkURL: The URL pattern to link to the provided build code (Unused currently)
buildSites.websiteList = {
	{
		label = "Maxroll", id = "Maxroll", matchURL = "^https://maxroll%.gg/poe/pob/.*", regexURL = "maxroll%.gg/poe/pob/(.+)%s*$", downloadURL = "maxroll%.gg/poe/api/pob/%1",
		codeOut = "https://maxroll.gg/poe/pob/", postUrl = "https://maxroll.gg/poe/api/pob", postFields = "pobCode=", linkURL = "maxroll%.gg/poe/pob/%1"
	},
	{
		label = "pob.codes", id = "PoBCodes", matchURL = "^https://pob%.codes/b/.+", regexURL = "pob%.codes/b/(.+)%s*$", downloadURL = "api.pob.codes/%1/raw",
		codeOut = "https://pob.codes/b/", postUrl = "https://api.pob.codes/pob/plain", postFields = "", linkURL = "pob.codes/b/%1"
	},
	{
		label = "pobb.in", id = "POBBin", matchURL = "^https://pobb%.in/.+", regexURL = "pobb%.in/(.+)%s*$", downloadURL = "pobb.in/pob/%1",
		codeOut = "https://pobb.in/", postUrl = "https://pobb.in/pob/", postFields = "", linkURL = "pobb.in/%1"
	},
	{
		label = "PoeNinja", id = "PoeNinja", matchURL = "^https://poe%.ninja/?p?o?e?1?/pob/%w+", regexURL = "poe%.ninja/?p?o?e?1?/pob/(%w+)%s*$", downloadURL = "poe.ninja/poe1/pob/raw/%1",
		codeOut = "", postUrl = "https://poe.ninja/poe1/pob/api/upload", postFields = "code=", linkURL="poe.ninja/poe1/pob/%1"
	},
	{
		label = "Pastebin.com", id = "pastebin", matchURL = "^https://pastebin%.com/%w+", regexURL = "pastebin%.com/(%w+)%s*$", downloadURL = "pastebin.com/raw/%1", linkURL = "pastebin.com/%1"
	},
	{ label = "PastebinP.com", id = "pastebinProxy", matchURL = "^https://pastebinp%.com/%w+", regexURL = "pastebinp%.com/(%w+)%s*$", downloadURL = "pastebinp.com/raw/%1", linkURL = "pastebin.com/%1" },
	{ label = "Rentry.co", id = "rentry", matchURL = "^https://rentry%.co/%w+", regexURL = "rentry%.co/(%w+)%s*$", downloadURL = "rentry.co/paste/%1/raw", linkURL = "rentry.co/%1" },
	{ label = "poedb.tw", id = "PoEDB", matchURL = "^https://poedb%.tw/.+", regexURL = "poedb%.tw/pob/(.+)%s*$", downloadURL = "poedb.tw/pob/%1/raw", codeOut = "", postUrl = "https://poedb.tw/pob/api/gen", postFields = "", linkURL = "poedb.tw/pob/%1" },
}

--- Uploads a PoB build code to a website
--- @param websiteInfo table Contains the postUrl, any postParams, and a prefix to add to the response
--- @param buildCode string The build code that will be uploaded
function buildSites.UploadBuild(buildCode, websiteInfo)
	local response
	if websiteInfo then
		response = LaunchSubScript([[
			local code, connectionProtocol, proxyURL = ...
			local curl = require("lcurl.safe")
			local page = ""
			local easy = curl.easy()
			easy:setopt_url(']]..websiteInfo.postUrl..[[')
			easy:setopt(curl.OPT_POST, true)
			easy:setopt(curl.OPT_USERAGENT, "Path of Building/]]..launch.versionNumber..[[")
			easy:setopt(curl.OPT_POSTFIELDS, ']]..websiteInfo.postFields..[['..code)
			easy:setopt(curl.OPT_ACCEPT_ENCODING, "")
			easy:setopt(curl.OPT_FOLLOWLOCATION, 1)
			if connectionProtocol then
				easy:setopt(curl.OPT_IPRESOLVE, connectionProtocol)
			end
			if proxyURL then
				easy:setopt(curl.OPT_PROXY, proxyURL)
			end
			easy:setopt_writefunction(function(data)
				page = page..data
				return true
			end)
			easy:perform()
			local res = easy:getinfo_response_code()
			easy:close()
			if (res == 200) then
				return page
			else
				return nil, page
			end
		]], "", "", buildCode, launch.connectionProtocol, launch.proxyURL)
	end
	return response
end

-- Resolve only provider entries defined by the native allowlist.
local function nativeProviderById(providerId)
	for _, siteInfo in ipairs(buildSites.websiteList) do
		if siteInfo.id == providerId then return siteInfo end
	end
end

-- Resolve against PoB's fixed provider allowlist. Caller-supplied provider
-- tables are never trusted for regexes or destination hosts.
--- @param link string A provider URL or a supported pob:// protocol URI
--- @param websiteInfo table? Native provider entry selected by the caller
--- @return string? resolved URL, string? resolution error, table? native provider
function buildSites.ResolveDownloadURL(link, websiteInfo)
	if type(link) ~= "string" or #link == 0 or #link > 4096 or link:find("[%c]") then
		return nil, "Invalid build link"
	end
	local provider, siteCodeURL
	if websiteInfo == nil then
		-- Protocol-handler calls are accepted only when the URI names a native
		-- provider; the destination host always comes from websiteList.
		for _, siteInfo in ipairs(buildSites.websiteList) do
			local pattern = "^pob:[/\\\\]*" .. siteInfo.id:lower() .. "[/\\\\]+(.+)"
			if link:match(pattern) then
				provider = siteInfo
				siteCodeURL = link:gsub(pattern, "https://" .. siteInfo.downloadURL)
				break
			end
		end
		if not provider then return nil, "Download information not found" end
	else
		provider = type(websiteInfo) == "table" and nativeProviderById(websiteInfo.id) or nil
		if not provider then return nil, "Download information not found" end
		if type(provider.matchURL) ~= "string" or not link:match(provider.matchURL) then
			return nil, "Link does not match selected provider"
		end
		if provider.id == "POBBin" and link:match("^https://pobb%.in/u/") then
			-- Profile pages use /u/<profile>/<build>, while PoBB's raw export
			-- endpoint uses /pob/<profile>:<build>. Keep encoded profile
			-- discriminators such as %23 intact.
			local profile, buildId = link:match("^https://pobb%.in/u/([^/?#]+)/([^/?#]+)/?$")
			if not profile or not buildId then return nil, "Invalid PoBB profile build URL" end
			siteCodeURL = "https://pobb.in/pob/" .. profile .. ":" .. buildId
		else
			local replacements
			siteCodeURL, replacements = link:gsub(provider.regexURL, provider.downloadURL)
			if replacements ~= 1 or siteCodeURL == link then
				return nil, "Invalid link for selected provider"
			end
		end
	end
	return siteCodeURL, nil, provider
end

--- Downloads a PoB build code from an allowlisted website.
--- @param link string A supported provider URL or pob:// protocol URI
--- @param websiteInfo table? Native provider entry; nil for protocol-handler links
--- @param callback function Receives success, body/error, and resolved URL
--- @param options table? Internal download options; followRedirects defaults to true
function buildSites.DownloadBuild(link, websiteInfo, callback, options)
	if type(callback) ~= "function" then return nil, "Download callback is required" end
	options = type(options) == "table" and options or { }
	local siteCodeURL, resolveError = buildSites.ResolveDownloadURL(link, websiteInfo)
	if not siteCodeURL then
		callback(false, resolveError, nil)
		return
	end
	local completed = false
	local function finish(success, data, reason)
		if completed then return end
		completed = true
		callback(success, data, siteCodeURL, reason)
	end
	local function onDownload(response, errMsg)
		if errMsg then
			local responseCode = tonumber(tostring(errMsg):match("^Response code: (%d+)$"))
			if options.followRedirects == false and responseCode and responseCode >= 300 and responseCode < 400 then
				finish(false, "Optimizer study imports do not follow redirects; use the provider's canonical PoB URL or a local PoB export", "redirect_disallowed")
				return
			end
			if errMsg == "Response exceeded maximum allowed size" then
				finish(false, "Build download exceeds the size limit", "download_too_large")
			else
				finish(false, errMsg, "download_failed")
			end
		elseif type(response) ~= "table" or type(response.body) ~= "string" or response.body == "" then
			finish(false, "Build provider returned no usable export", "download_invalid_response")
		elseif #response.body > MAX_BUILD_CODE_BYTES then
			finish(false, "Build download exceeds the size limit", "download_too_large")
		else
			finish(true, response.body)
		end
	end
	local ok, requestId = pcall(launch.DownloadPage, launch, siteCodeURL, onDownload,
		{ maxResponseBytes = MAX_BUILD_CODE_BYTES, followRedirects = options.followRedirects ~= false })
	if not ok then
		finish(false, "Unable to start build download", "download_start_failed")
	elseif not completed and not requestId then
		finish(false, "Unable to start build download", "download_start_failed")
	end
end

-- Parses and converts URI's to import links. Currently only supports protocol handler URI's, extend as needed.
-- @param uri string Example: pob://pobbin/<id> or pob://poeninja/<id>
function buildSites.ParseImportLinkFromURI(uri)
	local importLink = nil

	-- Check if it's an URI from protocol handler
	for _, siteInfo in ipairs(buildSites.websiteList) do
		if uri:match("^pob:[/\\]*" .. siteInfo.id:lower() .. "[/\\]+(.+)") then
			importLink = uri:gsub("^pob:[/\\]*" .. siteInfo.id:lower() .. "[/\\]+(.+)", "https://" .. siteInfo.linkURL)
			break
		end
	end

	return importLink
end
