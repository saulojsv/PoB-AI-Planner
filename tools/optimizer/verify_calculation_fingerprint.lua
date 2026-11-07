-- Run from the PoB src directory with the repository's LuaJIT runtime.
-- This verifies that every selected calculation file matches manifest.xml
-- and reports the exact versioned content identity used by optimizer studies.
local xml = require("xml")
local Version = require("Modules.Optimizer.Version")
local Fingerprint = require("Modules.Optimizer.ContentFingerprint")

local manifest = assert(xml.LoadXMLFile("../manifest.xml"), "manifest.xml could not be read")
local inventoryFingerprint, identityError = Version.ManifestFingerprint(manifest)
assert(inventoryFingerprint, identityError or "manifest inventory is invalid")
local rows, rowsError = Fingerprint.BuildEntries(manifest)
assert(rows, rowsError or "calculation file inventory is invalid")
local digest, status, fileCount, byteCount, reason = Fingerprint.Compute(rows, {
	default = "..", program = ".", tree = ".", runtime = "../runtime",
}, inventoryFingerprint)
assert(digest and status == "verified", tostring(status) .. ": " .. tostring(reason))
print(string.format("CONTENT_FINGERPRINT %s %d %d %s", status, fileCount, byteCount, digest))
