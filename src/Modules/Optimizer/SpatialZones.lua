--
-- Module: versioned spatial partition of the loaded PoB passive tree.
-- The partition is derived from native node positions and class-start data,
-- never from a screenshot. It is a deterministic baseline for user masks and
-- future learned policies; it does not alter native links or point costs.
--
local t_sort = table.sort

local spatialZones = { }

local regionOrder = {
	Hub = 1,
	NorthWest = 2,
	NorthEast = 3,
	SouthWest = 4,
	SouthEast = 5,
}

local regionAliases = {
	hub = "Hub",
	nw = "NorthWest", northwest = "NorthWest",
	ne = "NorthEast", northeast = "NorthEast",
	sw = "SouthWest", southwest = "SouthWest",
	se = "SouthEast", southeast = "SouthEast",
}

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function orderedIds(values)
	local ids = { }
	for id in pairs(values or { }) do ids[#ids + 1] = id end
	t_sort(ids, function(a, b)
		local numberA, numberB = tonumber(a), tonumber(b)
		if numberA and numberB and numberA ~= numberB then return numberA < numberB end
		return tostring(a) < tostring(b)
	end)
	return ids
end

local function median(values)
	if #values == 0 then return nil end
	t_sort(values)
	local middle = math.floor((#values + 1) / 2)
	if #values % 2 == 1 then return values[middle] end
	return (values[middle] + values[middle + 1]) / 2
end

local function coordinates(spec, id, node)
	local x, y = node and node.x, node and node.y
	local baseNode = spec.tree and spec.tree.nodes and spec.tree.nodes[id]
	if not finite(x) then x = baseNode and baseNode.x end
	if not finite(y) then y = baseNode and baseNode.y end
	if finite(x) and finite(y) then return x, y end
	return nil
end

local function linkedId(link)
	if type(link) == "table" then return link.id end
	return link
end

local function getCenter(spec)
	local tree = spec.tree or { }
	local classStarts = { }
	local scionCenter
	local sumX, sumY, count = 0, 0, 0
	for classId, class in pairs(tree.classes or { }) do
		local startId = class.startNodeId
		local node = startId and ((spec.nodes or { })[startId] or (tree.nodes or { })[startId])
		local x, y = coordinates(spec, startId, node)
		if x then
			classStarts[#classStarts + 1] = { id = startId, classId = classId, name = class.name or "", x = x, y = y }
			sumX, sumY, count = sumX + x, sumY + y, count + 1
			if tostring(class.name):lower() == "scion" then scionCenter = { x = x, y = y } end
		end
	end
	t_sort(classStarts, function(a, b)
		if tostring(a.classId) ~= tostring(b.classId) then return tostring(a.classId) < tostring(b.classId) end
		return tostring(a.id) < tostring(b.id)
	end)
	if scionCenter then return scionCenter.x, scionCenter.y, classStarts end
	if count > 0 then return sumX / count, sumY / count, classStarts end

	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for id, node in pairs(spec.nodes or { }) do
		local x, y = coordinates(spec, id, node)
		if x then
			minX, maxX = math.min(minX, x), math.max(maxX, x)
			minY, maxY = math.min(minY, y), math.max(maxY, y)
		end
	end
	if minX == math.huge then return nil, nil, classStarts end
	return (minX + maxX) / 2, (minY + maxY) / 2, classStarts
end

local function getHubRadius(spec, centerX, centerY, classStarts)
	local startRadii = { }
	for _, classStart in ipairs(classStarts) do
		if classStart.name:lower() ~= "scion" then
			local dx, dy = classStart.x - centerX, classStart.y - centerY
			local radius = math.sqrt(dx * dx + dy * dy)
			if radius > 0 then startRadii[#startRadii + 1] = radius end
		end
	end
	local startRingRadius = median(startRadii)

	local edgeLengths, seenEdges = { }, { }
	for id, node in pairs(spec.nodes or { }) do
		if not node.ascendancyName and node.type ~= "AscendClassStart" then
			local x, y = coordinates(spec, id, node)
			if x then
				for _, link in ipairs(node.linked or { }) do
					local otherId = linkedId(link)
					local other = spec.nodes[otherId]
					if other and not other.ascendancyName and other.type ~= "AscendClassStart"
						and tostring(id) < tostring(otherId) then
						local edgeKey = tostring(id) .. ":" .. tostring(otherId)
						if not seenEdges[edgeKey] then
							seenEdges[edgeKey] = true
							local otherX, otherY = coordinates(spec, otherId, other)
							if otherX then
								local dx, dy = x - otherX, y - otherY
								local length = math.sqrt(dx * dx + dy * dy)
								if length > 0 then edgeLengths[#edgeLengths + 1] = length end
							end
						end
					end
				end
			end
		end
	end
	local medianEdgeLength = median(edgeLengths)
	local minDimension = math.huge
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for id, node in pairs(spec.nodes or { }) do
		local x, y = coordinates(spec, id, node)
		if x then
			minX, maxX = math.min(minX, x), math.max(maxX, x)
			minY, maxY = math.min(minY, y), math.max(maxY, y)
		end
	end
	if minX ~= math.huge then minDimension = math.min(maxX - minX, maxY - minY) end
	local fallbackEdge = medianEdgeLength or (finite(minDimension) and minDimension / 100 or 1)
	local ring = startRingRadius or (finite(minDimension) and minDimension * 0.12 or fallbackEdge * 3)
	-- Include the native class-start ring and two normal links around it. This
	-- makes the central hub a costed spatial transit area, not a virtual edge.
	local radius = ring + fallbackEdge * 2
	if finite(minDimension) and minDimension > 0 then radius = math.min(radius, minDimension * 0.45) end
	return math.max(radius, fallbackEdge), medianEdgeLength, startRingRadius
end

local function classify(x, y, centerX, centerY, hubRadius)
	local dx, dy = x - centerX, y - centerY
	if math.sqrt(dx * dx + dy * dy) <= hubRadius then return "Hub" end
	if x < centerX then
		return y < centerY and "NorthWest" or "SouthWest"
	end
	return y < centerY and "NorthEast" or "SouthEast"
end

function spatialZones.CanonicalRegionName(name)
	if type(name) ~= "string" then return nil end
	return regionAliases[name:lower()]
end

function spatialZones.Classify(x, y, metadata)
	if not metadata or not finite(x) or not finite(y)
		or not finite(metadata.centerX) or not finite(metadata.centerY)
		or not finite(metadata.hubRadius) then
		return nil
	end
	return classify(x, y, metadata.centerX, metadata.centerY, metadata.hubRadius)
end

function spatialZones.Build(spec)
	if not spec or type(spec.nodes) ~= "table" or not spec.tree then
		return nil, nil, "The active PoB passive graph is unavailable for spatial partitioning"
	end
	local centerX, centerY, classStarts = getCenter(spec)
	if not centerX or not centerY then
		return nil, nil, "PoB did not provide usable coordinates for any passive-tree node"
	end
	local hubRadius, medianEdgeLength, startRingRadius = getHubRadius(spec, centerX, centerY, classStarts)
	local ids = orderedIds(spec.nodes)
	local regionByNode, unresolved = { }, { }
	local counts = { Hub = 0, NorthWest = 0, NorthEast = 0, SouthWest = 0, SouthEast = 0 }
	for _, id in ipairs(ids) do
		local node = spec.nodes[id]
		local x, y = coordinates(spec, id, node)
		if x then
			local region = classify(x, y, centerX, centerY, hubRadius)
			regionByNode[id] = region
			counts[region] = counts[region] + 1
		else
			unresolved[#unresolved + 1] = id
		end
	end

	-- Some version-specific virtual nodes can omit their own coordinates while
	-- remaining linked to positioned nodes. Inherit the nearest positioned
	-- neighbor's zone using stable node ordering; never silently invent edges.
	if #unresolved > 0 then
		local queue = { }
		for _, id in ipairs(ids) do
			if regionByNode[id] then queue[#queue + 1] = id end
		end
		local cursor = 1
		while cursor <= #queue do
			local id = queue[cursor]
			cursor = cursor + 1
			local node = spec.nodes[id]
			local neighbors = { }
			for _, link in ipairs(node and node.linked or { }) do
				local otherId = linkedId(link)
				if spec.nodes[otherId] and not regionByNode[otherId] then neighbors[#neighbors + 1] = otherId end
			end
			t_sort(neighbors, function(a, b) return tostring(a) < tostring(b) end)
			for _, otherId in ipairs(neighbors) do
				regionByNode[otherId] = regionByNode[id]
				counts[regionByNode[id]] = counts[regionByNode[id]] + 1
				queue[#queue + 1] = otherId
			end
		end
	end

	local unassigned = #ids - (counts.Hub + counts.NorthWest + counts.NorthEast + counts.SouthWest + counts.SouthEast)
	local metadata = {
		partitionVersion = "spatial-v1",
		treeVersion = tostring(spec.treeVersion or spec.tree.version or "unknown"),
		totalNodeCount = #ids,
		assignedNodeCount = #ids - unassigned,
		unassignedNodeCount = unassigned,
		counts = counts,
		centerX = centerX,
		centerY = centerY,
		hubRadius = hubRadius,
		medianEdgeLength = medianEdgeLength,
		classStartRingRadius = startRingRadius,
	}
	if unassigned > 0 then
		return nil, metadata, string.format("Spatial partition cannot classify %d of %d active PoB nodes", unassigned, #ids)
	end
	return regionByNode, metadata
end

function spatialZones.RegionNames()
	local names = { }
	for name in pairs(regionOrder) do names[#names + 1] = name end
	t_sort(names, function(a, b) return regionOrder[a] < regionOrder[b] end)
	return names
end

return spatialZones
