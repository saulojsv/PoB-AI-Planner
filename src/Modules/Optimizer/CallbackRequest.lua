-- Pure request-line parser for the loopback OAuth callback.
-- It accepts origin-form requests and the equivalent absolute-form only when
-- the authority is the exact IPv4 loopback listener that PoB opened.
local callbackRequest = { }

function callbackRequest.ParseRequestLine(requestLine, port)
	if type(requestLine) ~= "string" or #requestLine > 8192 then return nil, "invalid_request_line" end
	requestLine = requestLine:gsub("[\r\n]+$", "")
	local method, target, version = requestLine:match("^(%S+)%s+(%S+)%s+(HTTP/%d+%.%d+)$")
	if not method or not target or not version then return nil, "malformed_request_line" end

	if target:find("#", 1, true) or target:find("[%c%s]") then return nil, "invalid_target" end
	local scheme, absoluteTarget = target:match("^([%a]+)://(.*)$")
	if scheme then
		if scheme:lower() ~= "http" then return nil, "unsupported_scheme" end
		local authority, rest = absoluteTarget:match("^([^/]+)(/.*)$")
		if not authority or authority:lower() ~= ("127.0.0.1:" .. tostring(port)):lower() then
			return nil, "authority_mismatch"
		end
		target = rest
	elseif target:sub(1, 1) ~= "/" then
		return nil, "unsupported_target_form"
	end

	local path, query = target:match("^([^?]+)%?(.*)$")
	if not path then path = target end
	return method, path, query
end

function callbackRequest.ParseQuery(query)
	if type(query) ~= "string" or #query > 8192 then return nil, "invalid_query" end
	local function decode(value)
		local searchFrom = 1
		while true do
			local escapeStart = value:find("%", searchFrom, true)
			if not escapeStart then break end
			local firstHex, secondHex = value:sub(escapeStart + 1, escapeStart + 1), value:sub(escapeStart + 2, escapeStart + 2)
			if not firstHex:match("%x") or not secondHex:match("%x") then return nil end
			searchFrom = escapeStart + 3
		end
		return (value:gsub("%+", " "):gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
	end
	local params = { }
	for pair in query:gmatch("[^&]+") do
		local rawKey, rawValue = pair:match("^([^=]+)=(.*)$")
		if not rawKey then return nil, "malformed_query_pair" end
		local key, value = decode(rawKey), decode(rawValue)
		if not key or not value or params[key] ~= nil then return nil, "invalid_or_duplicate_query_parameter" end
		params[key] = value
	end
	return params
end

function callbackRequest.ParseCallback(requestLine, port, expectedState)
	local method, path, query = callbackRequest.ParseRequestLine(requestLine, port)
	if not method then return nil, "invalid_request_line" end
	if method ~= "GET" or path ~= "/auth/callback" then return nil, "not_callback", method, path end
	if query == nil then return nil, "missing_query" end
	local params, queryError = callbackRequest.ParseQuery(query)
	if not params then return nil, queryError or "invalid_query" end
	if params.state ~= expectedState then return nil, "state_mismatch" end
	if params.error then
		return { state = params.state, clientId = params.client_id, scope = params.scope,
			error = params.error_description or params.error }
	end
	if not params.code or params.code == "" then return nil, "missing_code" end
	return { code = params.code, state = params.state, clientId = params.client_id, scope = params.scope }
end

-- Safe operational diagnostics for the callback listener. Never include the
-- query string, arbitrary path segments, authority, or OAuth values in logs.
function callbackRequest.DescribeRequestSafely(requestLine, port)
	local method, path = callbackRequest.ParseRequestLine(requestLine, port)
	if not method then
		local reason = type(path) == "string" and path:match("^[a-z_]+$") and path or "invalid_request"
		return "invalid request (" .. reason .. ")"
	end
	local safeMethod = ({ GET = true, HEAD = true, POST = true, OPTIONS = true })[method] and method or "other-method"
	local safePath = path == "/auth/callback" and path or path == "/favicon.ico" and path or "other-path"
	return safeMethod .. " " .. safePath
end

return callbackRequest
