-- Path of Building
--
-- Module: Exact factorial interaction analysis for optimizer studies.
-- This module does not evaluate builds or admit training data. It only derives
-- difference-in-differences from four finite, exact PoB metric snapshots.

local factorialStudy = { }

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function factorialStudy.Compute(cells)
	if type(cells) ~= "table" then return nil, "Factorial cells are required" end
	local metricMaps = { }
	for _, name in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
		local cell = cells[name]
		if type(cell) ~= "table" or type(cell.metrics) ~= "table" then
			return nil, "The exact " .. name .. " metric snapshot is missing"
		end
		metricMaps[name] = cell.metrics
	end

	local keys = { }
	for key, value in pairs(metricMaps.baseline) do
		if type(key) == "string" and isFinite(value)
			and isFinite(metricMaps.factorA[key])
			and isFinite(metricMaps.factorB[key])
			and isFinite(metricMaps.combined[key]) then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	if #keys == 0 then return nil, "The four exact cells have no common finite PoB metrics" end

	local metrics = { }
	for _, key in ipairs(keys) do
		local baseline = metricMaps.baseline[key]
		local factorA = metricMaps.factorA[key]
		local factorB = metricMaps.factorB[key]
		local combined = metricMaps.combined[key]
		metrics[key] = {
			baseline = baseline,
			factorA = factorA,
			factorB = factorB,
			combined = combined,
			factorADelta = factorA - baseline,
			factorBDelta = factorB - baseline,
			combinedDelta = combined - baseline,
			interaction = combined - factorA - factorB + baseline,
		}
	end
	return {
		formula = "combined - factorA - factorB + baseline",
		metricCount = #keys,
		metricKeys = keys,
		metrics = metrics,
	}
end

return factorialStudy
