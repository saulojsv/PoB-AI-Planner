-- Path of Building
--
-- Module: non-blocking-per-frame local JSON-RPC 2.0 named-pipe client.
-- It is optional; missing daemon/runtime returns a fallback status.

local ipc = { }
local json = require("dkjson")
local requestId = 0
local ffiState

local function runtimeDirectory()
	local localAppData = os.getenv("LOCALAPPDATA")
	if type(localAppData) ~= "string" or localAppData == "" then return nil end
	return localAppData .. "\\PathOfBuilding\\AIPlanner"
end

local function readEndpoint()
	local directory = runtimeDirectory()
	if not directory then return nil, "private_runtime_path_unavailable" end
	local file = io.open(directory .. "\\endpoint.json", "rb")
	if not file then return nil, "daemon_not_running" end
	local contents = file:read(8192)
	file:close()
	if not contents then return nil, "endpoint_unreadable" end
	local ok, endpoint = pcall(json.decode, contents)
	local pipePrefix = "\\\\.\\pipe\\pob-ai-planner-"
	if not ok or type(endpoint) ~= "table" or endpoint.protocol ~= "windows_named_pipe"
		or type(endpoint.address) ~= "string" or endpoint.address:sub(1, #pipePrefix) ~= pipePrefix
		or not endpoint.address:sub(#pipePrefix + 1):match("^[%da-f]+$")
		or type(endpoint.authToken) ~= "string" or #endpoint.authToken < 32 then
		return nil, "endpoint_invalid"
	end
	return endpoint
end

local function loadWinApi()
	if ffiState then return ffiState end
	if not jit or jit.os ~= "Windows" then return nil, "named_pipe_client_unavailable" end
	local ok, ffi = pcall(require, "ffi")
	if not ok then return nil, "ffi_unavailable" end
	pcall(ffi.cdef, [[
	typedef void * POB_HANDLE;
	typedef unsigned long POB_DWORD;
	typedef int POB_BOOL;
	POB_BOOL __stdcall WaitNamedPipeW(const unsigned short *name, POB_DWORD timeout);
	POB_HANDLE __stdcall CreateFileW(const unsigned short *name, POB_DWORD access, POB_DWORD share,
		void *security, POB_DWORD creation, POB_DWORD flags, POB_HANDLE templateHandle);
	POB_BOOL __stdcall PeekNamedPipe(POB_HANDLE handle, void *buffer, POB_DWORD bufferSize,
		POB_DWORD *bytesRead, POB_DWORD *bytesAvailable, POB_DWORD *bytesLeftThisMessage);
	POB_BOOL __stdcall ReadFile(POB_HANDLE handle, void *buffer, POB_DWORD bytesToRead,
		POB_DWORD *bytesRead, void *overlapped);
	POB_BOOL __stdcall WriteFile(POB_HANDLE handle, const void *buffer, POB_DWORD bytesToWrite,
		POB_DWORD *bytesWritten, void *overlapped);
	POB_BOOL __stdcall CloseHandle(POB_HANDLE handle);
	]])
	local loaded, kernel = pcall(ffi.load, "kernel32")
	if not loaded then return nil, "kernel32_unavailable" end
	ffiState = { ffi = ffi, kernel = kernel }
	return ffiState
end

local function wideAscii(ffi, value)
	local buffer = ffi.new("unsigned short[?]", #value + 1)
	for index = 1, #value do buffer[index - 1] = value:byte(index) end
	buffer[#value] = 0
	return buffer
end

local Client = { }
Client.__index = Client

function ipc.Connect()
	local endpoint, endpointError = readEndpoint()
	if not endpoint then return nil, endpointError end
	local state, apiError = loadWinApi()
	if not state then return nil, apiError end
	local ffi, kernel = state.ffi, state.kernel
	local name = wideAscii(ffi, endpoint.address)
	if kernel.WaitNamedPipeW(name, 0) == 0 then return nil, "daemon_pipe_unavailable" end
	local handle = kernel.CreateFileW(name, 0xC0000000, 0, nil, 3, 0, nil)
	if handle == nil or handle == ffi.cast("POB_HANDLE", -1) then return nil, "daemon_pipe_connect_failed" end
	return setmetatable({ ffi = ffi, kernel = kernel, handle = handle, token = endpoint.authToken,
		readBuffer = "", closed = false }, Client)
end

function Client:Close()
	if self.closed then return end
	self.closed = true
	if self.handle then self.kernel.CloseHandle(self.handle); self.handle = nil end
end

function Client:readAvailable()
	local ffi = self.ffi
	local available = ffi.new("POB_DWORD[1]")
	if self.kernel.PeekNamedPipe(self.handle, nil, 0, nil, available, nil) == 0 then
		return nil, "daemon_pipe_disconnected"
	end
	if available[0] == 0 then return "" end
	local count = math.min(available[0], 16384)
	local buffer = ffi.new("char[?]", count)
	local read = ffi.new("POB_DWORD[1]")
	if self.kernel.ReadFile(self.handle, buffer, count, read, nil) == 0 or read[0] == 0 then
		return nil, "daemon_pipe_read_failed"
	end
	return ffi.string(buffer, read[0])
end

local function extractLine(self)
	local newline = self.readBuffer:find("\n", 1, true)
	if not newline then return nil end
	local line = self.readBuffer:sub(1, newline - 1):gsub("\r$", "")
	self.readBuffer = self.readBuffer:sub(newline + 1)
	return line
end

function Client:Call(method, params, control, job, timeoutSeconds)
	requestId = requestId + 1
	local id = requestId
	params = params or { }
	params.authToken = self.token
	local encoded, encodeError = json.encode({ jsonrpc = "2.0", id = id, method = method, params = params })
	if type(encoded) ~= "string" then return nil, "request_encode_failed: " .. tostring(encodeError) end
	if #encoded > 16 * 1024 * 1024 then return nil, "request_too_large" end
	local outgoing = encoded .. "\n"
	local offset = 1
	local started = os.clock()
	while true do
		if control and control.cancelled then return nil, "cancelled" end
		if os.clock() - started > (timeoutSeconds or 300) then return nil, "ipc_timeout" end
		if offset <= #outgoing then
			local length = math.min(8192, #outgoing - offset + 1)
			local chunk = outgoing:sub(offset, offset + length - 1)
			local buffer = self.ffi.new("char[?]", #chunk)
			self.ffi.copy(buffer, chunk, #chunk)
			local written = self.ffi.new("POB_DWORD[1]")
			if self.kernel.WriteFile(self.handle, buffer, #chunk, written, nil) == 0 then return nil, "daemon_pipe_write_failed" end
			if written[0] > 0 then offset = offset + written[0] end
		else
			local line = extractLine(self)
			if line then
				local ok, response = pcall(json.decode, line)
				if ok and type(response) == "table" and response.id == id then
					if response.error then return nil, tostring(response.error.message or "JSON-RPC error"), response.error.code end
					return response.result
				end
			else
				local incoming, readError = self:readAvailable()
				if incoming == nil then return nil, readError end
				if incoming ~= "" then self.readBuffer = self.readBuffer .. incoming end
			end
		end
		if job then
			job.progress = job.progress or { phase = "Local GNN IPC", processed = 0, total = 1 }
			coroutine.yield(job.progress)
		end
	end
end

function ipc.ReadEndpoint()
	local endpoint, err = readEndpoint()
	if not endpoint then return false, err end
	return true, endpoint
end

return ipc
