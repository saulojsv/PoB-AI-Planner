describe("locally managed PoB release updater guard", function()
	it("compiles the standalone updater guard without starting network access", function()
		local updater, loadError = loadfile("UpdateCheck.lua")
		assert.is_function(updater, tostring(loadError))
	end)

	it("matches the startup guard to the installed release marker", function()
		local scriptPath, fallbackPath = GetScriptPath()
		local root = type(scriptPath) == "string" and scriptPath ~= "" and scriptPath or nil
		if not root and type(fallbackPath) == "string" and fallbackPath ~= "" then root = fallbackPath end
		root = root or "."
		local marker = io.open(root .. "/AIPlannerManaged.release", "rb")
		local exists = marker ~= nil
		if marker then marker:close() end
		assert.are.equal(exists, launch.managedRelease == true)
	end)

	it("does not dispatch an upstream update check", function()
		local oldManaged = launch.managedRelease
		local oldRunning = launch.updateCheckRunning
		local oldBackground = launch.updateCheckBackground
		local oldMessage = launch.updateMsg
		local oldProgress = launch.updateProgress
		local oldLastCheck = launch.lastUpdateCheck
		local oldLaunchSubScript = LaunchSubScript
		launch.managedRelease = true
		LaunchSubScript = function()
			error("managed releases must not start the upstream update script")
		end
		local ok, result = pcall(function() return launch:CheckForUpdate(true) end)
		LaunchSubScript = oldLaunchSubScript
		launch.managedRelease = oldManaged
		launch.updateCheckRunning = oldRunning
		launch.updateCheckBackground = oldBackground
		launch.updateMsg = oldMessage
		launch.updateProgress = oldProgress
		launch.lastUpdateCheck = oldLastCheck
		assert.is_true(ok, tostring(result))
		assert.is_false(result, "managed release checks must stop before invoking the updater")
	end)
end)
