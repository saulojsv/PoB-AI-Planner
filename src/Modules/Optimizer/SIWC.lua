-- Path of Building
--
-- Sign in with ChatGPT for the native AI Planner. Credentials are encrypted with
-- Windows DPAPI and never written to Settings.xml or a plaintext sidecar file.
-- The integration fails closed on platforms without this protected store.

local AuthClass = newClass("OptimizerSIWC")
local base64 = require("base64")
local dkjson = require("dkjson")
local sha = require("sha2")
local ffiOk, ffi = pcall(require, "ffi")

local AUTH_ENDPOINT = "https://auth.openai.com/api/accounts/authorize"
local TOKEN_ENDPOINT = "https://auth.openai.com/api/accounts/oauth/token"
local JWKS_ENDPOINT = "https://auth.openai.com/.well-known/jwks.json"
local API_RESOURCE = "https://api.openai.com/v1"
local REQUIRED_SCOPES = { "openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct" }
local CREDENTIAL_FILE = "AIPlannerChat.dat"
local DPAPI_ENTROPY = "Path of Building Community AI Planner credentials v1"

local winCrypto

local function isWindows()
	return ffiOk and ffi.os == "Windows"
end

local function loadWinCrypto()
	if winCrypto then return winCrypto end
	if not isWindows() then return nil, "Protected ChatGPT sign-in is currently available on Windows only" end
	local ok, err = pcall(ffi.cdef, [[
		typedef unsigned char POB_BYTE;
		typedef unsigned long POB_ULONG;
		typedef unsigned long POB_DWORD;
		typedef int POB_BOOL;
		typedef void *POB_HANDLE;
		typedef struct { POB_DWORD cbData; POB_BYTE *pbData; } POB_DATA_BLOB;
		typedef struct {
			POB_ULONG Magic;
			POB_ULONG BitLength;
			POB_ULONG cbPublicExp;
			POB_ULONG cbModulus;
			POB_ULONG cbPrime1;
			POB_ULONG cbPrime2;
		} POB_BCRYPT_RSAKEY_BLOB;
		typedef struct { const wchar_t *pszAlgId; } POB_BCRYPT_PKCS1_PADDING_INFO;
		POB_ULONG BCryptGenRandom(POB_HANDLE, POB_BYTE *, POB_ULONG, POB_ULONG);
		POB_ULONG BCryptOpenAlgorithmProvider(POB_HANDLE *, const wchar_t *, const wchar_t *, POB_ULONG);
		POB_ULONG BCryptImportKeyPair(POB_HANDLE, POB_HANDLE, const wchar_t *, POB_HANDLE *, POB_BYTE *, POB_ULONG, POB_ULONG);
		POB_ULONG BCryptVerifySignature(POB_HANDLE, void *, POB_BYTE *, POB_ULONG, POB_BYTE *, POB_ULONG, POB_ULONG);
		POB_ULONG BCryptDestroyKey(POB_HANDLE);
		POB_ULONG BCryptCloseAlgorithmProvider(POB_HANDLE, POB_ULONG);
		POB_BOOL CryptProtectData(POB_DATA_BLOB *, const wchar_t *, POB_DATA_BLOB *, void *, void *, POB_DWORD, POB_DATA_BLOB *);
		POB_BOOL CryptUnprotectData(POB_DATA_BLOB *, wchar_t **, POB_DATA_BLOB *, void *, void *, POB_DWORD, POB_DATA_BLOB *);
		void *LocalFree(void *);
		int MultiByteToWideChar(unsigned int, POB_DWORD, const char *, int, wchar_t *, int);
		POB_BOOL MoveFileExW(const wchar_t *, const wchar_t *, POB_DWORD);
		POB_DWORD GetLastError(void);
	]])
	if not ok then return nil, tostring(err) end
	local loaded, bcrypt = pcall(ffi.load, "bcrypt.dll")
	if not loaded then return nil, "Windows CNG cryptography is unavailable" end
	local cryptLoaded, crypt32 = pcall(ffi.load, "crypt32.dll")
	local kernelLoaded, kernel32 = pcall(ffi.load, "kernel32.dll")
	if not cryptLoaded or not kernelLoaded then return nil, "Windows protected credential storage is unavailable" end
	winCrypto = { bcrypt = bcrypt, crypt32 = crypt32, kernel32 = kernel32 }
	return winCrypto
end

local function utf8ToWide(text)
	local crypto, err = loadWinCrypto()
	if not crypto then return nil, err end
	local needed = crypto.kernel32.MultiByteToWideChar(65001, 0, text, #text, nil, 0)
	if needed <= 0 then return nil, "Could not convert the credential path for Windows" end
	local output = ffi.new("wchar_t[?]", needed + 1)
	if crypto.kernel32.MultiByteToWideChar(65001, 0, text, #text, output, needed) <= 0 then
		return nil, "Could not convert the credential path for Windows"
	end
	output[needed] = 0
	return output
end

local function randomBytes(count)
	local crypto, err = loadWinCrypto()
	if not crypto then return nil, err end
	local bytes = ffi.new("POB_BYTE[?]", count)
	local status = crypto.bcrypt.BCryptGenRandom(nil, bytes, count, 0x00000002) -- system-preferred CSPRNG
	if status ~= 0 then return nil, "Windows secure random generator failed" end
	return ffi.string(bytes, count)
end

local function base64UrlEncode(text)
	return base64.encode(text):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", "")
end

local function base64UrlDecode(text)
	if type(text) ~= "string" or not text:match("^[%w_%-]*$") then return nil end
	local value = text:gsub("-", "+"):gsub("_", "/")
	local remainder = #value % 4
	if remainder == 1 then return nil end
	if remainder > 0 then value = value .. string.rep("=", 4 - remainder) end
	return base64.decode(value)
end

local function uuidV4()
	local raw, err = randomBytes(16)
	if not raw then return nil, err end
	local bytes = { raw:byte(1, 16) }
	bytes[7] = bytes[7] % 16 + 64
	bytes[9] = bytes[9] % 64 + 128
	local hex = { }
	for index, byte in ipairs(bytes) do hex[index] = string.format("%02x", byte) end
	local all = table.concat(hex)
	return "urn:uuid:" .. all:sub(1, 8) .. "-" .. all:sub(9, 12) .. "-" .. all:sub(13, 16) .. "-" .. all:sub(17, 20) .. "-" .. all:sub(21)
end

local function urlEncode(text)
	return (tostring(text):gsub("([^%w%-%._~])", function(char) return string.format("%%%02X", char:byte()) end))
end

local function protect(text)
	local crypto, err = loadWinCrypto()
	if not crypto then return nil, err end
	local inputText, entropyText = text, DPAPI_ENTROPY
	local input = ffi.new("POB_DATA_BLOB[1]")
	local entropy = ffi.new("POB_DATA_BLOB[1]")
	local output = ffi.new("POB_DATA_BLOB[1]")
	input[0].cbData, input[0].pbData = #inputText, ffi.cast("POB_BYTE *", ffi.cast("const char *", inputText))
	entropy[0].cbData, entropy[0].pbData = #entropyText, ffi.cast("POB_BYTE *", ffi.cast("const char *", entropyText))
	if crypto.crypt32.CryptProtectData(input, nil, entropy, nil, nil, 0x1, output) == 0 then
		return nil, "Windows could not encrypt the ChatGPT credentials"
	end
	local protectedText = ffi.string(output[0].pbData, output[0].cbData)
	crypto.kernel32.LocalFree(output[0].pbData)
	return protectedText
end

local function unprotect(cipherText)
	local crypto, err = loadWinCrypto()
	if not crypto then return nil, err end
	local inputText, entropyText = cipherText, DPAPI_ENTROPY
	local input = ffi.new("POB_DATA_BLOB[1]")
	local entropy = ffi.new("POB_DATA_BLOB[1]")
	local output = ffi.new("POB_DATA_BLOB[1]")
	input[0].cbData, input[0].pbData = #inputText, ffi.cast("POB_BYTE *", ffi.cast("const char *", inputText))
	entropy[0].cbData, entropy[0].pbData = #entropyText, ffi.cast("POB_BYTE *", ffi.cast("const char *", entropyText))
	if crypto.crypt32.CryptUnprotectData(input, nil, entropy, nil, nil, 0x1, output) == 0 then
		return nil, "The encrypted ChatGPT credentials could not be opened for this Windows user"
	end
	local plainText = ffi.string(output[0].pbData, output[0].cbData)
	crypto.kernel32.LocalFree(output[0].pbData)
	return plainText
end

local function verifyRS256(signingInput, signature, key)
	local crypto, err = loadWinCrypto()
	if not crypto then return false, err end
	if type(key) ~= "table" or key.kty ~= "RSA" or (key.alg and key.alg ~= "RS256") or (key.use and key.use ~= "sig") then
		return false, "The selected OpenAI signing key is not an RS256 signing key"
	end
	local modulus, exponent = base64UrlDecode(key.n), base64UrlDecode(key.e)
	if not modulus or not exponent or #modulus < 256 or #modulus > 1024 or #exponent > 8 then
		return false, "The OpenAI signing key has invalid RSA parameters"
	end
	if #signature ~= #modulus then return false, "The OpenAI ID token signature length is invalid" end
	local rsaName, rsaNameError = utf8ToWide("RSA")
	local publicBlobName, publicBlobNameError = utf8ToWide("RSAPUBLICBLOB")
	local shaName, shaNameError = utf8ToWide("SHA256")
	if not rsaName or not publicBlobName or not shaName then
		return false, rsaNameError or publicBlobNameError or shaNameError or "Windows could not prepare RSA verification"
	end
	local algorithm = ffi.new("POB_HANDLE[1]")
	local status = crypto.bcrypt.BCryptOpenAlgorithmProvider(algorithm, ffi.cast("const wchar_t *", rsaName), nil, 0)
	if status ~= 0 then return false, "Windows could not open the RSA verifier" end
	local keyHandle = ffi.new("POB_HANDLE[1]")
	local header = ffi.new("POB_BCRYPT_RSAKEY_BLOB[1]")
	header[0].Magic = 0x31415352 -- BCRYPT_RSAPUBLIC_MAGIC / RSA1
	header[0].BitLength = #modulus * 8
	header[0].cbPublicExp = #exponent
	header[0].cbModulus = #modulus
	local headerSize = ffi.sizeof("POB_BCRYPT_RSAKEY_BLOB")
	local blob = ffi.new("POB_BYTE[?]", headerSize + #exponent + #modulus)
	ffi.copy(blob, header, headerSize)
	ffi.copy(blob + headerSize, exponent, #exponent)
	ffi.copy(blob + headerSize + #exponent, modulus, #modulus)
	status = crypto.bcrypt.BCryptImportKeyPair(algorithm[0], nil, ffi.cast("const wchar_t *", publicBlobName), keyHandle, blob, headerSize + #exponent + #modulus, 0)
	if status ~= 0 then
		crypto.bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0)
		return false, "Windows could not import the OpenAI RSA signing key"
	end
	local digest = sha.hex_to_bin(sha.sha256(signingInput))
	local digestBytes = ffi.new("POB_BYTE[?]", #digest)
	ffi.copy(digestBytes, digest, #digest)
	local signatureBytes = ffi.new("POB_BYTE[?]", #signature)
	ffi.copy(signatureBytes, signature, #signature)
	local paddingInfo = ffi.new("POB_BCRYPT_PKCS1_PADDING_INFO[1]")
	paddingInfo[0].pszAlgId = shaName
	status = crypto.bcrypt.BCryptVerifySignature(keyHandle[0], paddingInfo, digestBytes, #digest,
	signatureBytes, #signature, 0x00000002) -- BCRYPT_PAD_PKCS1
	crypto.bcrypt.BCryptDestroyKey(keyHandle[0])
	crypto.bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0)
	return status == 0, status == 0 and nil or "The OpenAI ID token signature is invalid"
end

local function atomicWrite(path, bytes)
	local tempPath = path .. ".tmp"
	local file, openError = io.open(tempPath, "wb")
	if not file then return false, "Could not create encrypted credential file: " .. tostring(openError) end
	local ok, writeError = file:write(bytes)
	file:close()
	if not ok then os.remove(tempPath) return false, "Could not write encrypted credential file: " .. tostring(writeError) end
	local fromWide, fromError = utf8ToWide(tempPath)
	local toWide, toError = utf8ToWide(path)
	local crypto, cryptoError = loadWinCrypto()
	if not crypto or not fromWide or not toWide then
		os.remove(tempPath)
		return false, cryptoError or fromError or toError or "Protected credential storage is unavailable"
	end
	if crypto.kernel32.MoveFileExW(fromWide, toWide, 0x1 + 0x8) == 0 then -- replace existing, write through
		local errorCode = crypto.kernel32.GetLastError()
		os.remove(tempPath)
		return false, "Could not atomically replace encrypted credentials (Windows error " .. tostring(errorCode) .. ")"
	end
	return true
end

local function prepareCredentialStorage(appData, createDirectory)
	if type(appData) ~= "string" or appData == "" then
		return nil, "Windows Local AppData is unavailable for protected ChatGPT credential storage"
	end
	createDirectory = createDirectory or MakeDir
	local root = appData
	while root:sub(-1) == "/" or root:sub(-1) == "\\" do
		root = root:sub(1, -2)
	end
	local parentDirectory = root .. "\\Path of Building Community\\"
	local credentialDirectory = parentDirectory .. "AI Planner\\"
	-- MakeDir creates one directory level at a time in the native runtime. Build the
	-- hierarchy explicitly because LocalAppData normally has no PoB-owned parent.
	for _, directory in ipairs({ parentDirectory, credentialDirectory }) do
		local created, createError = createDirectory(directory)
		-- Match the native PoB convention: an existing directory may return
		-- (nil, "No error"), which is a successful ensure operation.
		if not created and createError ~= "No error" then
			return nil, "Could not create the protected AI Planner credential directory: " .. tostring(createError or "unknown error")
		end
	end
	return credentialDirectory .. CREDENTIAL_FILE
end

local function credentialStoragePath()
	return prepareCredentialStorage(os.getenv("LOCALAPPDATA"), MakeDir)
end

local function hasScope(scopes, wanted)
	if type(scopes) == "string" then
		for scope in scopes:gmatch("%S+") do if scope == wanted then return true end end
	elseif type(scopes) == "table" then
		for _, scope in ipairs(scopes) do if scope == wanted then return true end end
	end
	return false
end

local function responseError(body, errorMessage)
	local parsed = type(body) == "string" and dkjson.decode(body) or nil
	local nested = type(parsed) == "table" and parsed.error or nil
	local message = type(nested) == "table" and (nested.message or nested.code) or nil
		or (type(parsed) == "table" and (parsed.error_description or parsed.detail or parsed.message))
		or (type(nested) == "string" and nested)
		or (type(parsed) == "table" and (parsed.error_code or parsed.code))
	if type(message) == "string" then return message:sub(1, 240) end
	return tostring(errorMessage or "The OpenAI authorization request failed"):sub(1, 240)
end

local terminalRefreshErrors = {
	invalid_grant = true,
	invalid_refresh_token = true,
	token_expired = true,
	refresh_token_expired = true,
	refresh_token_invalidated = true,
	refresh_token_reused = true,
}

function AuthClass:OptimizerSIWC()
	self.record = { }
	self.status = "Sign in with ChatGPT is not connected"
	self.pending = nil
	self.callbackScriptId = nil
	self.modelListPending = false
	self.reauthorizationRequired = false
	self.storagePath = nil
	if isWindows() then self.storagePath, self.storagePathError = credentialStoragePath() end
	self:Load()
	return self
end

function AuthClass:Load()
	local crypto, err = loadWinCrypto()
	if not crypto then self.status = err or "Protected credential storage is unavailable" return false, self.status end
	if not self.storagePath then self.status = self.storagePathError or "Protected ChatGPT credential storage is unavailable" return false, self.status end
	local file = io.open(self.storagePath, "rb")
	if not file then
		local hostId, randomError = uuidV4()
		if not hostId then self.status = randomError return false, randomError end
		self.record = { hostId = hostId }
		local saved, saveError = self:Save()
		if not saved then self.status = saveError return false, saveError end
		return true
	end
	local encrypted = file:read("*a")
	file:close()
	local plain, decryptError = unprotect(encrypted or "")
	if not plain then self.status = decryptError return false, decryptError end
	local decoded, _, decodeError = dkjson.decode(plain)
	if type(decoded) ~= "table" or type(decoded.hostId) ~= "string" or not decoded.hostId:match("^urn:uuid:") then
		self.status = decodeError or "Encrypted ChatGPT credential record is invalid"
		return false, self.status
	end
	self.record = decoded
	self.reauthorizationRequired = type(decoded.credentials) == "table" and decoded.credentials.reauthorizationRequired == true or false
	self.status = decoded.credentials and ("Connected as " .. tostring(decoded.credentials.email or "ChatGPT account")) or "Sign in with ChatGPT is not connected"
	return true
end

function AuthClass:Save()
	if not self.storagePath then return false, "PoB user settings path is not ready" end
	local encoded, encodeError = dkjson.encode(self.record)
	if not encoded then return false, "Could not encode ChatGPT credentials: " .. tostring(encodeError) end
	local encrypted, encryptError = protect(encoded)
	if not encrypted then return false, encryptError end
	return atomicWrite(self.storagePath, encrypted)
end

function AuthClass:IsConnected()
	return type(self.record.credentials) == "table" and self.record.credentials.clientId ~= nil
end

function AuthClass:NeedsReauthorization()
	local credential = self.record and self.record.credentials
	if not self:IsConnected() then return false end
	return self.reauthorizationRequired == true
		or (type(credential) == "table" and credential.reauthorizationRequired == true)
		or type(credential.accessToken) ~= "string"
		or type(credential.refreshToken) ~= "string"
end

function AuthClass:RequireReauthorization(reason, clearTokens)
	local credential = self.record and self.record.credentials
	if type(credential) ~= "table" or type(credential.clientId) ~= "string" then return false, "No registered ChatGPT account is available to reconnect" end
	local oldAccess, oldRefresh, oldExpiry, oldFlag = credential.accessToken, credential.refreshToken, credential.expiresAt, credential.reauthorizationRequired
	local oldRequired = self.reauthorizationRequired
	if clearTokens then
		credential.accessToken = nil
		credential.refreshToken = nil
		credential.expiresAt = nil
	end
	credential.reauthorizationRequired = true
	self.reauthorizationRequired = true
	local saved, saveError = self:Save()
	if not saved then
		credential.accessToken, credential.refreshToken, credential.expiresAt, credential.reauthorizationRequired = oldAccess, oldRefresh, oldExpiry, oldFlag
		self.reauthorizationRequired = oldRequired or true
		self.reauthorizationReason = reason
		return false, saveError
	end
	self.reauthorizationReason = reason
	self.status = reason or "ChatGPT authorization needs attention; sign in again"
	return true
end

function AuthClass:GetStatus()
	if self.pending then return "Waiting for ChatGPT authorization in the browser" end
	if self:NeedsReauthorization() then return self.reauthorizationReason or "ChatGPT authorization needs attention; sign in again" end
	if self:IsConnected() then
		local account = self.record.credentials
		return "Connected as " .. tostring(account.email or "ChatGPT account")
	end
	return self.status
end

function AuthClass:GetAccountLabel()
	if not self:IsConnected() then return "Not connected" end
	return tostring(self.record.credentials.email or "ChatGPT account")
end

function AuthClass:BuildAuthorizeUrl(clientId, hostId, state, nonce, challenge, port, credential)
	local redirectUri = "http://127.0.0.1:" .. tostring(port) .. "/auth/callback"
	local params = {
		client_id = clientId,
		ext_agent_host_id = hostId,
		response_type = "code",
		redirect_uri = redirectUri,
		scope = table.concat(REQUIRED_SCOPES, " "),
		resource = API_RESOURCE,
		state = state,
		nonce = nonce,
		code_challenge_method = "S256",
		code_challenge = challenge,
	}
	if clientId == "dynamic_agent_client" then
		params.agent_name_hint = "Path of Building Community Fork AI Planner"
	elseif type(credential) == "table" then
		if type(credential.idToken) == "string" then params.id_token_hint = credential.idToken end
		if type(credential.email) == "string" then params.login_hint = credential.email end
	end
	local query = { }
	for key, value in pairs(params) do query[#query + 1] = urlEncode(key) .. "=" .. urlEncode(value) end
	table.sort(query)
	return AUTH_ENDPOINT .. "?" .. table.concat(query, "&"), redirectUri
end

local function makeCallbackScript()
	local file, err = io.open("LaunchServerSIWC.lua", "r")
	if not file then return nil, "Could not read the local ChatGPT callback server: " .. tostring(err) end
	local source = file:read("*a")
	file:close()
	return source
end

function AuthClass:Begin(callback)
	if self.pending then return false, "A ChatGPT sign-in is already in progress" end
	local hostId = self.record.hostId
	if type(hostId) ~= "string" then return false, "The stable ChatGPT host ID is missing" end
	local state, err = randomBytes(32)
	if not state then return false, err end
	local nonce, nonceError = randomBytes(32)
	if not nonce then return false, nonceError end
	local verifier, verifierError = randomBytes(32)
	if not verifier then return false, verifierError end
	local stateText, nonceText = base64UrlEncode(state), base64UrlEncode(nonce)
	local verifierText = base64UrlEncode(verifier)
	local challenge = base64UrlEncode(sha.hex_to_bin(sha.sha256(verifierText)))
	local credential = self:IsConnected() and self.record.credentials or nil
	local clientId = credential and credential.clientId or "dynamic_agent_client"
	local script, scriptError = makeCallbackScript()
	if not script then return false, scriptError end
	local authUrl = self:BuildAuthorizeUrl(clientId, hostId, stateText, nonceText, challenge, "__PORT__", credential)
	self.pending = { state = stateText, nonce = nonceText, verifier = verifierText, clientId = clientId, callback = callback }
	local id = LaunchSubScript(script, "", "ConPrintf,OpenURL", stateText, clientId, authUrl)
	if not id then self.pending = nil return false, "Could not start the loopback ChatGPT callback server" end
	self.callbackScriptId = id
	launch.subScripts[id] = { type = "DOWNLOAD", callback = function(code, errorMessage, returnedState, issuedClientId, grantedScope, port)
		self.callbackScriptId = nil
		local attempt = self.pending
		if not attempt then return end
		self.pending = nil
		if returnedState ~= nil and returnedState ~= attempt.state then
			self.status = "ChatGPT authorization was rejected because the OAuth state did not match"
			if attempt.callback then attempt.callback(false, self.status) end
			return
		end
		if errorMessage then
			self.status = tostring(errorMessage)
			if attempt.callback then attempt.callback(false, self.status) end
			return
		end
		if type(returnedState) ~= "string" then
			self.status = "ChatGPT authorization was rejected because the OAuth state did not match"
			if attempt.callback then attempt.callback(false, self.status) end
			return
		end
		if type(code) ~= "string" or code == "" then
			self.status = "ChatGPT authorization returned no authorization code"
			if attempt.callback then attempt.callback(false, self.status) end
			return
		end
		local issued = issuedClientId and issuedClientId ~= "" and issuedClientId or attempt.clientId
		if attempt.clientId == "dynamic_agent_client" and (not issued or issued == "dynamic_agent_client") then
			self.status = "The new ChatGPT registration did not return an issued client ID"
			if attempt.callback then attempt.callback(false, self.status) end
			return
		end
		if attempt.clientId ~= "dynamic_agent_client" and issued ~= attempt.clientId then
			self.status = "ChatGPT returned a different client ID than the selected account"
			if attempt.callback then attempt.callback(false, self.status) end
			return
		end
		self:ExchangeCode(attempt, code, issued, tonumber(port), callback)
	end }
	return true
end

function AuthClass:CancelSignIn()
	if self.callbackScriptId then
		AbortSubScript(self.callbackScriptId)
		self.callbackScriptId = nil
	end
	self.pending = nil
	self.status = "ChatGPT sign-in cancelled"
end

function AuthClass:ExchangeCode(attempt, code, clientId, port, callback)
	if not port or port < 1 or port > 65535 then
		self.status = "The loopback callback did not return a valid port"
		if callback then callback(false, self.status) end
		return
	end
	local redirectUri = "http://127.0.0.1:" .. tostring(port) .. "/auth/callback"
	local fields = {
		"grant_type=authorization_code",
		"client_id=" .. urlEncode(clientId),
		"code=" .. urlEncode(code),
		"code_verifier=" .. urlEncode(attempt.verifier),
		"redirect_uri=" .. urlEncode(redirectUri),
		"resource=" .. urlEncode(API_RESOURCE),
	}
	launch:DownloadPage(TOKEN_ENDPOINT, function(response, errorMessage)
		local token, _, decodeError = dkjson.decode(response and response.body or "")
		if errorMessage or type(token) ~= "table" or type(token.id_token) ~= "string" then
			self.status = responseError(response and response.body, errorMessage or decodeError)
			if callback then callback(false, self.status) end
			return
		end
		local scopes = token.scope or token.scopes
		if not hasScope(scopes, "chatgpt.tokens.use.direct") or not hasScope(scopes, "resource.invoke") then
			self.status = "This ChatGPT authorization did not grant the direct model-use permissions required by AI Planner"
			if callback then callback(false, self.status) end
			return
		end
		self:ValidateIDToken(token.id_token, clientId, attempt.nonce, function(claims, verifyError)
			if not claims then
				self.status = verifyError
				if callback then callback(false, self.status) end
				return
			end
			local previous = self.record.credentials
			if previous and previous.clientId == clientId and previous.subject ~= claims.sub then
				self.status = "The selected ChatGPT account identity changed; existing credentials were kept"
				if callback then callback(false, self.status) end
				return
			end
			local credential = {
				clientId = clientId,
				hostId = self.record.hostId,
				subject = claims.sub,
				email = type(claims.email) == "string" and claims.email:sub(1, 180) or nil,
				idToken = token.id_token,
				accessToken = token.access_token,
				refreshToken = token.refresh_token,
				tokenType = token.token_type or "Bearer",
				expiresAt = os.time() + (tonumber(token.expires_in) or 0),
				scopes = scopes,
			}
			if type(credential.accessToken) ~= "string" or not credential.accessToken:match("%S")
				or type(credential.refreshToken) ~= "string" or not credential.refreshToken:match("%S") then
				self.status = "The ChatGPT token response did not contain the required credentials"
				if callback then callback(false, self.status) end
				return
			end
			local previousCredential = self.record.credentials
			local previousReauthorization = self.reauthorizationRequired
			self.record.credentials = credential
			self.reauthorizationRequired = false
			local saved, saveError = self:Save()
			if not saved then
				self.record.credentials = previousCredential
				self.reauthorizationRequired = previousReauthorization
				self.status = saveError
				if callback then callback(false, self.status) end
				return
			end
			self.status = "Connected as " .. tostring(credential.email or "ChatGPT account")
			if callback then callback(true, self.status) end
		end)
	end, {
		header = "Content-Type: application/x-www-form-urlencoded\r\n",
		body = table.concat(fields, "&"),
		forceTLS = true,
	})
end

function AuthClass:ValidateIDToken(idToken, clientId, expectedNonce, callback)
	local headerPart, payloadPart, signaturePart = idToken:match("^([^.]+)%.([^.]+)%.([^.]+)$")
	if not headerPart then callback(nil, "The ChatGPT ID token is malformed") return end
	local headerJson, payloadJson, signature = base64UrlDecode(headerPart), base64UrlDecode(payloadPart), base64UrlDecode(signaturePart)
	local header = headerJson and dkjson.decode(headerJson)
	local claims = payloadJson and dkjson.decode(payloadJson)
	if type(header) ~= "table" or type(claims) ~= "table" or not signature then callback(nil, "The ChatGPT ID token could not be decoded") return end
	if header.alg ~= "RS256" or type(header.kid) ~= "string" or #header.kid > 128 then callback(nil, "The ChatGPT ID token uses an unsupported signature algorithm") return end
	launch:DownloadPage(JWKS_ENDPOINT, function(response, errorMessage)
		local jwks = not errorMessage and dkjson.decode(response and response.body or "")
		local key
		for _, candidate in ipairs(jwks and jwks.keys or { }) do if candidate.kid == header.kid then key = candidate break end end
		if not key then callback(nil, "The signing key for the ChatGPT ID token was not found in OpenAI JWKS") return end
		local verified, signatureError = verifyRS256(headerPart .. "." .. payloadPart, signature, key)
		if not verified then callback(nil, signatureError) return end
		local audMatches = claims.aud == clientId
		if type(claims.aud) == "table" then for _, aud in ipairs(claims.aud) do if aud == clientId then audMatches = true break end end end
		if type(claims.aud) == "table" and #claims.aud > 1 and claims.azp ~= clientId then
			callback(nil, "The ChatGPT ID token authorized party is invalid")
			return
		end
		if claims.iss ~= "https://auth.openai.com" or not audMatches or type(claims.sub) ~= "string" or claims.sub == "" then
			callback(nil, "The ChatGPT ID token issuer, audience, or subject is invalid")
			return
		end
		if type(claims.exp) ~= "number" or claims.exp <= os.time() or claims.nonce ~= expectedNonce then
			callback(nil, "The ChatGPT ID token is expired or its nonce does not match this login")
			return
		end
		callback(claims)
	end, { forceTLS = true })
end

local function supportsTextChat(model, slug)
	local inputModalities = model.input_modalities or model.inputModalities
	if type(inputModalities) == "table" then
		local hasText = false
		for _, modality in pairs(inputModalities) do if tostring(modality):lower() == "text" then hasText = true break end end
		if not hasText then return false end
	end
	local outputModalities = model.output_modalities or model.outputModalities
	if type(outputModalities) == "table" then
		local hasText = false
		for _, modality in pairs(outputModalities) do if tostring(modality):lower() == "text" then hasText = true break end end
		if not hasText then return false end
	end
	local endpoints = model.supported_endpoints or model.supportedEndpoints
	if type(endpoints) == "table" then
		for _, endpoint in pairs(endpoints) do
			local name = tostring(endpoint):lower()
			if name:find("responses", 1, true) or name:find("chat/completions", 1, true) then return true end
		end
		return false
	end
	local capabilities = model.capabilities
	if type(capabilities) == "table" then
		if capabilities.responses ~= nil or capabilities.chat ~= nil or capabilities.text ~= nil then
			return capabilities.responses == true or capabilities.chat == true or capabilities.text == true
		end
	end

	-- /v1/models lists non-chat resources too. Keep this selector focused on
	-- text-capable model families when endpoint capability metadata is absent.
	local normalized = slug:lower()
	if normalized:find("embedding", 1, true) or normalized:find("moderation", 1, true)
		or normalized:find("realtime", 1, true) or normalized:find("transcrib", 1, true)
		or normalized:find("text-to-speech", 1, true) or normalized:match("^tts%-")
		or normalized:match("^whisper") or normalized:match("^dall%-e")
		or normalized:match("^sora") or normalized:match("^gpt%-audio")
		or normalized:match("^gpt%-image") or normalized:match("^audio%-") then
		return false
	end
	return normalized:match("^gpt%-") ~= nil or normalized:match("^chatgpt%-") ~= nil
		or normalized:match("^o%d+[%-%._]?") ~= nil or normalized:match("^codex%-") ~= nil
end

local function normalizeModelCatalog(decoded)
	if type(decoded) ~= "table" then return nil end
	local entries = type(decoded.models) == "table" and decoded.models or decoded.data
	if type(entries) ~= "table" then return nil end
	local models, seen = { }, { }
	for _, model in ipairs(entries) do
		if type(model) == "table" then
			local slug = model.slug or model.id
			local visibility = model.visibility
			if type(slug) == "string" and #slug > 0 and #slug <= 96 and not seen[slug]
				and (visibility == nil or visibility == "list") and model.enabled ~= false and model.deleted ~= true
				and supportsTextChat(model, slug) then
				seen[slug] = true
				models[#models + 1] = {
					slug = slug,
					displayName = tostring(model.display_name or model.name or slug):sub(1, 96),
				}
			end
		end
	end
	return models
end

function AuthClass:FetchModels(callback)
	self:GetAccessToken(function(token, tokenError)
		if not token then callback(nil, tokenError) return end
		launch:DownloadPage("https://api.openai.com/v1/models", function(response, errorMessage)
			local decoded = not errorMessage and dkjson.decode(response and response.body or "")
			local models = normalizeModelCatalog(decoded)
			if not models then
				callback(nil, responseError(response and response.body, errorMessage or "The ChatGPT model catalog was unavailable"))
				return
			end
			callback(models)
		end, { header = "Authorization: Bearer " .. token .. "\r\n", forceTLS = true })
	end)
end

function AuthClass:GetAccessToken(callback)
	local credential = self.record.credentials
	if not credential then callback(nil, "Sign in with ChatGPT before sending a message") return end
	if self:NeedsReauthorization() then callback(nil, self:GetStatus()) return end
	if type(credential.accessToken) == "string" and credential.expiresAt and credential.expiresAt > os.time() + 90 then
		callback(credential.accessToken)
		return
	end
	if type(credential.refreshToken) ~= "string" then callback(nil, "The ChatGPT session expired; sign in again") return end
	local fields = {
		"grant_type=refresh_token",
		"client_id=" .. urlEncode(credential.clientId),
		"refresh_token=" .. urlEncode(credential.refreshToken),
		"resource=" .. urlEncode(API_RESOURCE),
	}
	launch:DownloadPage(TOKEN_ENDPOINT, function(response, errorMessage)
		local refreshed = not errorMessage and dkjson.decode(response and response.body or "")
		if type(refreshed) ~= "table" or type(refreshed.access_token) ~= "string" then
			local body = response and response.body
			local parsed = type(body) == "string" and dkjson.decode(body) or nil
			local nested = type(parsed) == "table" and parsed.error or nil
			local errorCode = type(nested) == "table" and nested.code or nil
				errorCode = errorCode or (type(nested) == "string" and nested) or (type(parsed) == "table" and (parsed.error_code or parsed.code))
			local message = responseError(body, errorMessage or "The ChatGPT session could not be refreshed")
			if terminalRefreshErrors[errorCode] then
				self:RequireReauthorization("The saved ChatGPT refresh token was rejected. Sign in again with the same account.", true)
				callback(nil, self:GetStatus())
			else
				callback(nil, message)
			end
			return
		end
		local scopes = refreshed.scope or refreshed.scopes or credential.scopes
		if not hasScope(scopes, "chatgpt.tokens.use.direct") or not hasScope(scopes, "resource.invoke") then
			self:RequireReauthorization("The renewed ChatGPT session lacks direct model-use permission. Sign in again and review the requested access.", false)
			callback(nil, self:GetStatus())
			return
		end
		local oldAccess, oldRefresh, oldExpiry, oldScopes = credential.accessToken, credential.refreshToken, credential.expiresAt, credential.scopes
		credential.accessToken = refreshed.access_token
		credential.refreshToken = refreshed.refresh_token or credential.refreshToken
		credential.expiresAt = os.time() + (tonumber(refreshed.expires_in) or 0)
		credential.scopes = scopes
		local saved, saveError = self:Save()
		if not saved then
			credential.accessToken, credential.refreshToken, credential.expiresAt, credential.scopes = oldAccess, oldRefresh, oldExpiry, oldScopes
			callback(nil, saveError)
			return
		end
		callback(credential.accessToken)
	end, {
		header = "Content-Type: application/x-www-form-urlencoded\r\n",
		body = table.concat(fields, "&"),
		forceTLS = true,
	})
end

function AuthClass:Forget()
	local previous = self.record.credentials
	local previousReauthorization = self.reauthorizationRequired
	self.record.credentials = nil
	self.reauthorizationRequired = false
	local saved, err = self:Save()
	if not saved then self.record.credentials = previous self.reauthorizationRequired = previousReauthorization self.status = err return false, err end
	self.status = "ChatGPT credentials removed from this device"
	return true
end

AuthClass.Base64UrlEncode = base64UrlEncode
AuthClass.Base64UrlDecode = base64UrlDecode
AuthClass.UrlEncode = urlEncode
AuthClass.HasScope = hasScope
AuthClass.VerifyRS256 = verifyRS256
AuthClass.PrepareCredentialStorage = prepareCredentialStorage
AuthClass.NormalizeModelCatalog = normalizeModelCatalog
AuthClass.ResponseError = responseError
AuthClass.TerminalRefreshErrors = terminalRefreshErrors

return AuthClass
