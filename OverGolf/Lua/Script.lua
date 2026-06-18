-- GolfServer.lua
-- Place in: ServerScriptService

local Players           = game:GetService("Players")
local ServerStorage     = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

-- Dependencies:
--   - ReplicatedStorage.GolfShared.GolfConfig
--   - ReplicatedStorage.GolfShared.GolfRemotes
--   - ReplicatedStorage.GolfShared.GolfScoring
local GolfShared = ReplicatedStorage:WaitForChild("GolfShared")
local GolfConfig = require(GolfShared:WaitForChild("GolfConfig"))
local GolfRemotes = require(GolfShared:WaitForChild("GolfRemotes"))
local GolfScoring = require(GolfShared:WaitForChild("GolfScoring"))

-- ─────────────────────────────────────────
-- RemoteEvents
-- ─────────────────────────────────────────
local Remotes = GolfRemotes.GetAllServer()
local SwingEvent            = Remotes.SwingEvent
local BallReadyEvent        = Remotes.BallReady
local ClearEvent            = Remotes.ClearEvent
local GoalAnimEvent         = Remotes.GoalAnim
local TrackBallEvent        = Remotes.TrackBallEvent
local WallHitEvent          = Remotes.WallHitEvent
local SlotAssignEvent       = Remotes.SlotAssign
local GoalResultEvent       = Remotes.GoalResult
local ScoreboardUpdateEvent = Remotes.ScoreboardUpdate
local StartGameEvent        = Remotes.StartGame

-- ─────────────────────────────────────────
-- 슬롯 관리 (최대 6명)
-- ─────────────────────────────────────────
local MAX_SLOTS   = GolfConfig.MAX_SLOTS
local playerSlots = {} -- slotNumber(1~6) -> UserId
local userSlots   = {} -- UserId -> slotNumber

local function assignSlot(player)
	for i = 1, MAX_SLOTS do
		if not playerSlots[i] then
			playerSlots[i] = player.UserId
			userSlots[player.UserId] = i
			return i
		end
	end
	return nil
end

local function releaseSlot(player)
	local slot = userSlots[player.UserId]
	if slot then
		playerSlots[slot] = nil
		userSlots[player.UserId] = nil
	end
end

local function broadcastSlots()
	local slotData = {}
	for slot, uid in pairs(playerSlots) do
		local p = Players:GetPlayerByUserId(uid)
		slotData[slot] = p and p.Name or "?"
	end
	for _, p in ipairs(Players:GetPlayers()) do
		SlotAssignEvent:FireClient(p, slotData, userSlots[p.UserId] or 0)
	end
end

-- ─────────────────────────────────────────
-- 스코어 추적
-- ─────────────────────────────────────────
local playerScores = {} -- UserId -> { [holeNumber] = swingCount }

local function broadcastScoreboard()
	local data = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local slot = userSlots[p.UserId]
		if slot then
			local scores = playerScores[p.UserId] or {}
			local total  = 0
			for _, s in pairs(scores) do total = total + s end
			data[slot] = {
				name   = p.Name,
				slot   = slot,
				userId = p.UserId,
				scores = scores,
				total  = total,
			}
		end
	end
	for _, p in ipairs(Players:GetPlayers()) do
		ScoreboardUpdateEvent:FireClient(p, data)
	end
end

-- ─────────────────────────────────────────
-- 벽 충돌 사운드
-- ─────────────────────────────────────────
local function setupBallCollision(ball, player)
	local lastHitTime = 0
	local HIT_COOLDOWN = 0.2

	ball.Touched:Connect(function(hit)
		if hit.Name == "Wall" then
			local currentTime = os.clock()
			if currentTime - lastHitTime > HIT_COOLDOWN then
				lastHitTime = currentTime
				WallHitEvent:FireClient(player)
			end
		end
	end)
end

-- ─────────────────────────────────────────
-- Player data
-- ─────────────────────────────────────────
local playerData = {}
local playerBalls = {} -- UserId -> SimulationBall owned by that player

-- ─────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────
local MAX_HOLE            = GolfConfig.MAX_HOLE
local SUCTION_Y_THRESHOLD = GolfConfig.SUCTION_Y_THRESHOLD

local function randomCFrameInsidePart(part)
	local s  = part.Size
	local rx = (math.random() - 0.5) * s.X * 0.7
	local rz = (math.random() - 0.5) * s.Z * 0.7
	local ry = s.Y * 0.5 + 2
	return part.CFrame * CFrame.new(rx, ry, rz)
end

local function placePhysicalBallAt(player, data, cf)
	local ballTemplate2 = ServerStorage:WaitForChild("Ball2")
	local ball2         = ballTemplate2:Clone()
	ball2.Name          = "PhysicalBall_" .. tostring(player.UserId)
	ball2.CFrame        = cf
	ball2.Anchored      = true   -- ✅ false → true
	ball2.CanCollide    = true
	ball2.Parent        = Workspace

local function placeSimulationBallAt(player, data, cf)
	local ball = getPlayerBall(player)
	if not ball or not ball.Parent then
		return nil
	end

	ball:Stop()
	ball:SetPlaybackTime(0)
	ball.CFrame = cf

	data.activeBall = ball
	data.isSimulating = false

	return ball
end

local setupBallForPlayer

local function playGoalSuctionAnim(ball, startPos, goalPos)
	local STEPS = 30
	local INTERVAL = 1 / 30

	for i = 1, STEPS do
		if not ball or not ball.Parent then break end
		local t = i / STEPS
		local xzT = math.log(1 + t * 9) / math.log(10)
		local newX = startPos.X + (goalPos.X - startPos.X) * xzT
		local newZ = startPos.Z + (goalPos.Z - startPos.Z) * xzT
		local newY = startPos.Y
		ball.CFrame = CFrame.new(newX, newY, newZ)
		task.wait(INTERVAL)
	end
end

local function triggerGoal(player, data, stoppedPos)
	if data.cleared then return end
	data.cleared  = true
	data.swinging = true

	if data.goalConnection then
		data.goalConnection:Disconnect()
		data.goalConnection = nil
	end

	local ball    = data.activeBall
	local goalPos = data.goalPart.Position

	-- ─── 스코어 기록 ───
	local clearedHole = data.currentHole
	local swings      = data.swingCount or 0
	local elapsed     = os.clock() - (data.holeStartTime or os.clock())

	if not playerScores[player.UserId] then
		playerScores[player.UserId] = {}
	end
	playerScores[player.UserId][clearedHole] = swings

	local term, exp, point = GolfScoring.GetScoreInfo(swings, clearedHole)

	-- ─── 결과 전송 (GoalAnim과 동시에) ───
	GoalResultEvent:FireClient(player, {
		hole    = clearedHole,
		swings  = swings,
		elapsed = elapsed,
		term    = term,
		exp     = exp,
		point   = point,
	})
	GoalAnimEvent:FireClient(player, data.goalPart)

	task.wait(1.5)

	if ball and ball.Parent then
		local yDiff = stoppedPos.Y - goalPos.Y
		if yDiff > SUCTION_Y_THRESHOLD then
			playGoalSuctionAnim(ball, stoppedPos, goalPos)
		end
		task.wait(0.2)
		ball:Stop()
		ball:SetPlaybackTime(0)
	end

	playerData[player.UserId] = nil
	ClearEvent:FireClient(player, clearedHole)

	-- 스코어보드 전체 브로드캐스트
	broadcastScoreboard()

	local nextHole = clearedHole + 1
	if nextHole > MAX_HOLE then nextHole = 1 end

	-- ✅ 최종 홀이면 스코어보드 충분히 보여준 뒤 hole 1로
	local delayTime = (clearedHole == MAX_HOLE) and GolfConfig.FINAL_HOLE_DELAY or GolfConfig.NEXT_HOLE_DELAY

	-- 클라이언트에서 Result(3.5s) + Scoreboard(3s) = 약 6.5s 이후 다음 홀 준비
	-- BallReadyEvent가 blockBar 중 도착해도 pendingBarShow로 처리됨
	task.delay(delayTime, function()
		local char = player.Character or player.CharacterAdded:Wait(10)
		if not char then return end
		setupBallForPlayer(player, char, nextHole)
	end)
end

setupBallForPlayer = function(player, character, targetHole)
	targetHole = targetHole or 1

	local prev = playerData[player.UserId]
	if prev and prev.activeBall and prev.activeBall.Parent then
		prev.activeBall:Stop()
		prev.activeBall:SetPlaybackTime(0)
	end
	playerData[player.UserId] = nil

	local humanoid = character:WaitForChild("Humanoid")
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0

	local hrp = character:WaitForChild("HumanoidRootPart")
	hrp.Anchored = true

	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BasePart") or desc:IsA("MeshPart") then
			--desc.Transparency = 1
			desc.CanCollide   = false
		end
	end

	local holeFolder = Workspace:WaitForChild("Holes"):WaitForChild("Hole" .. tostring(targetHole))
	local startPart  = holeFolder:WaitForChild("Start")
	local goalPart   = holeFolder:WaitForChild("Goal")
	local spawnCF    = randomCFrameInsidePart(startPart)

	local data = {
		activeBall     = nil,
		isSimulating   = false,
		lastCFrame     = spawnCF,
		goalPart       = goalPart,
		startPart      = startPart,
		swinging       = false,
		cleared        = false,
		currentHole    = targetHole,
		goalConnection = nil,
		swingCount     = 0,            -- 타수 카운터
		holeStartTime  = os.clock(),   -- 홀 시작 시각
	}
	playerData[player.UserId] = data

	local ball = placeSimulationBallAt(player, data, spawnCF)
	if not ball then
		playerData[player.UserId] = nil
		return
	end

	task.wait(GolfConfig.BALL_READY_DELAY)
	if playerData[player.UserId] == data and ball and ball.Parent then
		BallReadyEvent:FireClient(player, ball.Name, true)
	end

	task.spawn(function()
		while data and data.activeBall and data.activeBall.Parent and playerData[player.UserId] == data do
			task.wait(0.2)
			if data.cleared then break end
	
				local ball = data.activeBall
				local currentPos = ball.BallCFrame.Position
				if playerData[player.UserId] ~= data then break end
		
				-- ✅ 다른 홀 필드 체크
				local rayResult = workspace:Raycast(
					currentPos + Vector3.new(0, 5, 0),
					Vector3.new(0, -20, 0)
				)
				local skipGoalCheck = false
				if rayResult and rayResult.Instance then
					local parent = rayResult.Instance.Parent
					local parentName = parent and parent.Name or ""
					local hitHoleNum = parentName:match("^Hole(%d+)$")
					if hitHoleNum and tonumber(hitHoleNum) ~= data.currentHole then
						if not data.swinging then
							data.activeBall:Stop()
							data.activeBall.CFrame = data.lastCFrame
							data.activeBall:SetPlaybackTime(0)
							BallReadyEvent:FireClient(player, data.activeBall.Name, true)
						end
						skipGoalCheck = true
					end
				end
	
			-- 기존 골 판정
			if not skipGoalCheck then
				local gPart   = data.goalPart
				local gRadius = math.min(gPart.Size.X, gPart.Size.Z) / 2 * 0.6
				local rel     = gPart.CFrame:PointToObjectSpace(currentPos)
				local dist2D  = math.sqrt(rel.X^2 + rel.Z^2)
		
				if dist2D <= gRadius and currentPos.Y < gPart.Position.Y + 2 and currentPos.Y > gPart.Position.Y - 50 then
					triggerGoal(player, data, currentPos)
				elseif data.currentHole == 18 then
					-- ✅ hole 18은 Goal 파트에 닿기만 하면 골
					local rel18  = gPart.CFrame:PointToObjectSpace(currentPos)
					local halfX  = gPart.Size.X / 2
					local halfZ  = gPart.Size.Z / 2
					if math.abs(rel18.X) <= halfX and math.abs(rel18.Z) <= halfZ
						and currentPos.Y < gPart.Position.Y + 10
						and currentPos.Y > gPart.Position.Y - 50 then
						triggerGoal(player, data, currentPos)
					end
					elseif currentPos.Y < -150 then
						if not data.swinging then
							data.activeBall:Stop()
							data.activeBall.CFrame = data.lastCFrame
							data.activeBall:SetPlaybackTime(0)
							BallReadyEvent:FireClient(player, data.activeBall.Name, true)
						end
					end
			end
		end
	end)
end

Players.PlayerAdded:Connect(function(player)
	assignSlot(player)
	playerScores[player.UserId] = {}
	broadcastSlots()
end)

Players.PlayerRemoving:Connect(function(player)
	local data = playerData[player.UserId]
	if data and data.activeBall and data.activeBall.Parent then
		data.activeBall:Destroy()
	end
	playerData[player.UserId] = nil
	playerScores[player.UserId] = nil
	releaseSlot(player)
	broadcastSlots()
	broadcastScoreboard()
end)

StartGameEvent.OnServerEvent:Connect(function(player)
	local character = player.Character
	if character then
		-- 이때 플레이어의 캐릭터를 투명하게 만들고 1번 홀 공을 세팅합니다.
		task.spawn(setupBallForPlayer, player, character, 1)
	end
end)

-- ─────────────────────────────────────────
-- Swing Event
-- ─────────────────────────────────────────
SwingEvent.OnServerEvent:Connect(function(player, direction, power)
	local data = playerData[player.UserId]
	if not data or data.swinging or data.cleared then return end
	if not data.activeBall or not data.activeBall.Parent then return end

	data.swingCount = (data.swingCount or 0) + 1
	data.swinging = true

	local ball = data.activeBall
	-- 첫 샷 직후에는 BallCFrame 갱신이 늦을 수 있어 서버가 저장한 안정 위치를 우선 사용합니다.
	local startCFrame = data.lastCFrame or ball.CFrame or ball.BallCFrame
	local startPos = startCFrame.Position
	local dir = Vector3.new(direction.X, 0, direction.Z)
	if dir.Magnitude < 0.001 then dir = Vector3.new(0, 0, -1) end
	dir = dir.Unit

	local startCF = CFrame.lookAt(startPos + Vector3.new(0, 3, 0), dir * 10, Vector3.yAxis)
	local oldBall = data.activeBall

	if oldBall then
		oldBall.Anchored = true
		oldBall.CanCollide = false
	end

	local ballTemplate = ServerStorage:WaitForChild("Ball")
	local simBall = ballTemplate:Clone()

	wait(0.1)
	simBall.Parent = game.Workspace
	simBall:Stop()
	simBall.Name = "SimBall_" .. tostring(player.UserId)
	simBall.CFrame = startCF
	simBall.Transparency = 0

	wait(0.2)

	setupBallCollision(simBall, player)
	simBall.EnablePathMarker = true

	data.activeBall = simBall
	data.isSimulating = true

	local ratio = math.clamp(power / 100, 0, 1)
	local swingSpeed = GolfConfig.SWING_POWER_MULTIPLIER * ratio
	simBall.CFrame = CFrame.lookAt(startCF.Position, startCF.Position + dir * 10, Vector3.yAxis)

	local Params = BallSimParams.new()
	Params.Mass = 0.9
	Params.BaseGravity = 3200
	Params.Restitution = 0.2
	Params.Friction = 1
	Params.DampingLinear = 0.012
	--Params.Simsteps = GolfConfig.SIMULATION_STEPS
	--Params.DeltaTime = GolfConfig.SIMULATION_DELTA_TIME
	--Params.InitialCFrame = simBall.CFrame
	Params.InitialSpeed = 100

	if oldBall then
		oldBall:Destroy()
	end

	simBall:Simulate(Params)
	task.wait(0.3)

	local function finishSwingAndSwapToPhysical(finalCFrame, isReset)
		if playerData[player.UserId] == data and not data.cleared then
			local safePos = finalCFrame.Position + Vector3.new(0, 0.15, 0)
			local flatCF = CFrame.new(safePos) * finalCFrame.Rotation
			data.lastCFrame = flatCF

			if data.activeBall then
				data.activeBall:Destroy()
			end

			local newPhysBall = placePhysicalBallAt(player, data, flatCF)
			data.swinging = false
			BallReadyEvent:FireClient(player, newPhysBall.Name, isReset)

			task.delay(GolfConfig.PHYSICAL_BALL_UNANCHOR_DELAY, function()
				if newPhysBall and newPhysBall.Parent then
					newPhysBall.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
					newPhysBall.Anchored = false
				end
			end)
		end
	end

	TrackBallEvent:FireClient(player, simBall.Name)


	if simBall and simBall.Parent then
		simBall:Play()
	end
	simBall.Paused:Wait()

	
	if not simBall or not simBall.Parent then
		if playerData[player.UserId] == data and not data.cleared then
			data.swinging = false
			if data.activeBall and data.activeBall.Parent then
				BallReadyEvent:FireClient(player, data.activeBall.Name, false)
			end
		end
		return
	end

	local finalCF = simBall.BallCFrame
	if not finalCF then
		finalCF = data.lastCFrame
	end

	local goalPart = data.goalPart
	local goalRadius = math.min(goalPart.Size.X, goalPart.Size.Z) / 2 * 0.25
	local rel = goalPart.CFrame:PointToObjectSpace(finalCF.Position)
	local dist2D = math.sqrt(rel.X^2 + rel.Z^2)
	local isGoal = dist2D <= goalRadius

	if isGoal then
		if playerData[player.UserId] == data and not data.cleared then
			triggerGoal(player, data, finalCF.Position)
		end
	else
		finishSwingAndSwapToPhysical(finalCF, false)
	end

end)