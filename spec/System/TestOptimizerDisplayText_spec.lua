local DisplayText = require("Modules.Optimizer.DisplayText")
local Readiness = require("Modules.Optimizer.BuildReadiness")
local AIChat = require("Modules.Optimizer.AIChat")
local OptimizerTab = require("Classes.OptimizerTab")

describe("AI Planner native font compatibility", function()
	local originalUnicode, originalWidth
	before_each(function() originalUnicode, originalWidth = main.unicode, DrawStringWidth end)
	after_each(function() main.unicode, DrawStringWidth = originalUnicode, originalWidth end)
	it("keeps Unicode-capable presentation and raw text unchanged", function()
		main.unicode = true
		assert.are.equal("Diagnóstico — conversão e ação", DisplayText.Native("Diagnóstico — conversão e ação"))
	end)
	it("adapts Portuguese and planning symbols for the stock native font only", function()
		main.unicode = false
		assert.are.equal("Diagnostico - conversao, acao, Vida -> ES - delta", DisplayText.Native("Diagnóstico — conversão, ação, Vida → ES · Δ"))
		assert.are.equal("^xD8B777Fireball 12.345 - Cold", DisplayText.Native("^xD8B777Fireball 12.345 - Cold"))
	end)
	it("detects escaped glyph widths even when the Lua runtime advertises Unicode", function()
		main.unicode = true
		DrawStringWidth = function(_, _, text) return text == "ação" and 120 or 24 end
		local evidence = DisplayText.Evidence()
		assert.is_true(evidence.unicodeDeclared)
		assert.is_false(evidence.unicodeWidthCompatible)
		assert.is_true(evidence.asciiFallback)
		assert.are.equal("Diagnostico", DisplayText.Native("Diagnóstico"))
	end)
	it("detects an escaped punctuation glyph independently of accented-letter support", function()
		main.unicode = true
		DrawStringWidth = function(_, _, text)
			if text == "—" then return 80 end
			return 20
		end
		local evidence = DisplayText.Evidence()
		assert.is_false(evidence.unicodeWidthCompatible)
		assert.is_true(evidence.asciiFallback)
		assert.are.equal("AI Planner - Build Direction", DisplayText.Native("AI Planner — Build Direction"))
	end)
	it("wraps readable native overview rows while preserving accented evidence in the report", function()
		main.unicode = false
		newBuild()
		local tab = build.optimizerTab
		tab.width, tab.height = 716, 530
		tab:Layout({ width = 716, height = 530 })
		local report = tab:RefreshReadiness(true)
		assert.are.equal("Combinar", tab.controls.pageOverview.label)
		assert.are.equal("Opcoes avancadas", tab.controls.overviewAdvanced.label)
		assert.are.equal("Atualizar detalhes", tab.controls.overviewRefresh.label)
		assert.is_false(tab.controls.overviewAdvanced:IsShown(), "redundant advanced shortcut stays out of the focused overview")
		assert.is_false(tab.controls.overviewRefresh:IsShown(), "readiness refreshes automatically while the overview is visible")
		for _, row in ipairs(tab.controls.overviewReport.list) do
			assert.is_nil(row[1]:find("[\128-\255]"), "The native renderer must not expand Portuguese into [U+....] labels")
		end
		assert.is_truthy(table.concat(Readiness.Describe(report), "\n"):find("Configuração", 1, true),
			"The evidence/report text must retain its original Unicode")
	end)
	it("adapts transcript display without rewriting the conversation sent to ChatGPT", function()
		main.unicode = false
		local chat = setmetatable({ messages = { { role = "assistant", text = "Conversão, ação e proteção — 123 DPS" } }, draft = "" }, { __index = AIChat })
		local rendered = chat:RenderTranscript(800, 400)
		assert.is_truthy(rendered:find("Conversao, acao e protecao - 123 DPS", 1, true))
		assert.are.equal("Conversão, ação e proteção — 123 DPS", chat.messages[1].text)
	end)
	it("keeps exact result rows readable when the native font escapes planning symbols", function()
		main.unicode = true
		DrawStringWidth = function(_, _, text)
			if text == "—" or text == "→" or text == "Δ" then return 80 end
			return 20
		end
		local tab = {
			textValues = { },
			result = {
				status = "feasible",
				evaluation = { metrics = { FullDPS = 10 }, candidateLabel = "candidate — exact" },
				searchBaseline = { exact = true, metrics = { FullDPS = 5 }, label = "baseline — exact", feasible = true, violationCount = 0 },
			},
		}
		local rows = OptimizerTab.FormatResultDetails(tab, 760)
		local rendered = { }
		for _, row in ipairs(rows) do rendered[#rendered + 1] = row[1] end
		local text = table.concat(rendered, "\n")
		assert.is_truthy(text:find("baseline - exact", 1, true))
		assert.is_truthy(text:find("candidate - exact", 1, true))
		assert.is_truthy(text:find("Full DPS: 5 -> 10 (delta +5)", 1, true))
		assert.is_nil(text:find("FullDPS", 1, true), "metric rows should use a readable label instead of an internal key")
		assert.is_nil(text:find("[\128-\255]"), "result rows must not display escaped UTF-8 codepoint markers")
	end)
	it("renders native route deltas from shortest round-trip decimals", function()
		main.unicode = true
		local metrics = { CombinedDPS = 17833023.80824, TotalEHP = 193613.14890955 }
		local candidate = {
			nodeIds = { 1 }, sourceSignature = "decimal-delta-fixture",
			evaluation = {
				feasible = true, objective = "CombinedDPS", candidateLabel = "exact route",
				metrics = metrics, metricDelta = { CombinedDPS = 418884.4200229 },
			},
		}
		local tab = {
			textValues = { objectiveMetric = "CombinedDPS" },
			result = {
				status = "feasible", routePlanner = true, objectiveMetric = "CombinedDPS",
				sourceSignature = "decimal-delta-fixture", candidate = candidate,
				evaluation = candidate.evaluation, paretoFront = { candidate },
				searchBaseline = {
					exact = true, feasible = true, violationCount = 0, label = "exact baseline",
					metrics = { CombinedDPS = 17414139.388218, TotalEHP = 188174.08853846 },
				},
			},
		}
		local rows = OptimizerTab.FormatResultDetails(tab, 900, candidate)
		local rendered = { }
		for _, row in ipairs(rows) do rendered[#rendered + 1] = row[1] end
		local text = table.concat(rendered, "\n")
		assert.is_truthy(text:find("17,414,139.388218 -> 17,833,023.80824", 1, true), text)
		assert.is_truthy(text:find("418,884.420022", 1, true), text)
		assert.is_truthy(text:find("5,439.06037109", 1, true), text)
		assert.is_nil(text:find("418,884.4200229", 1, true), "route display must not expose binary-float subtraction artifacts")
	end)
end)
