-- One-shot loopback callback for Sign in with ChatGPT.
-- Bound to IPv4 loopback only; the authorization values are not logged.

local state, requestedClientId, authUrlTemplate = ...
local socket = require("socket")
local CallbackRequest = require("Modules.Optimizer.CallbackRequest")
local server = socket.tcp4()
server:setoption("reuseaddr", true)
local bound, bindError = server:bind("127.0.0.1", 0)
if not bound then
	server:close()
	return nil, "Could not bind the local ChatGPT callback: " .. tostring(bindError)
end
local listened, listenError = server:listen(1)
if not listened then
	server:close()
	return nil, "Could not listen for the local ChatGPT callback: " .. tostring(listenError)
end
local host, port = server:getsockname()
if host ~= "127.0.0.1" or not port then
	server:close()
	return nil, "The local ChatGPT callback did not bind to IPv4 loopback"
end

local authUrl = authUrlTemplate:gsub("__PORT__", tostring(port))
OpenURL(authUrl)

local function sendPage(client, status, title, message)
	local body = "<!doctype html><html><head><meta charset=\"utf-8\"><title>" .. title .. "</title></head>" ..
		"<body style=\"font-family:Arial,sans-serif;background:#151515;color:#eee;margin:3em\"><h2>" .. title .. "</h2><p>" .. message .. "</p></body></html>"
	client:send("HTTP/1.1 " .. status .. "\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body)
end

local deadline = os.time() + 300
local callbackCode, callbackError, callbackState, callbackClientId, callbackScope
while os.time() < deadline and not callbackCode and not callbackError do
	server:settimeout(math.min(5, math.max(1, deadline - os.time())))
	local client = server:accept()
	if client then
		client:settimeout(5)
		local peer = client:getpeername()
		local request = client:receive("*l")
		if peer == "127.0.0.1" and request and #request <= 8192 then
			local callback, callbackReason, method, path = CallbackRequest.ParseCallback(request, port, state)
			if callback then
				callbackState = callback.state
				callbackClientId = callback.clientId or requestedClientId
				callbackScope = callback.scope
				if callback.error then
					callbackError = callback.error
					sendPage(client, "200 OK", "ChatGPT sign-in was not completed", "Return to Path of Building and review the sign-in status.")
				else
					callbackCode = callback.code
					sendPage(client, "200 OK", "ChatGPT sign-in received", "Return to Path of Building. The app is validating the authorization.")
				end
			elseif callbackReason == "not_callback" and method == "GET" and path == "/favicon.ico" then
				sendPage(client, "404 Not Found", "Not found", "")
			elseif callbackReason == "not_callback" then
				ConPrintf("Ignored unrelated local request during ChatGPT sign-in: %s", CallbackRequest.DescribeRequestSafely(request, port))
				sendPage(client, "404 Not Found", "Sign-in callback not recognized", "Return to the same Path of Building window that started sign-in. If it does not finish, close this tab and restart sign-in from that window.")
			elseif callbackReason == "state_mismatch" then
				ConPrintf("Ignored ChatGPT callback with mismatched OAuth state")
				sendPage(client, "400 Bad Request", "ChatGPT callback did not match this sign-in", "This callback belongs to a different or expired sign-in. Return to the Path of Building window that started sign-in; if needed, close this tab and start again there.")
			else
				sendPage(client, "400 Bad Request", "Invalid ChatGPT callback", "Return to Path of Building and try again.")
			end
		else
			sendPage(client, "403 Forbidden", "Forbidden", "This endpoint accepts only a local browser callback.")
		end
		client:close()
	end
end

server:close()
if not callbackCode and not callbackError then callbackError = "Timed out waiting for ChatGPT authorization" end
return callbackCode, callbackError, callbackState, callbackClientId, callbackScope, port
