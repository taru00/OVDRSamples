-- GolfRemotes.lua
-- Dependencies:
--   - GolfConfig
-- Centralizes RemoteEvent names and lookup/creation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GolfConfig = require(script.Parent:WaitForChild("GolfConfig"))

local GolfRemotes = {}

function GolfRemotes.GetFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("GolfEvents")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "GolfEvents"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

function GolfRemotes.GetOrCreate(name: string): RemoteEvent
	local folder = GolfRemotes.GetFolder()
	local event = folder:FindFirstChild(name)
	if not event then
		event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = folder
	end
	return event :: RemoteEvent
end

function GolfRemotes.WaitFor(name: string): RemoteEvent
	return GolfRemotes.GetFolder():WaitForChild(name) :: RemoteEvent
end

function GolfRemotes.GetAllServer(): {[string]: RemoteEvent}
	local events: {[string]: RemoteEvent} = {}
	for key, name in pairs(GolfConfig.EVENT_NAMES) do
		events[key] = GolfRemotes.GetOrCreate(name)
	end
	return events
end

function GolfRemotes.GetAllClient(): {[string]: RemoteEvent}
	local events: {[string]: RemoteEvent} = {}
	for key, name in pairs(GolfConfig.EVENT_NAMES) do
		events[key] = GolfRemotes.WaitFor(name)
	end
	return events
end

return GolfRemotes