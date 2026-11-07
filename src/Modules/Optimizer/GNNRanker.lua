-- Path of Building
--
-- Module: optional remote GNN ordering. The returned array is checked as a
-- pure permutation; PoB's native exact evaluator remains the only validator.

local ranker = { }
local GraphSnapshot = require("Modules.Optimizer.GraphSnapshot")
local IPC = require("Modules.Optimizer.GNNIPC")
local TrainingExport = require("Modules.Optimizer.GNNTrainingExport")

local function isPermutation(original, ranked, proposalIds)
	if type(ranked) ~= "table" or #ranked ~= #original or type(proposalIds) ~= "table" then return false end
	local byId, seen = { }, { }
	for index, candidate in ipairs(original) do byId[proposalIds[index]] = candidate end
	local result = { }
	for _, proposalId in ipairs(ranked) do
		if type(proposalId) ~= "string" or seen[proposalId] or not byId[proposalId] then return false end
		seen[proposalId] = true
		result[#result + 1] = byId[proposalId]
	end
	return #result == #original, result
end

function ranker.Rank(build, candidates, parsed, control, job)
	local runSpec = parsed and parsed.search and parsed.search.routePlannerRunSpec
	if type(runSpec) ~= "table" then return candidates, "run_spec_unavailable" end
	local snapshotOk, buildSnapshot, proposals = pcall(GraphSnapshot.Create, build, candidates, runSpec)
	if not snapshotOk or not buildSnapshot then
		return candidates, "deterministic_fallback_snapshot_unavailable: " .. tostring(proposals or buildSnapshot)
	end
	if job and control and type(control.gnnTrainingAuthorization) == "table"
		and control.gnnTrainingAuthorization.consent == true then
		local contextOk, context = pcall(TrainingExport.CreateContext, buildSnapshot, proposals, candidates,
			runSpec, control.gnnTrainingAuthorization)
		if contextOk then job.gnnTrainingContext = context end
	end
	if runSpec.modelMode == "deterministic_fallback" then return candidates, "deterministic_fallback_selected" end
	local client, connectError = IPC.Connect()
	if not client then return candidates, "deterministic_fallback_" .. tostring(connectError) end
	local optimize, optimizeError = client:Call("build_planner/optimize", {
		runSpec = runSpec,
		buildSnapshot = buildSnapshot,
		proposals = proposals,
	}, control, job, runSpec.budget.timeoutSeconds)
	if not optimize then
		client:Close()
		return candidates, "deterministic_fallback_" .. tostring(optimizeError)
	end
	local deadline = os.clock() + runSpec.budget.timeoutSeconds
	while os.clock() < deadline do
		if control and control.cancelled then
			client:Call("build_planner/cancel", { job_id = optimize.job_id }, nil, job, 2)
			client:Close()
			return candidates, "cancelled"
		end
		local polled, pollError = client:Call("build_planner/poll", { job_id = optimize.job_id }, control, job, 5)
		if not polled then
			if pollError == "cancelled" then
				client:Call("build_planner/cancel", { job_id = optimize.job_id }, nil, job, 2)
			end
			client:Close()
			return candidates, "deterministic_fallback_" .. tostring(pollError)
		end
		local progress = polled.progress or { }
		if job then
			job.progress = { phase = "GNN ranking", processed = tonumber(progress.processed) or 0,
				total = tonumber(progress.total) or #proposals, current = tostring(polled.status or "waiting") }
		end
		if polled.status == "completed" then
			client:Close()
			local ordering = polled.result and polled.result.rankedProposalIds
			local ids = { }
			for index = 1, #candidates do ids[index] = "p" .. tostring(index) end
			local valid, ranked = isPermutation(candidates, ordering, ids)
			if not valid then return candidates, "deterministic_fallback_invalid_model_ranking" end
			return ranked, "ranked"
		elseif polled.status == "failed" then
			client:Close()
			return candidates, "deterministic_fallback_model_job_failed: " .. tostring(polled.error or "unknown error")
		elseif polled.status == "cancelled" then
			client:Close()
			return candidates, "cancelled"
		end
		coroutine.yield(job and job.progress or { phase = "GNN ranking", processed = 0, total = #proposals })
	end
	client:Call("build_planner/cancel", { job_id = optimize.job_id }, nil, job, 2)
	client:Close()
	return candidates, "deterministic_fallback_daemon_timeout"
end

return ranker
