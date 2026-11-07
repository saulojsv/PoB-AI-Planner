-- The stock SimpleGraphic font renderer escapes unsupported Unicode, unlike
-- the Unicode-capable HeadlessWrapper/PoeCharm runtime. Adapt presentation only;
-- keep exact snapshots, imported names and persisted data in their original form.
local display = { }
local cachedRenderer, cachedFlag, cachedEvidence
local replacements = {
	["á"] = "a", ["à"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a",
	["Á"] = "A", ["À"] = "A", ["Â"] = "A", ["Ã"] = "A", ["Ä"] = "A",
	["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e",
	["É"] = "E", ["È"] = "E", ["Ê"] = "E", ["Ë"] = "E",
	["í"] = "i", ["ì"] = "i", ["î"] = "i", ["ï"] = "i",
	["Í"] = "I", ["Ì"] = "I", ["Î"] = "I", ["Ï"] = "I",
	["ó"] = "o", ["ò"] = "o", ["ô"] = "o", ["õ"] = "o", ["ö"] = "o",
	["Ó"] = "O", ["Ò"] = "O", ["Ô"] = "O", ["Õ"] = "O", ["Ö"] = "O",
	["ú"] = "u", ["ù"] = "u", ["û"] = "u", ["ü"] = "u",
	["Ú"] = "U", ["Ù"] = "U", ["Û"] = "U", ["Ü"] = "U",
	["ç"] = "c", ["Ç"] = "C", ["ñ"] = "n", ["Ñ"] = "N",
	["—"] = "-", ["–"] = "-", ["→"] = "->", ["Δ"] = "delta",
	["·"] = "-", ["•"] = "*", ["…"] = "...", ["═"] = "=",
}
local rendererGlyphs = { "á", "ç", "ñ", "—", "–", "→", "Δ", "·", "•", "…", "═" }
function display.Evidence()
	local declared = main and main.unicode == true or false
	if cachedEvidence and cachedRenderer == DrawStringWidth and cachedFlag == declared then return cachedEvidence end
	local ok, accented, plain = pcall(function()
		return DrawStringWidth(14, "VAR", "ação"), DrawStringWidth(14, "VAR", "acao")
	end)
	local measured = ok and type(accented) == "number" and type(plain) == "number"
		and accented > 0 and plain > 0 and accented < math.huge and plain < math.huge
	local compatible = declared and measured and accented <= plain * 1.75
	local unsupportedGlyphs = { }
	if compatible then
		for _, glyph in ipairs(rendererGlyphs) do
			local glyphOk, glyphWidth, referenceWidth = pcall(function()
				return DrawStringWidth(14, "VAR", glyph), DrawStringWidth(14, "VAR", "M")
			end)
			local glyphMeasured = glyphOk and type(glyphWidth) == "number" and type(referenceWidth) == "number"
				and glyphWidth > 0 and referenceWidth > 0 and glyphWidth < math.huge and referenceWidth < math.huge
			-- A native em dash/arrow may be wider than one Latin glyph. The renderer's
			-- escaped [U+....] fallback is several times wider than a capital M.
			-- Use a generous bound to avoid converting legitimate typography.
			if not glyphMeasured or glyphWidth > referenceWidth * 2.5 then
				compatible = false
				unsupportedGlyphs[#unsupportedGlyphs + 1] = glyph
			end
		end
	end
	cachedRenderer, cachedFlag = DrawStringWidth, declared
	cachedEvidence = { unicodeDeclared = declared, unicodeWidthCompatible = compatible,
		asciiFallback = not compatible, unsupportedGlyphs = unsupportedGlyphs, source = "native_VAR_font_width_probe" }
	if measured then cachedEvidence.accentedWidth, cachedEvidence.plainWidth = accented, plain end
	return cachedEvidence
end
function display.Native(text)
	if type(text) ~= "string" then return text end
	if display.Evidence().unicodeWidthCompatible then return text end
	return (text:gsub("[%z\1-\127\194-\244][\128-\191]*", function(character)
		return replacements[character] or character
	end))
end
return display
