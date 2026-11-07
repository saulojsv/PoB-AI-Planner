-- Bounded, hash-verified intake for a user-selected local Path of Building XML.
-- This module does not grant rights or create training labels; it only returns
-- structurally valid source XML for the isolated native importer.
local ingestion = { }
local MAX_ARCHIVE_XML_BYTES = 16 * 1024 * 1024

local function validSha256(value)
	return type(value) == "string" and #value == 64 and value:match("^%x+$") ~= nil
end

local function readBounded(path)
	if type(path) ~= "string" or path == "" or #path > 32760 or path:find("[%z\r\n]") then
		return nil, "invalid_xml_path"
	end
	local file, openError = io.open(path, "rb")
	if not file then return nil, "xml_open_failed: " .. tostring(openError or "open failed"):sub(1, 160) end
	local size = file:seek("end")
	if not size then file:close(); return nil, "xml_size_unavailable" end
	if size < 1 then file:close(); return nil, "empty_xml" end
	if size > MAX_ARCHIVE_XML_BYTES then file:close(); return nil, "xml_too_large" end
	if not file:seek("set", 0) then file:close(); return nil, "xml_seek_failed" end
	local contents = file:read(MAX_ARCHIVE_XML_BYTES + 1)
	local closeOk, closeError = file:close()
	if type(contents) ~= "string" or contents == "" then return nil, "xml_read_failed" end
	if #contents > MAX_ARCHIVE_XML_BYTES then return nil, "xml_too_large" end
	if #contents ~= size then return nil, "xml_changed_during_read" end
	if closeOk == nil then return nil, "xml_close_failed: " .. tostring(closeError or "close failed"):sub(1, 120) end
	return contents
end

function ingestion.Read(record, importLifecycle, sha, readFile)
	if type(record) ~= "table" or record.sourceFormat ~= "pob_xml" then return nil, "unsupported_source_format" end
	if not validSha256(record.sourceXmlSha256) then return nil, "invalid_source_xml_sha256" end
	if type(importLifecycle) ~= "table" or type(importLifecycle.ValidateXML) ~= "function"
		or type(sha) ~= "table" or type(sha.sha256) ~= "function" then
		return nil, "xml_validation_runtime_unavailable"
	end
	local xmlText, readError = (readFile or readBounded)(record.sourceXmlPath)
	if not xmlText then return nil, readError end
	if type(xmlText) ~= "string" or #xmlText < 1 or #xmlText > MAX_ARCHIVE_XML_BYTES then
		return nil, "xml_too_large_or_empty"
	end
	if sha.sha256(xmlText):lower() ~= record.sourceXmlSha256:lower() then return nil, "source_xml_sha256_mismatch" end
	local coverage, validationError = importLifecycle.ValidateXML(xmlText)
	if not coverage then return nil, validationError or "invalid_xml" end
	return xmlText, coverage
end

ingestion.MAX_ARCHIVE_XML_BYTES = MAX_ARCHIVE_XML_BYTES
return ingestion
