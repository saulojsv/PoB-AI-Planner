local Inputs = require("Modules.Optimizer.Inputs")
local MarketBudget = require("Modules.Optimizer.MarketBudget")
local json = require("dkjson")

local function snapshot(capturedAtUnixMs)
	return {
		source = "poe.ninja",
		provider = "poe.ninja documented economy overview API",
		league = { id = "poe1-test-league", name = "Test League" },
		capturedAtUnixMs = capturedAtUnixMs or os.time() * 1000,
		divineChaosRate = 200,
		quotes = {
			["101"] = { chaosValue = 400, source = "poe.ninja", listingCount = 2, league = "poe1-test-league" },
			["102"] = { chaosValue = 50, source = "poe.ninja", listingCount = 1, league = "poe1-test-league" },
		},
	}
end

local function encode(value)
	local text, err = json.encode(value)
	assert(text, err)
	return text
end

local function parse(values)
	local parsed, err = MarketBudget.Parse(values)
	assert(parsed, err)
	return parsed
end

describe("Optimizer strict currency budget", function()
	it("leaves the budget disabled when no amount is provided", function()
		local parsed, err = Inputs.Parse({ })
		assert(parsed, err)
		assert(parsed.search.currencyBudget == nil)
		local result = MarketBudget.Evaluate(nil, { { itemId = 101, slot = "Weapon" } })
		assert(result.feasible and result.status == "disabled")
	end)

	it("normalizes estimated trade prices to Divine and applies an exact inclusive cap", function()
		local values = {
			currencyBudgetAmount = "3",
			currencyBudgetUnit = "Divine",
			currencyBudgetMode = "Trade",
			currencyBudgetLeague = "poe1-test-league",
			marketQuotesJson = encode(snapshot()),
		}
		local parsed = parse(values)
		assert(parsed.unit == "Divine" and parsed.league == "poe1-test-league")
		local result = MarketBudget.Evaluate(parsed, { { itemId = 101, slot = "Weapon", name = "Unique Blade" } })
		assert(result.feasible and result.status == "pass")
		assert(result.total == 2 and result.limit == 3)
		assert(result.totalChaos == 400 and result.pricedItemCount == 1)
	end)

	it("accepts compact server-generated quotes while inheriting league provenance", function()
		local data = snapshot()
		for _, quote in pairs(data.quotes) do
			quote.source = nil
			quote.league = nil
		end
		local parsed = parse({ currencyBudgetAmount = "3", marketQuotesJson = encode(data) })
		assert(parsed.quotes[101].source == "poe.ninja")
		assert(parsed.quotes[101].league == "poe1-test-league")
	end)

	it("rejects a strict over-budget result without rounding", function()
		local parsed = parse({
			currencyBudgetAmount = "1.99",
			currencyBudgetUnit = "Divine",
			marketQuotesJson = encode(snapshot()),
		})
		local result = MarketBudget.Evaluate(parsed, { { itemId = 101, slot = "Weapon" } })
		assert(not result.feasible and result.status == "violated")
		assert(result.total == 2 and result.limit == 1.99)
		assert(result.violations[1].key == "currency_budget")
	end)

	it("fails closed when any equipped item lacks a price", function()
		local parsed = parse({ currencyBudgetAmount = "999", marketQuotesJson = encode(snapshot()) })
		local result = MarketBudget.Evaluate(parsed, {
			{ itemId = 101, slot = "Weapon", name = "The Unique" },
			{ itemId = 999, slot = "Helmet", name = "Rare Helmet" },
		})
		assert(not result.feasible and result.status == "unsupported")
		assert(result.pricedItemCount == 1 and result.itemCount == 2)
		assert(result.missingItems[1].itemId == 999)
		assert(result.violations[1].key == "currency_budget_price_coverage")
	end)

	it("rejects league-mismatched and stale trade snapshots", function()
		local mismatched = snapshot()
		mismatched.quotes["101"].league = "another-league"
		local parsed, err = MarketBudget.Parse({ currencyBudgetAmount = "1000", marketQuotesJson = encode(mismatched) })
		assert(parsed == nil and err:find("does not match the snapshot league", 1, true))

		local stale = snapshot((os.time() - 31 * 60) * 1000)
		parsed, err = MarketBudget.Parse({ currencyBudgetAmount = "1000", marketQuotesJson = encode(stale) })
		assert(parsed == nil and err:find("older than 30 minutes", 1, true))
	end)

	it("uses only explicit manual acquisition prices for SSF", function()
		local parsed = parse({
			currencyBudgetAmount = "2",
			currencyBudgetUnit = "Divine",
			currencyBudgetMode = "SSF",
			currencyBudgetDivineChaosRate = "200",
			marketQuotesJson = encode(snapshot()),
			manualItemPricesJson = encode({ ["101"] = 400 }),
		})
		assert(parsed.source == "ssf_manual" and parsed.quotes[101].source == "ssf_user")
		assert(parsed.quotes[102] == nil, "trade estimates must not leak into SSF")
		local result = MarketBudget.Evaluate(parsed, { { itemId = 101, slot = "Weapon" } })
		assert(result.feasible and result.total == 2)
		local uncovered = MarketBudget.Evaluate(parsed, { { itemId = 102, slot = "Helmet" } })
		assert(not uncovered.feasible and uncovered.status == "unsupported")
	end)

	it("requires a supported Divine conversion rate and rejects unsupported sources", function()
		local parsed, err = MarketBudget.Parse({
			currencyBudgetAmount = "2",
			currencyBudgetUnit = "Divine",
			marketQuotesJson = encode({ source = "manual", quotes = { } }),
		})
		assert(parsed == nil and err:find("Divine-to-Chaos rate", 1, true))
		parsed, err = MarketBudget.Parse({
			currencyBudgetAmount = "2",
			currencyBudgetMode = "Trade",
			marketQuotesJson = encode({ source = "ssf_manual", quotes = { } }),
		})
		assert(parsed == nil and err:find("SSF-only", 1, true))
	end)
end)
