--[[
	CHARACTER CONTROLLER MANAGER
	
	A robust two-phase loading system for modular character controllers.
	
	PHASE 1 - CONSTRUCTION (.new):
		- Modules are required and constructors called.
		- Controllers are stored in the manager but should NOT reference other controllers yet.
	
	PHASE 2 - INITIALIZATION (:Initialize):
		- Called automatically after ALL controllers are constructed.
		- Safe to use Manager:GetController() here.
]]

-- SERVICES
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- PACKAGES
local Packages = ReplicatedStorage.Packages
local Janitor = require(Packages.Janitor)

-- TYPES
-- Definition for a Controller instance
type Controller = {
	Initialize: (self: Controller) -> ()?, -- Optional initialization method
	Destroy: (self: Controller) -> ()?, -- Optional cleanup method
	Manager: ControllerManager, -- Reference back to the manager
	[any]: any,
}

-- Definition for the Controller Module (the ModuleScript returning a table)
type ControllerConstructor = (Character: Model, Manager: ControllerManager) -> Controller

type ControllerModule = {
	new: ControllerConstructor?,
	New: ControllerConstructor?,
	RetryInterval: number?, -- Optional: Override retry time for this module
	[any]: any,
}

-- Definition for the Manager itself
type ControllerManager = {
	__index: ControllerManager,
	new: (ControllerFolders: { Folder | ModuleScript }, Options: { [string]: any }?) -> ControllerManager,
	GetController: (self: ControllerManager, Character: Model, Name: string) -> Controller?,
	Load: (self: ControllerManager, Character: Model) -> ({ [string]: Controller }, { [string]: any }),
	DestroyForCharacter: (self: ControllerManager, Character: Model) -> (),
	Destroy: (self: ControllerManager) -> (),

	-- Internal
	_TryLoadModule: (self: ControllerManager, ModuleScript: ModuleScript, Character: Model) -> any,
	_InitializeControllers: (self: ControllerManager, Character: Model) -> (),
}

-- Metatable
local ControllerManager = {}
ControllerManager.__index = ControllerManager

--[[
	Constructor for the ControllerManager.
	@param ControllerFolders: A list of Folders containing ModuleScripts or individual ModuleScripts to load.
	@param Options: Configuration table { MaxRetries: number, RetryInterval: number, KickOnFailure: boolean }.
]]
function ControllerManager.new(ControllerFolders: { Folder | ModuleScript }, Options: { [string]: any }?)
	local self = setmetatable({}, ControllerManager)

	self.ControllerFolders = ControllerFolders or {}
	self.LoadingCharacters = {} -- Tracks characters currently being loaded to prevent double loading

	Options = Options or {}
	self.MaxRetries = Options.MaxRetries or 5
	self.RetryInterval = Options.RetryInterval or (60 / 5) -- Default: 12 seconds
	self.KickOnFailure = if Options.KickOnFailure ~= nil then Options.KickOnFailure else true
	self.DevMode = RunService:IsStudio()

	-- Storage
	-- We use weak keys ("k") so that if the Character is destroyed/nil, the entry is automatically allowed to be garbage collected
	self.ControllersByCharacter = setmetatable({}, { __mode = "k" })
	self.Janitors = setmetatable({}, { __mode = "k" })

	return self
end

--[[
	Retrieves a loaded controller instance for a specific character.
	Use this inside :Initialize() methods to talk to other controllers.
	@param Character: The character model.
	@param Name: The name of the controller module (e.g., "MovementController").
]]

function ControllerManager:GetController(Character: Model, Name: string): Controller?
	local Dict = self.ControllersByCharacter[Character]
	return if Dict then Dict[Name] else nil -- Returns the controller instance if found, otherwise nil
end

--[[
	Internal: Attempts to require and instantiate a single controller module.
	Handles retries if the module fails to load (e.g. waiting for dependencies).
]]
function ControllerManager:_TryLoadModule(ModuleScript: ModuleScript, Character: Model)
	local Entry = {
		Name = ModuleScript.Name,
		Time = 0,
		Loaded = false,
		Error = nil :: string?,
		Attempts = 0,
	}

	local StartTime = os.clock()
	local CurrentRetryInterval = self.RetryInterval

	if self.DevMode then
		print(string.format("[Module: %s] Starting load", Entry.Name))
	end

	for Attempt = 1, self.MaxRetries do
		Entry.Attempts = Attempt

		local Success, Result = pcall(function()
			local Module = require(ModuleScript) :: ControllerModule
			local Constructor = Module.New or Module.new

			if type(Constructor) ~= "function" then
				error("Missing .new() or .New() constructor")
			end

			-- Modules can request a custom retry interval
			if Module.RetryInterval then
				CurrentRetryInterval = Module.RetryInterval
			end

			-- Instantiate the controller
			local Instance = Constructor(Character, self)
			if not Instance then
				error("Constructor returned nil")
			end

			Instance.Manager = self

			-- Register the controller instance in our dictionary
			local CharacterControllers = self.ControllersByCharacter[Character]
			if not CharacterControllers then
				CharacterControllers = {}
				self.ControllersByCharacter[Character] = CharacterControllers
			end
			CharacterControllers[Entry.Name] = Instance

			-- If the controller has a Destroy/Cleanup method, register it with the Janitor
			if type(Instance.Destroy) == "function" then
				self.Janitors[Character]:Add(Instance, "Destroy")
			end

			return true
		end)

		-- If the module loaded successfully, mark it as loaded and break out of the loop
		if Success then
			Entry.Loaded = true
			if self.DevMode then
				print(string.format("[Module: %s] Loaded on attempt %d", Entry.Name, Attempt))
			end
			break
		else
			-- If the module failed to load, store the error and continue to the next attempt
			Entry.Error = tostring(Result)
			warn(string.format("[Module: %s] Attempt %d failed: %s", Entry.Name, Attempt, Entry.Error))

			-- Wait before retrying, unless it's the last attempt
			if Attempt < self.MaxRetries then
				task.wait(CurrentRetryInterval)
			end
		end
	end

	Entry.Time = os.clock() - StartTime
	return Entry
end

--[[
	Internal: Calls :Initialize() on all loaded controllers for a character.
	This is the second phase of loading.
]]
function ControllerManager:_InitializeControllers(Character: Model)
	local Controllers = self.ControllersByCharacter[Character]
	if not Controllers then
		return
	end

	if self.DevMode then
		print(string.format("[ControllerManager] Initializing for %s...", Character.Name))
	end

	-- Initialize each controller
	for Name, Controller in pairs(Controllers) do
		if type(Controller.Initialize) == "function" then
			local Success, Error = pcall(function()
				Controller:Initialize()
			end)

			if not Success then
				warn(string.format("[ControllerManager] Error initializing %s: %s", Name, tostring(Error)))
			end
		end
	end
end

--[[
	Main entry point: Loads all controllers for a given character.
	Usually called when a character executes logic (e.g. CharacterAdded).
	
	1. Creates a Janitor for cleanup.
	2. Recursively loads all ModuleScripts in the configured folders.
	3. Runs the Initialization phase.
]]
function ControllerManager:Load(Character: Model)
	if self.LoadingCharacters[Character] then
		warn("Already loading controllers for " .. Character.Name)
		return {}, {}
	end

	self.LoadingCharacters[Character] = true

	-- Ensure any previous data for this character is wiped
	self:DestroyForCharacter(Character)

	-- Create lifecycle manager (Janitor) for this character
	local CharJanitor = Janitor.new()
	self.Janitors[Character] = CharJanitor

	-- Auto-cleanup when character is removed from the game hierarchy
	CharJanitor:Add(Character.AncestryChanged:Connect(function()
		if not Character.Parent then
			self:DestroyForCharacter(Character)
		end
	end))

	-- Auto-cleanup when Humanoid dies
	local Humanoid = Character:FindFirstChildOfClass("Humanoid")
	if Humanoid then
		CharJanitor:Add(Humanoid.Died:Connect(function()
			self:DestroyForCharacter(Character)
		end))
	end

	local TotalStart = os.clock()
	local FolderReport = {}
	local TotalModules, TotalLoadedModules = 0, 0
	local FailedModules = {}

	-- Helper function to process individual modules
	local function ProcessModule(ModuleScript: ModuleScript)
		TotalModules += 1
		local Entry = self:_TryLoadModule(ModuleScript, Character)

		if Entry.Loaded then
			TotalLoadedModules += 1
		else
			table.insert(FailedModules, Entry)
		end

		return Entry
	end

	-- Search the folders for ModuleScripts
	for _, Item in ipairs(self.ControllerFolders) do
		if typeof(Item) == "Instance" then
			if Item:IsA("Folder") then
				local Report = {}
				-- Load all children modules in the folder
				for _, Child in ipairs(Item:GetChildren()) do
					if Child:IsA("ModuleScript") then
						table.insert(Report, ProcessModule(Child))
					end
				end
				FolderReport[Item.Name] = Report
			elseif Item:IsA("ModuleScript") then
				-- Load single module if passed directly
				FolderReport[Item.Name] = { ProcessModule(Item) }
			end
		end
	end

	-- Phase 2: Initialize
	if TotalLoadedModules > 0 then
		self:_InitializeControllers(Character)
	end

	-- Reporting results
	if #FailedModules > 0 then
		warn(string.format("[ControllerManager] Loaded %d/%d (Failures detected)", TotalLoadedModules, TotalModules))

		-- Kick player if critical failure is detected (Production only)
		local Player = Players:GetPlayerFromCharacter(Character)
		if self.KickOnFailure and Player and not self.DevMode then
			local ErrorList = {}
			for _, Fail in ipairs(FailedModules) do
				table.insert(ErrorList, string.format("%s: %s", Fail.Name, Fail.Error or "Unknown"))
			end
			Player:Kick("Failed to load required game modules:\n" .. table.concat(ErrorList, "\n"))
		end
	else
		-- Success block
		if self.DevMode then
			print(
				string.format(
					"[ControllerManager] Loaded %d/%d successfully in %.4fs",
					TotalLoadedModules,
					TotalModules,
					os.clock() - TotalStart
				)
			)
		end
	end

	self.LoadingCharacters[Character] = nil
	return self.ControllersByCharacter[Character] or {}, FolderReport
end

--[[
	Cleans up all controllers and logic associated with a specific character.
	This is called automatically on death/removing, but can be called manually.
]]
function ControllerManager:DestroyForCharacter(Character: Model)
	local CharJanitor = self.Janitors[Character]
	if CharJanitor then
		CharJanitor:Destroy() -- This destroys all controllers added to the Janitor
		self.Janitors[Character] = nil
	end
	self.ControllersByCharacter[Character] = nil
end

--[[
	Full cleanup of the Manager (e.g. when the game is shutting down or the script is destroyed).
]]
function ControllerManager:Destroy()
	for _, CharJanitor in pairs(self.Janitors) do
		CharJanitor:Destroy()
	end
	self.Janitors = {}
	self.ControllersByCharacter = {}
	self.LoadingCharacters = {}

	setmetatable(self, nil)
	table.clear(self)
end

return ControllerManager
