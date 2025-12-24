--[[CHARACTER CONTROLLER MANAGER USAGE:

THERE IS A TWO PHASE LOADING SYSTEM TO ENSURE ALL CONTROLLERS ARE AVAILABLE:

PHASE 1 - CONSTRUCTION (.new or .New):
	- All controller modules are required and their constructors are called
	- Controllers are stored in the manager but should NOT reference other controllers yet
	- Constructor signature: function Module.new(Character, Manager)

PHASE 2 - INITIALIZATION (.Initialize):
	- Called automatically after ALL controllers are constructed
	- Here YOU USE Manager:GetController(Character, Name) to get references to other controllers
	- Initialization signature: function Controller:Initialize()
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ControllerManager = {}
ControllerManager.__index = ControllerManager

-- Constructor
function ControllerManager.new(ControllerFolders, Options)
	local self = setmetatable({}, ControllerManager)
	self.ControllerFolders = ControllerFolders or {}

	Options = Options or {}
	self.MaxRetries = Options.MaxRetries or 5
	self.RetryInterval = Options.RetryInterval or (60 / 5)
	self.KickOnFailure = Options.KickOnFailure or true
	self.DevMode = RunService:IsStudio()

	-- Weak table to automatically clean up character entries
	self.ControllersByCharacter = setmetatable({}, { __mode = "k" })

	return self
end

-- Get controller
function ControllerManager:GetController(Character, Name)
	local Dict = self.ControllersByCharacter[Character]
	return Dict and Dict[Name] or nil
end

-- Attempt to load a single controller module
function ControllerManager:_TryLoadModule(ModuleScript, Character)
	local Entry = {
		Name = ModuleScript.Name,
		Time = 0,
		Loaded = false,
		Error = nil,
		Attempts = 0,
	}

	local StartTime = os.clock()
	local RetryInterval = self.RetryInterval

	print(
		string.format(
			"[Module: %s] Starting load (%d attempts max, %.2fs default interval)",
			Entry.Name,
			self.MaxRetries,
			self.RetryInterval
		)
	)

	for Attempt = 1, self.MaxRetries do
		Entry.Attempts = Attempt

		local Success, ErrorMessage = pcall(function()
			local Module = require(ModuleScript)
			local Constructor = Module.New or Module.new

			if type(Constructor) ~= "function" then
				error("Missing .new() or .New() constructor")
			end

			RetryInterval = Module.RetryInterval or RetryInterval

			local Instance = Constructor(Character, self)
			if not Instance then
				error("Constructor returned nil")
			end

			Instance.Manager = self

			self.ControllersByCharacter[Character] = self.ControllersByCharacter[Character] or {}
			self.ControllersByCharacter[Character][Entry.Name] = Instance

			Entry.Loaded = true
		end)

		if Success and Entry.Loaded then
			print(string.format("[Module: %s] Loaded successfully on attempt %d", Entry.Name, Attempt))
			break
		else
			Entry.Error = tostring(ErrorMessage)
			warn(string.format("[Module: %s] Attempt %d failed: %s", Entry.Name, Attempt, Entry.Error))

			if Attempt < self.MaxRetries then
				print(
					string.format(
						"[Module: %s] Retrying in %.2fs (%d/%d)...",
						Entry.Name,
						RetryInterval,
						Attempt + 1,
						self.MaxRetries
					)
				)
				task.wait(RetryInterval)
			else
				warn(string.format("[Module: %s] Giving up after %d attempts", Entry.Name, self.MaxRetries))
			end
		end
	end

	Entry.Time = os.clock() - StartTime
	print(string.format("[Module: %s] Load time: %.4fs", Entry.Name, Entry.Time))

	return Entry
end

-- Initialize controllers after all are loaded
function ControllerManager:_InitializeControllers(Character)
	local Controllers = self.ControllersByCharacter[Character]
	if not Controllers then
		return
	end

	print(string.format("[ControllerManager] Initializing controllers for %s...", Character.Name))

	for Name, Controller in pairs(Controllers) do
		if type(Controller.Initialize) == "function" then
			local Success, ErrorMessage = pcall(function()
				Controller:Initialize()
			end)

			if not Success then
				warn(string.format("[ControllerManager] Error initializing %s: %s", Name, ErrorMessage))
			else
				print(string.format("[ControllerManager] Initialized %s successfully", Name))
			end
		end
	end

	print(string.format("[ControllerManager] All controllers initialized for %s", Character.Name))
end

-- Load all modules for a given character
function ControllerManager:Load(Character)
	self:DestroyForCharacter(Character)

	-- Cleanup when character is removed from game
	local AncestryConnection
	AncestryConnection = Character.AncestryChanged:Connect(function()
		if not Character.Parent then
			self:DestroyForCharacter(Character)
			AncestryConnection:Disconnect()
		end
	end)

	-- Cleanup on character death
	local Humanoid = Character:FindFirstChild("Humanoid")
	if Humanoid then
		Humanoid.Died:Connect(function()
			self:DestroyForCharacter(Character)
		end)
	end

	local TotalStart = os.clock()
	local FolderReport = {}
	local TotalModules, TotalLoadedModules = 0, 0
	local FailedModules = {}

	for _, Item in ipairs(self.ControllerFolders) do
		if typeof(Item) == "Instance" then
			if Item:IsA("Folder") then
				print(string.format("\n[Load] Folder: '%s'", Item.Name))
				local Report = {}
				local FolderLoadedCount = 0

				for _, ModuleScript in ipairs(Item:GetChildren()) do
					if ModuleScript:IsA("ModuleScript") then
						TotalModules += 1
						local Entry = self:_TryLoadModule(ModuleScript, Character)
						table.insert(Report, Entry)

						if Entry.Loaded then
							TotalLoadedModules += 1
							FolderLoadedCount += 1
						else
							table.insert(FailedModules, Entry)
						end
					end
				end

				FolderReport[Item.Name] = Report
				print(string.format("[Load] -> %s: %d/%d loaded", Item.Name, FolderLoadedCount, #Report))
			elseif Item:IsA("ModuleScript") then
				-- Handle single ModuleScript passed in the list
				print(string.format("\n[Load] Single Module: '%s'", Item.Name))
				TotalModules += 1
				local Entry = self:_TryLoadModule(Item, Character)

				-- Add to a "SingleModules" report group or just use its name
				FolderReport[Item.Name] = { Entry }

				if Entry.Loaded then
					TotalLoadedModules += 1
					print(string.format("[Load] -> %s: Loaded", Item.Name))
				else
					table.insert(FailedModules, Entry)
					print(string.format("[Load] -> %s: Failed", Item.Name))
				end
			else
				warn(
					string.format(
						"[ControllerManager] Invalid item in ControllerFolders: %s (%s)",
						Item.Name,
						Item.ClassName
					)
				)
			end
		end
	end

	-- Initialize all controllers after loading
	if TotalLoadedModules > 0 then
		self:_InitializeControllers(Character)

		if #FailedModules > 0 then
			warn(
				string.format(
					"[ControllerManager] Initialized %d controllers, but %d failed to load",
					TotalLoadedModules,
					#FailedModules
				)
			)
		end
	end

	-- Print summary
	print("[SUMMARY]")
	if #FailedModules > 0 then
		warn(string.format("Loaded %d/%d modules (with failures)", TotalLoadedModules, TotalModules))
		print("Failed Modules:")
		for _, Entry in ipairs(FailedModules) do
			print(string.format("   - %s (%s)", Entry.Name, Entry.Error or "Unknown"))
		end

		if self.KickOnFailure and not self.DevMode and Character:IsDescendantOf(game) then
			local Player = Players:GetPlayerFromCharacter(Character)
			if Player then
				local Details = {}
				for _, Entry in ipairs(FailedModules) do
					table.insert(
						Details,
						string.format(
							"%s (error: %s; attempts: %d; time: %.2fs)",
							Entry.Name,
							Entry.Error or "nil",
							Entry.Attempts,
							Entry.Time
						)
					)
				end

				local TotalTime = os.clock() - TotalStart
				local Summary = string.format(
					"[ControllerManager] Player: %s | Loaded: %d/%d | Total time: %.2fs",
					Player.Name,
					TotalLoadedModules,
					TotalModules,
					TotalTime
				)

				local KickMessage = Summary .. "\nFailed modules:\n - " .. table.concat(Details, "\n - ")

				Player:Kick(KickMessage)
			end
		elseif self.KickOnFailure and self.DevMode then
			warn("[ControllerManager] DevMode ON — skipping Kick")
		end
	else
		print(string.format("Loaded %d/%d modules (all successful)", TotalLoadedModules, TotalModules))
	end

	print(string.format("Total load time: %.4fs\n", os.clock() - TotalStart))
	return self.ControllersByCharacter[Character] or {}, FolderReport
end

-- Destroy all controllers related to a specific character
function ControllerManager:DestroyForCharacter(Character)
	local Dict = self.ControllersByCharacter[Character]
	if Dict then
		for _, Controller in pairs(Dict) do
			if type(Controller.Destroy) == "function" then
				local Success, ErrorMessage = pcall(function()
					Controller:Destroy()
				end)
				if not Success then
					warn(
						string.format("[ControllerManager] Error destroying %s: %s", tostring(Controller), ErrorMessage)
					)
				end
			end
		end
		self.ControllersByCharacter[Character] = nil
	end
end

-- Destroy all controllers from all characters
function ControllerManager:Destroy()
	for _Character, Dict in pairs(self.ControllersByCharacter) do
		for _, Controller in pairs(Dict) do
			if type(Controller.Destroy) == "function" then
				pcall(function()
					Controller:Destroy()
				end)
			end
		end
	end
	self.ControllersByCharacter = {}

	setmetatable(self, nil)
	table.clear(self)
end

return ControllerManager
