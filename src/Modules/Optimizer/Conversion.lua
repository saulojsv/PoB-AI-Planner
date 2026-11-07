-- Path of Building
--
-- Module: Conversion requirements. Reads the exact conversion table produced by
-- CalcOffence; it deliberately does not repeat Path of Exile conversion rules.
--
local t_insert = table.insert
local conversion = { }

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function conversion.Evaluate(activeSkill, requestedRoute, minPercent)
	local result = { satisfied = true, edges = { }, shortfall = { } }
	if not requestedRoute or #requestedRoute == 0 then
		return result
	end
	local tableForSkill = activeSkill and activeSkill.conversionTable
	if type(tableForSkill) ~= "table" then
		return { satisfied = false, unsupported = true, edges = { }, shortfall = { "Exact skill conversion table is unavailable" } }
	end
	for index = 1, #requestedRoute - 1 do
		local fromType = requestedRoute[index]
		local toType = requestedRoute[index + 1]
		local source = tableForSkill[fromType]
		local percent = source and source.conversion and source.conversion[toType]
		percent = isFinite(percent) and percent * 100 or 0
		local edge = { from = fromType, to = toType, percent = percent, required = minPercent or 100 }
		t_insert(result.edges, edge)
		if percent + 0.0000001 < edge.required then
			result.satisfied = false
			t_insert(result.shortfall, string.format("%s to %s: %.4g%% < %.4g%%", fromType, toType, percent, edge.required))
		end
	end
	return result
end

return conversion
