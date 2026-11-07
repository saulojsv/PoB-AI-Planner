-- Path of Building
--
-- Module: Exact, isolated comparison of the seven PoE base-class starts.
-- This is a root-only baseline, not a search across ascendancies or passive
-- allocations. Each candidate is calculated by the normal PoB engine.
--
local Inputs = require("Modules.Optimizer.Inputs")
local Candidate = require("Modules.Optimizer.Candidate")
local PhantomSim = require("Modules.Optimizer.PhantomSim")

local classRoots = { }

local function shallowCopy(source)
	local copy = { }
	for key, value in pairs(source or { }) do copy[key] = value end
	return copy
end

local function comparisonInputs()
	return {
		hard = { },
		objective = "CombinedDPS",
		scenarioProfile = "Current",
		targetNodeIds = { },
		conversion = { route = { }, minPercent = 0 },
		branch = { required = { }, allowed = { }, forbidden = { } },
		search = {
			maxAddedPoints = 0,
			maxTotalPoints = 120,
			evaluationBudget = 1,
			seed = 1,
			addNodeIds = { },
			removeNodeIds = { },
			requiredNodeIds = { },
			forbiddenNodeIds = { },
		},
	}
end

local function classBuildProxy(build, classId)
	local rootSpec, err, itemsTab = Candidate.BuildPassiveSpec(build, { }, { }, { classId = classId })
	if not rootSpec then return nil, err end
	local proxy = shallowCopy(build)
	proxy.spec = rootSpec
	proxy.itemsTab = itemsTab
	proxy.treeTab = shallowCopy(build.treeTab)
	proxy.treeTab.viewer = shallowCopy(build.treeTab and build.treeTab.viewer)
	setmetatable(proxy, getmetatable(build))
	return proxy
end

local function evaluatedMetrics(result)
	if result and result.candidate and result.candidate.evaluation then
		return result.candidate.evaluation.metrics, result.candidate.evaluation.violations
	end
	return result and result.bestObservedMetrics or { }, result and result.bestObservedViolations or { }
end

function classRoots.RunComparison(build)
	local classes = { }
	for classId, class in pairs(build and build.spec and build.spec.tree.classes or { }) do
		if class and class.startNodeId then
			classes[#classes + 1] = { id = classId, name = class.name or ("Class " .. tostring(classId)) }
		end
	end
	table.sort(classes, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.id < b.id
	end)
	local job = {
		status = "running",
		progress = { phase = "Preparing class roots", processed = 0, total = #classes },
		results = { },
		index = 0,
		cancelled = false,
	}
	function job:Cancel()
		self.cancelled = true
		if self.currentJob then self.currentJob:Cancel() end
	end
	function job:Step()
		if self.status ~= "running" then return self.status, self.result end
		if self.cancelled then
			self.status = "cancelled"
			self.result = { status = "cancelled", results = self.results }
			return self.status, self.result
		end
		if not self.currentJob then
			self.index = self.index + 1
			local class = classes[self.index]
			if not class then
				self.status = "complete"
				self.result = { status = "complete", exactEngine = true, rootOnly = true, results = self.results }
				return self.status, self.result
			end
			local proxy, err = classBuildProxy(build, class.id)
			if not proxy then
				self.results[#self.results + 1] = { classId = class.id, class = class.name, status = "unsupported", reason = err, passivePoints = 0 }
				self.progress = { phase = "Exact class-root calculations", processed = #self.results, total = #classes, current = class.name }
				return "running", self.progress
			end
			self.currentClass = class
			self.currentJob = PhantomSim.RunPhantomSim(proxy, comparisonInputs())
			self.progress = { phase = "Exact class-root calculations", processed = #self.results, total = #classes, current = class.name }
			return "running", self.progress
		end
		local state, result = self.currentJob:Step()
		if state == "running" then
			self.progress = { phase = "Exact class-root calculations", processed = #self.results, total = #classes, current = self.currentClass.name }
			return state, self.progress
		end
		local class = self.currentClass
		local metrics, violations = evaluatedMetrics(result)
		self.results[#self.results + 1] = {
			classId = class.id,
			class = class.name,
			status = state == "error" and "error" or result and result.status or state,
			metrics = metrics or { },
			violations = violations or { },
			passivePoints = 0,
			baseline = "class start only; no ascendancy, allocated passives, or tree jewels",
		}
		self.currentJob = nil
		self.currentClass = nil
		self.progress = { phase = "Exact class-root calculations", processed = #self.results, total = #classes }
		return "running", self.progress
	end
	return job
end

return classRoots
