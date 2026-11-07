-- Path of Building
--
-- Module: Equal-budget exact search from every native base-class start.
-- Each class starts from a fresh PoB PassiveSpec, shares the same selected
-- gear/skills/config and level, and is evaluated through PhantomSim. This is a
-- bounded comparison, never a claim of a globally optimal build.

local Candidate = require("Modules.Optimizer.Candidate")
local PhantomSim = require("Modules.Optimizer.PhantomSim")

local classSearch = { }

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function shallowCopy(source)
	local copy = { }
	for key, value in pairs(source or { }) do copy[key] = value end
	return copy
end

local function copyArray(source)
	local copy = { }
	for index, value in ipairs(source or { }) do copy[index] = value end
	return copy
end

local function copyParsed(source, classId, budget)
	local parsed = shallowCopy(source)
	parsed.hard = { }
	for key, value in pairs(source.hard or { }) do parsed.hard[key] = shallowCopy(value) end
	parsed.branch = shallowCopy(source.branch)
	for _, key in ipairs({ "required", "allowed", "forbidden" }) do parsed.branch[key] = copyArray(source.branch and source.branch[key]) end
	parsed.conversion = shallowCopy(source.conversion)
	parsed.conversion.route = copyArray(source.conversion and source.conversion.route)
	parsed.targetNodeIds = copyArray(source.targetNodeIds)
	parsed.search = shallowCopy(source.search)
	for _, key in ipairs({ "addNodeIds", "removeNodeIds", "requiredNodeIds", "forbiddenNodeIds" }) do
		parsed.search[key] = copyArray(source.search and source.search[key])
	end
	parsed.search.searchAllClasses = false
	parsed.search.baseClassId = classId
	parsed.search.evaluationBudget = budget
	-- Keep structural generation proportional to this class's exact quota. The
	-- UI's normal hidden proposal budget can be much larger (for example 120),
	-- which made a one- or ten-evaluation class search spend thousands of
	-- cooperative pathfinding steps preparing proposals it could never evaluate.
	parsed.search.proposalBudget = budget
	-- A global class comparison must spend its equal per-class budget on both
	-- ascendancy alternatives and main-tree routes. PhantomSim uses this internal
	-- profile to raise the route quota without changing ordinary single-class runs.
	parsed.search.equalBudgetClassSearch = true
	return parsed
end

local function listClasses(build)
	local classes = { }
	for classId, class in pairs(build and build.spec and build.spec.tree and build.spec.tree.classes or { }) do
		if class and class.startNodeId and class.classes then
			classes[#classes + 1] = { id = classId, name = class.name or ("Class " .. tostring(classId)) }
		end
	end
	table.sort(classes, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.id < b.id
	end)
	return classes
end

local function makeClassRoot(build, classId)
	local spec, err, itemsTab = Candidate.BuildPassiveSpec(build, { }, { }, { classId = classId })
	if not spec then return nil, err end
	local proxy = shallowCopy(build)
	setmetatable(proxy, getmetatable(build))
	proxy.spec = spec
	proxy.itemsTab = itemsTab
	proxy.itemsTab.build = proxy
	proxy.treeTab = shallowCopy(build.treeTab)
	proxy.treeTab.viewer = shallowCopy(build.treeTab and build.treeTab.viewer)
	-- Global class comparison holds character level fixed. Otherwise PoB's Auto
	-- mode would turn a zero-point class root into a level-one candidate and
	-- compare different character levels instead of different class starts.
	proxy.characterLevelAutoMode = false
	return proxy
end

local function objectiveValue(candidate, objective)
	local metrics = candidate and candidate.evaluation and candidate.evaluation.metrics or { }
	local value = metrics[objective]
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value or nil
end

local function boundedText(value, limit)
	if type(value) ~= "string" then return nil end
	return value:sub(1, limit or 96)
end

local function summarizeAscendancyCoverage(searchCoverage)
	local source = searchCoverage and searchCoverage.ascendancies
	if type(source) ~= "table" then return nil end
	local result = { status = boundedText(source.status, 40) }
	for _, key in ipairs({
		"budget", "generatedCandidates", "exactEvaluations", "exactBloodlineEvaluations", "exactCombinedEvaluations",
		"availableMainAscendancies", "representedMainAscendancies", "availableBloodlines", "representedBloodlines",
		"availableBloodlineCombinations", "representedBloodlineCombinations", "availableCombinations", "representedCombinations",
	}) do
		if isFinite(source[key]) then result[key] = source[key] end
	end
	for _, key in ipairs({ "secondaryAscendancySearched", "secondaryCombinationSearched", "budgetLimited" }) do
		if type(source[key]) == "boolean" then result[key] = source[key] end
	end
	return result
end

local function summarizeTreeCoverage(searchCoverage)
	local phase = searchCoverage and searchCoverage.phase
	if type(phase) ~= "table" then return nil end
	local result = { }
	for _, key in ipairs({
		"exactEvaluations", "generatedTreeCandidates", "generatedProgressiveTreeBundles",
		"exactProgressiveTreeBundleEvaluations", "maxProgressiveRouteCount",
		"largestProposedTreePointCount", "largestExactTreePointCount",
		"generatedTreeAscendancyCombinations", "exactTreeAscendancyCombinations",
		"structuralTreeRejections", "structuralProgressiveTreeBundleRejections",
	}) do
		if isFinite(phase[key]) then result[key] = phase[key] end
	end
	local zones = searchCoverage and searchCoverage.zones
	if type(zones) == "table" then
		for _, key in ipairs({ "progressiveRouteDistinctGoals", "progressiveRouteSourceCandidates" }) do
			if isFinite(zones[key]) then result[key] = zones[key] end
		end
		result.progressiveRoutePoolStatus = boundedText(zones.progressiveRoutePoolStatus, 48)
		result.progressiveRouteGoalsByRegion = { }
		for region, count in pairs(zones.progressiveRouteGoalsByRegion or { }) do
			if type(region) == "string" and #region <= 48 and isFinite(count) then
				result.progressiveRouteGoalsByRegion[region] = count
			end
		end
	end
	return result
end

local function summarizeBestCandidate(candidate, objective)
	if type(candidate) ~= "table" or type(candidate.evaluation) ~= "table" then return nil end
	local evaluation = candidate.evaluation
	return {
		label = boundedText(candidate.label, 120),
		mainAscendancy = boundedText(evaluation.selectedAscendancyName, 80),
		bloodline = boundedText(evaluation.selectedSecondaryAscendancyName, 80),
		objectiveValue = objectiveValue(candidate, objective),
		passivePointsUsed = isFinite(evaluation.passivePointsUsed) and evaluation.passivePointsUsed or nil,
		passivePointLimit = isFinite(evaluation.strictPointCap) and evaluation.strictPointCap or nil,
		mainAscendancyPoints = isFinite(evaluation.ascendancyPointsUsed) and evaluation.ascendancyPointsUsed or nil,
		bloodlinePoints = isFinite(evaluation.secondaryAscendancyPointsUsed) and evaluation.secondaryAscendancyPointsUsed or nil,
	}
end

local function candidateBetter(a, b, objective)
	if not b then return true end
	local metricsA = a.evaluation and a.evaluation.metrics or { }
	local metricsB = b.evaluation and b.evaluation.metrics or { }
	local av, bv = objectiveValue(a, objective), objectiveValue(b, objective)
	if av == nil then return false end
	if bv == nil then return true end
	if av ~= bv then return av > bv end
	local dpsA, dpsB = metricsA.CombinedDPS or 0, metricsB.CombinedDPS or 0
	if dpsA ~= dpsB then return dpsA > dpsB end
	local ehpA, ehpB = metricsA.TotalEHP or 0, metricsB.TotalEHP or 0
	if ehpA ~= ehpB then return ehpA > ehpB end
	local pointsA = a.evaluation.passivePointsUsed or #(a.nodeIds or { })
	local pointsB = b.evaluation.passivePointsUsed or #(b.nodeIds or { })
	if pointsA ~= pointsB then return pointsA < pointsB end
	local classA = a.evaluation and a.evaluation.selectedBaseClassName or ""
	local classB = b.evaluation and b.evaluation.selectedBaseClassName or ""
	if classA ~= classB then return classA < classB end
	return tostring(a.label or "") < tostring(b.label or "")
end

local function addToParetoFront(front, candidate, objective)
	local function metrics(value)
		return value and value.evaluation and value.evaluation.metrics or { }
	end
	local function dominates(first, second)
		local firstMetrics, secondMetrics = metrics(first), metrics(second)
		local firstObjective, secondObjective = firstMetrics[objective] or 0, secondMetrics[objective] or 0
		local firstEhp, secondEhp = firstMetrics.TotalEHP or 0, secondMetrics.TotalEHP or 0
		local firstPoints = first.evaluation.passivePointsUsed or #(first.nodeIds or { })
		local secondPoints = second.evaluation.passivePointsUsed or #(second.nodeIds or { })
		return firstObjective >= secondObjective and firstEhp >= secondEhp and firstPoints <= secondPoints
			and (firstObjective > secondObjective or firstEhp > secondEhp or firstPoints < secondPoints)
	end
	for index = #front, 1, -1 do
		if dominates(front[index], candidate) then return end
		if dominates(candidate, front[index]) then table.remove(front, index) end
	end
	front[#front + 1] = candidate
end

local function terminalSummary(job)
	local classResults = { }
	for index, row in ipairs(job.classResults) do
		local metrics, violations = { }, { }
		for key, value in pairs(row.bestObservedMetrics or { }) do if isFinite(value) then metrics[key] = value end end
		for _, violation in ipairs(row.bestObservedViolations or { }) do
			local safe = { key = violation.key, label = violation.label, reason = violation.reason }
			if isFinite(violation.actual) then safe.actual = violation.actual end
			if isFinite(violation.required) then safe.required = violation.required end
			if isFinite(violation.deficit) then safe.deficit = violation.deficit end
			violations[#violations + 1] = safe
		end
		classResults[index] = {
			classId = row.classId,
			class = row.class,
			status = row.status,
			quota = row.quota,
			evaluations = row.evaluations,
			objectiveValue = row.objectiveValue,
			bestObservedMetrics = metrics,
			bestObservedViolations = violations,
			bestObservedDeficit = isFinite(row.bestObservedDeficit) and row.bestObservedDeficit or nil,
			bestCandidate = summarizeBestCandidate(row.bestCandidate, job.parsed.objective),
			ascendancyCoverage = summarizeAscendancyCoverage(row.searchCoverage),
			treeCoverage = summarizeTreeCoverage(row.searchCoverage),
			error = row.error and tostring(row.error):sub(1, 240) or nil,
		}
	end
	local result = {
		status = job.status,
		evaluations = job.evaluations,
		classSearch = {
			mode = "equal_per_class_exact_evaluation_budget",
			classCount = #job.classes,
			totalBudget = job.totalBudget,
			usedBudget = job.evaluations,
			unusedBudget = math.max(0, job.totalBudget - job.evaluations),
			exhaustive = false,
			results = classResults,
		},
		scenarioProfile = job.parsed.scenarioProfile,
	}
	if job.status == "feasible" and job.best then
		result.candidate = job.best
		result.evaluation = job.best.evaluation
		result.paretoFront = job.paretoFront
		result.scenarioProfile = job.best.evaluation.scenarioProfile
		result.scenario = job.best.evaluation.scenario
		result.message = "Best exact-feasible class candidate within equal per-class budgets; this is not a proof of global optimality."
	elseif job.status == "no_feasible_candidate" then
		result.candidate = nil
		result.bestObservedMetrics = job.bestFailure and job.bestFailure.metrics or { }
		result.bestObservedViolations = job.bestFailure and job.bestFailure.violations or { }
		result.bestObservedDeficit = job.bestFailure and job.bestFailure.normalizedDeficit
		result.message = job.bestFailure and "No feasible candidate found within the equal per-class search budget"
			or "No feasible candidate found; review per-class constraints and class-specific errors"
	elseif job.status == "cancelled" or job.status == "stale_build" or job.status == "error" then
		result.candidate = nil
		result.message = job.error or (job.status == "cancelled" and "Class comparison cancelled; partial candidates cannot be applied" or "Class comparison did not complete")
	end
	return result
end

function classSearch.Start(build, parsed, control)
	if not parsed or not parsed.search or parsed.search.searchAllClasses ~= true then
		return nil, "Enable search across all native base classes first"
	end
	if parsed.search.baseClassId ~= nil then return nil, "Choose one base class or all classes, not both" end
	if #(parsed.search.addNodeIds or { }) > 0 or #(parsed.search.removeNodeIds or { }) > 0 then
		return nil, "Explicit passive additions/removals cannot be combined with all-class search; use hard node requirements instead"
	end
	local classes = listClasses(build)
	if #classes < 2 then return nil, "The active PoB tree does not expose enough native class starts to compare" end
	local totalBudget = parsed.search.evaluationBudget
	if totalBudget < #classes then
		return nil, "All-class search needs at least " .. #classes .. " exact evaluations so every native class receives the same baseline opportunity"
	end
	local originalSignature = Candidate.BuildSignature(build)
	local baseQuota = math.floor(totalBudget / #classes)
	local remainder = totalBudget - baseQuota * #classes
	local job = {
		build = build,
		sourceSignature = originalSignature,
		parsed = parsed,
		classes = classes,
		totalBudget = totalBudget,
		baseQuota = baseQuota,
		remainder = remainder,
		index = 0,
		evaluations = 0,
		classResults = { },
		paretoFront = { },
		status = "running",
		progress = { phase = "Preparing equal-budget class search", processed = 0, total = totalBudget, currentClass = nil },
	}

	function job:Cancel()
		if self.status ~= "running" then return false end
		self.cancelRequested = true
		if self.currentJob then self.currentJob:Cancel() end
		return true
	end

	local function finish(self)
		for _, row in ipairs(self.classResults) do
			if row.status == "error" or row.status == "stale_build" then
				self.status = "error"
				self.error = "An exact PoB class evaluation failed; no candidate is offered."
				return
			end
		end
		self.status = self.best and "feasible" or "no_feasible_candidate"
	end

	function job:Step()
		if self.status ~= "running" then return self.status, self.result end
		if self.cancelRequested then
			self.status = "cancelled"
			self.error = "Class comparison cancelled; partial candidates cannot be applied"
			self.result = terminalSummary(self)
			return self.status, self.result
		end
		if Candidate.BuildSignature(self.build) ~= self.sourceSignature then
			self.status = "stale_build"
			self.error = "The active build or its inputs changed during class comparison; run it again"
			self.result = terminalSummary(self)
			return self.status, self.result
		end
		if not self.currentJob then
			self.index = self.index + 1
			local class = self.classes[self.index]
			if not class then
				finish(self)
				self.result = terminalSummary(self)
				return self.status, self.result
			end
			local quota = self.baseQuota + (self.index <= self.remainder and 1 or 0)
			local classBuild, classError = makeClassRoot(self.build, class.id)
			if not classBuild then
				self.classResults[#self.classResults + 1] = { classId = class.id, class = class.name, status = "error", quota = quota, error = tostring(classError) }
				self.progress = { phase = "Class root construction", processed = self.evaluations, total = self.totalBudget, currentClass = class.name, classIndex = self.index, classCount = #self.classes }
				return "running", self.progress
			end
			local classInputs = copyParsed(self.parsed, class.id, quota)
			self.currentClass = class
			self.currentQuota = quota
			self.currentJob = PhantomSim.RunPhantomSim(classBuild, classInputs, control)
			self.progress = { phase = "Exact class optimization", processed = self.evaluations, total = self.totalBudget, currentClass = class.name, classIndex = self.index, classCount = #self.classes, classBudget = quota }
			return "running", self.progress
		end
		local class = self.currentClass
		local status, classResult = self.currentJob:Step()
		if status == "running" then
			local inner = self.currentJob.progress or { }
			self.progress = {
				phase = "Class " .. class.name .. ": " .. tostring(inner.phase or "searching"),
				processed = math.min(self.totalBudget, self.evaluations + (inner.processed or 0)),
				total = self.totalBudget,
				currentClass = class.name,
				classIndex = self.index,
				classCount = #self.classes,
				classBudget = self.currentQuota,
			}
			return "running", self.progress
		end
		local used = classResult and classResult.evaluations or 0
		self.evaluations = self.evaluations + used
		local row = {
			classId = class.id,
			class = class.name,
			status = status,
			quota = self.currentQuota,
			evaluations = used,
			objectiveValue = nil,
			searchCoverage = classResult and classResult.searchCoverage or nil,
		}
		if status == "feasible" and classResult.candidate then
			row.bestCandidate = classResult.candidate
			local candidates = { classResult.candidate }
			for _, candidate in ipairs(classResult.paretoFront or { }) do
				if candidate ~= classResult.candidate then candidates[#candidates + 1] = candidate end
			end
			for _, candidate in ipairs(candidates) do
				candidate.classVariant = { classId = class.id }
				candidate.sourceSignature = self.sourceSignature
				candidate.label = class.name .. " — " .. tostring(candidate.label or "Feasible route")
				self.paretoFront[#self.paretoFront + 1] = candidate
			end
			local classBest = classResult.candidate
			row.objectiveValue = objectiveValue(classBest, self.parsed.objective)
			if candidateBetter(classBest, self.best, self.parsed.objective) then self.best = classBest end
			for _, violationCandidate in ipairs(classResult.paretoFront or { }) do
				if violationCandidate.feasible then
					if not self.best or candidateBetter(violationCandidate, self.best, self.parsed.objective) then self.best = violationCandidate end
				end
			end
			for _, candidate in ipairs(candidates) do addToParetoFront(self.paretoFront, candidate, self.parsed.objective) end
		elseif status == "no_feasible_candidate" then
			row.bestObservedMetrics = classResult.bestObservedMetrics or { }
			row.bestObservedViolations = classResult.bestObservedViolations or { }
			row.bestObservedDeficit = classResult.bestObservedDeficit
			local deficit = classResult.bestObservedDeficit
			if type(deficit) == "number" and deficit == deficit and deficit ~= math.huge
				and (not self.bestFailure or deficit < (self.bestFailure.normalizedDeficit or math.huge)) then
				self.bestFailure = {
					className = class.name,
					metrics = row.bestObservedMetrics,
					violations = row.bestObservedViolations,
					normalizedDeficit = deficit,
				}
			end
		else
			row.status = status == "invalid_inputs" and "invalid_inputs" or "error"
			row.error = classResult and classResult.message or self.currentJob.error or status
		end
		self.classResults[#self.classResults + 1] = row
		self.currentJob = nil
		self.currentClass = nil
		self.progress = { phase = "Equal-budget class search", processed = self.evaluations, total = self.totalBudget, currentClass = class.name, classIndex = self.index, classCount = #self.classes }
		if self.index >= #self.classes then
			finish(self)
			self.result = terminalSummary(self)
			return self.status, self.result
		end
		return "running", self.progress
	end
	return job
end

return classSearch
