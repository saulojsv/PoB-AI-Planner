local LocalXML = require("Modules.Optimizer.LocalXMLIngestion")
local Lifecycle = require("Modules.Optimizer.ImportLifecycle")
local sha = require("sha2")

describe("Local PoB XML ingestion boundary", function()
	local tempPath
	local function writeXml(xmlText)
		tempPath = os.tmpname()
		local file = assert(io.open(tempPath, "wb"))
		assert(file:write(xmlText))
		assert(file:close())
		return tempPath
	end
	local function recordFor(xmlText)
		return { sourceFormat = "pob_xml", sourceXmlPath = writeXml(xmlText), sourceXmlSha256 = sha.sha256(xmlText) }
	end

	after_each(function()
		if tempPath then os.remove(tempPath); tempPath = nil end
	end)

	it("reads, hashes and validates local XML using PoB's native framing parser", function()
		local xmlText = '<PathOfBuilding><Build targetVersion="' .. liveTargetVersion .. '"/></PathOfBuilding>'
		local loaded, coverage = LocalXML.Read(recordFor(xmlText), Lifecycle, sha)
		assert.are.equal(xmlText, loaded)
		assert.are.equal(liveTargetVersion, coverage.targetVersion)
		assert.are.equal("pob1_xml_structure_only", coverage.validationScope)
	end)

	it("rejects a source file changed after the manifest hash was recorded", function()
		local original = '<PathOfBuilding><Build targetVersion="' .. liveTargetVersion .. '"/></PathOfBuilding>'
		local record = recordFor(original)
		local file = assert(io.open(tempPath, "wb"))
		assert(file:write(original .. " "))
		assert(file:close())
		local loaded, reason = LocalXML.Read(record, Lifecycle, sha)
		assert.is_nil(loaded)
		assert.are.equal("source_xml_sha256_mismatch", reason)
	end)

	it("rejects invalid framing before native build loading", function()
		local xmlText = "<Other/>"
		local loaded, reason = LocalXML.Read(recordFor(xmlText), Lifecycle, sha)
		assert.is_nil(loaded)
		assert.are.equal("wrong_root", reason)
	end)

	it("rejects oversized local XML before parser or archive use", function()
		local record = { sourceFormat = "pob_xml", sourceXmlPath = "fixture.xml", sourceXmlSha256 = string.rep("a", 64) }
		local parserCalls = 0
		local loaded, reason = LocalXML.Read(record, { ValidateXML = function() parserCalls = parserCalls + 1 end }, sha,
			function() return string.rep("x", LocalXML.MAX_ARCHIVE_XML_BYTES + 1) end)
		assert.is_nil(loaded)
		assert.are.equal("xml_too_large_or_empty", reason)
		assert.are.equal(0, parserCalls)
	end)

	it("accepts only the explicit raw XML source format and a SHA-256 identity", function()
		local record = { sourceFormat = "pob_code", sourceXmlPath = "fixture.xml", sourceXmlSha256 = string.rep("a", 64) }
		local loaded, reason = LocalXML.Read(record, Lifecycle, sha)
		assert.is_nil(loaded)
		assert.are.equal("unsupported_source_format", reason)
		record.sourceFormat = "pob_xml"
		record.sourceXmlSha256 = "invalid"
		loaded, reason = LocalXML.Read(record, Lifecycle, sha)
		assert.is_nil(loaded)
		assert.are.equal("invalid_source_xml_sha256", reason)
	end)
end)
