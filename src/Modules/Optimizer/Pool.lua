-- Path of Building
--
-- Module: Optimizer-owned scratch table pool.
-- Never pool engine Env, ModDB, item, or active-skill objects: those have internal
-- references and caches whose reset contract is not public.
--
local pool = { }
local buckets = { }
local active = setmetatable({ }, { __mode = "k" })
local generation = 0

function pool.Acquire(kind)
	local bucket = buckets[kind]
	if not bucket then
		bucket = { }
		buckets[kind] = bucket
	end
	local value = table.remove(bucket) or { }
	generation = generation + 1
	active[value] = generation
	return value, generation
end

function pool.Release(kind, value, lease)
	if active[value] ~= lease then
		error("Optimizer pool lease is stale, duplicated, or belongs to another generation")
	end
	active[value] = nil
	for key in pairs(value) do
		value[key] = nil
	end
	local bucket = buckets[kind]
	if not bucket then
		bucket = { }
		buckets[kind] = bucket
	end
	bucket[#bucket + 1] = value
end

function pool.GetStats()
	local stats = { }
	for kind, bucket in pairs(buckets) do
		stats[kind] = #bucket
	end
	return stats
end

return pool
