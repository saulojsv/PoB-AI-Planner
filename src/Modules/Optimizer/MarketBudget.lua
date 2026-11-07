-- Path of Building
--
-- Module: exact equipment-budget gates for optimizer candidates.
-- Market values are external estimates; this module only sums quotes supplied
-- with provenance and never derives a price from item names or modifiers.

local json = require("dkjson")

local market = { }
local MAX_QUOTES = 300
local MAX_AGE_SECONDS = 30 * 60

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function trimmed(value)
	return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
end

local function parseNumber(value)
	local text = trimmed(value):gsub("%s", ""):gsub(",", ".")
	if text == "" then return nil end
	return tonumber(text)
end

local function decodeObject(text, label, maxBytes)
	text = trimmed(text)
	if text == "" then return { }, nil end
	if #text > maxBytes then return nil, label .. " exceeds the " .. tostring(maxBytes) .. "-character limit" end
	local decoded, _, err = json.decode(text)
	local meta = type(decoded) == "table" and getmetatable(decoded)
	if err or type(decoded) ~= "table" or (meta and meta.__jsontype and meta.__jsontype ~= "object") then
		return nil, label .. " must be a JSON object" .. (err and (": " .. tostring(err)) or "")
	end
	return decoded, nil
end

local function normalizeQuote(itemId, quote, mode, defaultSource, defaultLeague)
	if type(quote) ~= "table" then return nil, "price quote for item #" .. tostring(itemId) .. " must be an object" end
	local chaosValue = parseNumber(quote.chaosValue)
	if not isFinite(chaosValue) or chaosValue < 0 or chaosValue > 1000000000 then
		return nil, "price quote for item #" .. tostring(itemId) .. " needs a finite Chaos-equivalent value from 0 to 1000000000"
	end
	local source = tostring(quote.source or defaultSource or "")
	if source ~= "poe.ninja" and source ~= "user" and source ~= "ssf_user" then
		return nil, "price quote for item #" .. tostring(itemId) .. " has an unsupported source"
	end
	if mode == "SSF" and source == "poe.ninja" then
		return nil, "SSF budget cannot use trade-market prices"
	end
	if source == "poe.ninja" then
		local listings = parseNumber(quote.listingCount)
		if not isFinite(listings) or listings < 1 or listings ~= math.floor(listings) then
			return nil, "poe.ninja price for item #" .. tostring(itemId) .. " has no current listing evidence"
		end
		if chaosValue <= 0 then return nil, "poe.ninja price for item #" .. tostring(itemId) .. " is not a positive market estimate" end
	end
	return {
		chaosValue = chaosValue,
		source = source,
		listingCount = source == "poe.ninja" and tonumber(quote.listingCount) or nil,
		league = type(quote.league) == "string" and quote.league:sub(1, 80)
			or type(defaultLeague) == "string" and defaultLeague:sub(1, 80) or nil,
	}
end

function market.Parse(textValues)
	textValues = textValues or { }
	local amountText = trimmed(textValues.currencyBudgetAmount)
	if amountText == "" then return nil, nil end
	local amount = parseNumber(amountText)
	if not isFinite(amount) or amount < 0 or amount > 1000000000 then
		return nil, "Currency budget must be a finite amount from 0 to 1000000000"
	end
	local unit = trimmed(textValues.currencyBudgetUnit)
	if unit == "" then unit = "Chaos" end
	if unit ~= "Chaos" and unit ~= "Divine" then return nil, "Currency budget unit must be Chaos or Divine" end
	local mode = trimmed(textValues.currencyBudgetMode)
	if mode == "" then mode = "Trade" end
	if mode ~= "Trade" and mode ~= "SSF" then return nil, "Currency budget mode must be Trade or SSF" end
	local requestedLeague = trimmed(textValues.currencyBudgetLeague)
	if #requestedLeague > 80 then return nil, "Currency budget league is limited to 80 characters" end
	local manualRate = parseNumber(textValues.currencyBudgetDivineChaosRate)
	if textValues.currencyBudgetDivineChaosRate and trimmed(textValues.currencyBudgetDivineChaosRate) ~= ""
		and (not isFinite(manualRate) or manualRate <= 0 or manualRate > 1000000) then
		return nil, "Divine-to-Chaos rate must be finite and greater than zero"
	end

	local snapshot, snapshotError = decodeObject(textValues.marketQuotesJson, "Market price snapshot", 32768)
	if not snapshot then return nil, snapshotError end
	local manual, manualError = decodeObject(textValues.manualItemPricesJson, "Manual item prices", 16384)
	if not manual then return nil, manualError end
	local source = tostring(snapshot.source or "manual")
	if source ~= "poe.ninja" and source ~= "mixed" and source ~= "manual" and source ~= "ssf_manual" then
		return nil, "Market price snapshot source is unsupported"
	end
	if mode == "Trade" and source == "ssf_manual" then return nil, "An SSF-only price snapshot cannot be used for a Trade budget" end
	if mode == "SSF" and (source == "poe.ninja" or source == "mixed") then source = "ssf_manual" end
	local leagueValue = snapshot.league
	local league = type(leagueValue) == "table" and tostring(leagueValue.id or "") or tostring(leagueValue or "")
	if requestedLeague ~= "" and league ~= "" and requestedLeague ~= league then
		return nil, "Market price snapshot league does not match the selected league"
	end
	local rawQuotes = snapshot.quotes or { }
	if type(rawQuotes) ~= "table" then return nil, "Market price snapshot quotes must be an object" end
	local quotes, quoteCount = { }, 0
	if mode == "Trade" then
		for idText, rawQuote in pairs(rawQuotes) do
			local itemId = tonumber(idText)
			if not itemId or itemId < 1 or itemId ~= math.floor(itemId) or itemId > 2147483647 then
				return nil, "Market quote keys must be positive PoB item IDs"
			end
			local quote, quoteError = normalizeQuote(itemId, rawQuote, mode, source, league)
			if not quote then return nil, quoteError end
			if quote.source == "poe.ninja" and (league == "" or quote.league ~= league) then
				return nil, "A poe.ninja item quote does not match the snapshot league"
			end
			quotes[itemId] = quote
			quoteCount = quoteCount + 1
			if quoteCount > MAX_QUOTES then return nil, "At most 300 item prices can be loaded for one market budget" end
		end
	end
	for idText, rawValue in pairs(manual) do
		local itemId = tonumber(idText)
		if not itemId or itemId < 1 or itemId ~= math.floor(itemId) or itemId > 2147483647 then
			return nil, "Manual price keys must be positive PoB item IDs"
		end
		local chaosValue = parseNumber(rawValue)
		if not isFinite(chaosValue) or chaosValue < 0 or chaosValue > 1000000000 then
			return nil, "Manual Chaos-equivalent prices must be finite values from 0 to 1000000000"
		end
		if not quotes[itemId] then quoteCount = quoteCount + 1 end
		if quoteCount > MAX_QUOTES then return nil, "At most 300 item prices can be loaded for one market budget" end
		quotes[itemId] = { chaosValue = chaosValue, source = mode == "SSF" and "ssf_user" or "user" }
	end

	if mode == "SSF" and source == "ssf_manual" then
		-- Trade-derived prices may be present in a saved snapshot; they are not
		-- admissible in SSF mode, so only the explicit manual map is retained.
		quotes = { }
		quoteCount = 0
		for idText, rawValue in pairs(manual) do
			local itemId = tonumber(idText)
			local chaosValue = parseNumber(rawValue)
			quotes[itemId] = { chaosValue = chaosValue, source = "ssf_user" }
			quoteCount = quoteCount + 1
		end
		source = "ssf_manual"
	end

	local hasTradeQuote = false
	for _, quote in pairs(quotes) do
		if quote.source == "poe.ninja" then hasTradeQuote = true break end
	end
	if mode == "Trade" and (source ~= "manual" or hasTradeQuote) then
		local capturedAt = tonumber(snapshot.capturedAtUnixMs)
		if not isFinite(capturedAt) then return nil, "Trade price snapshot is missing its capture time" end
		local age = os.time() - math.floor(capturedAt / 1000)
		if age < -300 or age > MAX_AGE_SECONDS then return nil, "Trade price snapshot is older than 30 minutes; refresh market prices before optimization" end
		if league == "" then return nil, "Trade price snapshot is missing its league ID" end
	end
	local divineChaosRate = parseNumber(snapshot.divineChaosRate) or manualRate
	if unit == "Divine" and (not isFinite(divineChaosRate) or divineChaosRate <= 0) then
		return nil, "A current Divine-to-Chaos rate is required to normalize this budget"
	end

	return {
		amount = amount,
		unit = unit,
		mode = mode,
		league = league ~= "" and league or requestedLeague,
		requestedLeague = requestedLeague,
		divineChaosRate = divineChaosRate,
		quotes = quotes,
		source = source,
		capturedAtUnixMs = tonumber(snapshot.capturedAtUnixMs),
		provider = tostring(snapshot.provider or source):sub(1, 100),
	}, nil
end

function market.Evaluate(budget, itemEntries)
	if not budget then return { enabled = false, status = "disabled", feasible = true, itemCount = 0 } end
	local totalChaos, missing, itemCount, missingCount = 0, { }, 0, 0
	for _, itemEntry in ipairs(itemEntries or { }) do
		local itemId = tonumber(itemEntry.itemId)
		if itemId and itemId > 0 then
			itemCount = itemCount + 1
			local quote = budget.quotes[itemId]
			if not quote then
				missingCount = missingCount + 1
				if #missing < 32 then
					missing[#missing + 1] = { itemId = itemId, slot = tostring(itemEntry.slot or ""), name = tostring(itemEntry.name or "PoB item"):sub(1, 100) }
				end
			else
				totalChaos = totalChaos + quote.chaosValue
			end
		end
	end
	local result = {
		enabled = true,
		status = "pass",
		feasible = true,
		mode = budget.mode,
		unit = budget.unit,
		league = budget.league,
		source = budget.source,
		provider = budget.provider,
		amount = budget.amount,
		totalChaos = totalChaos,
		itemCount = itemCount,
		pricedItemCount = itemCount - missingCount,
		missingItems = missing,
	}
	if missingCount > 0 then
		result.status = "unsupported"
		result.feasible = false
		result.violations = { {
			key = "currency_budget_price_coverage",
			label = "Equipment price coverage",
			reason = tostring(missingCount) .. " equipped item(s) have no market or manual price; a budget cannot be certified",
			missingItems = missing,
			deficit = math.huge,
		} }
		result.normalizedDeficit = math.huge
		return result
	end
	local total = totalChaos
	local limit = budget.amount
	if budget.unit == "Divine" then
		total = totalChaos / budget.divineChaosRate
		limit = budget.amount
	end
	result.total = total
	result.limit = limit
	result.divineChaosRate = budget.unit == "Divine" and budget.divineChaosRate or nil
	result.withinBudget = total <= limit
	if not result.withinBudget then
		result.status = "violated"
		result.feasible = false
		result.normalizedDeficit = (total - limit) / math.max(limit, 1)
		result.violations = { {
			key = "currency_budget",
			label = "Currency budget",
			actual = total,
			required = limit,
			deficit = total - limit,
			reason = string.format("Estimated equipment cost %.2f %s exceeds the strict %.2f %s budget", total, budget.unit, limit, budget.unit),
		} }
	else
		result.normalizedDeficit = 0
		result.violations = { }
	end
	return result
end

return market
