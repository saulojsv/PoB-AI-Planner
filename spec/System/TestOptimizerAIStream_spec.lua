local AIChat = require("Modules/Optimizer/AIChat")
local json = require("dkjson")

-- Execute the production worker with only its HTTP transport replaced. This
-- exercises framing, JSON parsing and the exact response handed to the UI;
-- no network, account, token or native build state is used by these fixtures.
local function runStream(events, options)
	options = options or { }
	local chunks, deltas = { }, { }
	for _, event in ipairs(events) do
		chunks[#chunks + 1] = "data: " .. json.encode(event) .. (options.crlf and "\r\n\r\n" or "\n\n")
	end
	local body = options.rawBody or table.concat(chunks)
	if options.noFinalSeparator then body = body:gsub("[\r\n]+$", "") end
	local handle = { }
	function handle:setopt_url() end
	function handle:setopt() end
	function handle:setopt_headerfunction(callback) self.header = callback end
	function handle:setopt_writefunction(callback) self.write = callback end
	function handle:perform()
		self.header("x-request-id: req-fixture\r\n")
		local size = options.chunkSize or #body
		for first = 1, #body, size do if self.write(body:sub(first, first + size - 1)) == false then break end end
		return self
	end
	function handle:getinfo() return options.httpCode or 200 end
	function handle:close() end
	local curl = setmetatable({ easy = function() return handle end }, { __index = function(_, key) return key end })
	local env = setmetatable({
		require = function(name) if name == "lcurl.safe" then return curl end assert.are.equal("dkjson", name) return json end,
		AIPlannerStreamEvent = function(_, kind, text) assert.are.equal("delta", kind) deltas[#deltas + 1] = text end,
	}, { __index = _G })
	local worker = assert(loadstring(AIChat.StreamScript))
	setfenv(worker, env)
	local encoded, err, code = worker("fixture", "{}", "fixture-not-a-token")
	return encoded and json.decode(encoded), err, code, deltas
end

local function completed(output)
	return { type = "response.completed", response = { status = "completed", output = output or { }, usage = { output_tokens = 7 } } }
end
local function message(text)
	return { id = "msg-fixture", type = "message", role = "assistant", status = "completed", content = { { type = "output_text", text = text } } }
end

describe("Optimizer production Responses stream worker", function()
	it("recovers a sparse terminal envelope from a completed message without duplicated draft text", function()
		local result, err, code, deltas = runStream({
			{ type = "response.output_text.delta", delta = "QA-" },
			{ type = "response.output_item.done", output_index = 0, item = message("QA-OK") }, completed(),
		})
		assert.is_nil(err)
		assert.are.equal(200, code)
		assert.are.equal("QA-OK", result.output[1].content[1].text)
		assert.are.same({ "QA-" }, deltas)
		assert.are.equal(1, result.pob_stream_evidence.recoveredItems)
		assert.are.equal("req-fixture", result.pob_request_id)
	end)
	it("keeps an authoritative nonempty terminal envelope unchanged", function()
		local result = runStream({ { type = "response.output_item.done", output_index = 0, item = message("old") }, completed({ message("QA-OK") }) })
		assert.are.equal(1, #result.output)
		assert.are.equal("QA-OK", result.output[1].content[1].text)
		assert.are.equal(0, result.pob_stream_evidence.recoveredItems)
	end)
	it("recovers typed completed text across split CRLF frames and an EOF terminal event", function()
		local result = runStream({
			{ type = "response.output_text.done", output_index = 0, content_index = 0, item_id = "msg-fixture", text = "QA-OK" }, completed(),
		}, { crlf = true, chunkSize = 7, noFinalSeparator = true })
		assert.are.equal("QA-OK", result.output[1].content[1].text)
		assert.are.equal(1, result.pob_stream_evidence.textDone)
	end)
	it("never certifies partial text as a completed answer", function()
		local result = runStream({ { type = "response.output_text.delta", delta = "partial" }, completed() })
		assert.are.equal(0, #result.output)
		assert.are.equal(7, result.pob_stream_evidence.deltaBytes)
		local absent, err = runStream({ { type = "response.output_text.delta", delta = "partial" } })
		assert.is_nil(absent)
		assert.is_truthy(err:find("before response.completed", 1, true))
	end)
	it("rejects incomplete or failed streams even when completed items exist", function()
		for _, kind in ipairs({ "response.incomplete", "response.failed" }) do
			local result, err = runStream({ { type = "response.output_item.done", output_index = 0, item = message("QA-OK") },
				{ type = kind, response = { error = { message = "fixture failure" } } }, completed() })
			assert.is_nil(result)
			assert.is_truthy(err)
		end
	end)
	it("recovers completed function calls once and never from partial arguments", function()
		local call = { type = "function_call", call_id = "call-fixture", name = "get_build_snapshot", namespace = "pob", arguments = "{}" }
		local result = runStream({ { type = "response.function_call_arguments.delta", output_index = 0, delta = "{" },
			{ type = "response.output_item.done", output_index = 0, item = call }, completed() })
		assert.are.equal(1, #result.output)
		assert.are.same(call, result.output[1])
		local partial = runStream({ { type = "response.function_call_arguments.delta", output_index = 0, delta = "{" }, completed() })
		assert.are.equal(0, #partial.output)
	end)
	it("retains the response size limit and HTTP failure boundary", function()
		local result, err = runStream({ }, { rawBody = string.rep("x", 1048577) })
		assert.is_nil(result)
		assert.is_truthy(err:find("1 MiB", 1, true))
		local denied, failure, code = runStream({ }, { rawBody = '{"error":{"code":"fixture_denied"}}', httpCode = 403 })
		assert.is_nil(denied)
		assert.are.equal(403, code)
		assert.are.equal("fixture_denied", json.decode(failure).error.code)
	end)
	it("keeps truly empty output visible as a diagnostic and excludes raw stream content", function()
		local result = runStream({ { type = "response.output_text.delta", delta = "private fixture text" }, completed() })
		local evidence = json.encode(result.pob_stream_evidence)
		assert.is_nil(evidence:find("private", 1, true))
		assert.is_nil(evidence:find("fixture-not-a-token", 1, true))
		local chat = setmetatable({ messages = { }, currentTurn = { input = { } }, draft = "partial" }, { __index = AIChat })
		chat:HandleCompletedResponse(json.encode(result))
		assert.is_truthy(chat.statusMessage:find("completed without a visible reply", 1, true))
		assert.is_truthy(chat.statusMessage:find("Stream: events 2", 1, true))
	end)
end)
