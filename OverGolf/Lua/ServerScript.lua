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
local BallReadyEvent        = Remotes.BallReady
local ClearEvent            = Remotes.ClearEvent
local GoalAnimEvent         = Remotes.GoalAnim
local WallHitEvent          = Remotes.WallHitEvent
local SlotAssignEvent       = Remotes.SlotAssign
local GoalResultEvent       = Remotes.GoalResult
local ScoreboardUpdateEvent = Remotes.ScoreboardUpdate
local StartGameEvent        = Remotes.StartGame
local GoalReachedEvent      = Remotes.GoalReached

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
		print("[Server][Network] Send SlotAssign player=" .. p.Name .. " | slot=" .. tostring(userSlots[p.UserId] or 0))
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
		print("[Server][Network] Send ScoreboardUpdate player=" .. p.Name)
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
				print("[Server][Network] Send WallHitEvent player=" .. player.Name)
				WallHitEvent:FireClient(player)
			end
		end
	end)
end

local function printBallState(player, ball, stateName, reason)
	local playerName = player and player.Name or "UnknownPlayer"
	local reasonText = reason and (" | " .. reason) or ""
	print(string.format("[Server][SimulationBall] player=%s state=%s%s", playerName, stateName, reasonText))
end

local function setupBallStateLogging(ball, player)
	-- SimulationBall 내부 재생 이벤트가 발생할 때마다 실제 상태 변화를 출력합니다.
	ball.Played:Connect(function()
		printBallState(player, ball, "Played", "SimulationBall event")
	end)

	ball.Bounded:Connect(function(otherInstance, bounce)
		local otherName = otherInstance and otherInstance.Name or "nil"
		local parentName = (otherInstance and otherInstance.Parent) and otherInstance.Parent.Name or "nil"
		local hitPos = bounce and bounce.BouncedPosition
		local normal = bounce and bounce.ImpactNormal
		print(string.format(
			"[Server][SimulationBall] player=%s state=Bounded other=%s parent=%s pos=(%.3f, %.3f, %.3f) normal=(%.3f, %.3f, %.3f) bounced=%s sliding=%s",
			player.Name,
			tostring(otherName),
			tostring(parentName),
			hitPos and hitPos.X or 0, hitPos and hitPos.Y or 0, hitPos and hitPos.Z or 0,
			normal and normal.X or 0, normal and normal.Y or 0, normal and normal.Z or 0,
			tostring(bounce and bounce.IsBouncedHit),
			tostring(bounce and bounce.IsSlidingHit)
		))
	end)

	ball.Paused:Connect(function()
		printBallState(player, ball, "Paused", "SimulationBall event")
	end)

	ball.Stopped:Connect(function()
		printBallState(player, ball, "Stopped", "SimulationBall event")
	end)
end

local function destroySimulationBall(player, ball, reason)
	-- Destroy 호출은 플레이어 소유 SimulationBall 인스턴스를 제거합니다.
	printBallState(player, ball, "Destroy()", reason)
	ball:Destroy()
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

local function createPlayerBall(player)
	local oldBall = playerBalls[player.UserId]
	if oldBall and oldBall.Parent then
		destroySimulationBall(player, oldBall, "replace old player ball")
	end

	local ballTemplate = ServerStorage:WaitForChild("Ball")
	local ball = ballTemplate:Clone()
	ball.Name = "GolfBall_" .. tostring(player.UserId)
	ball.Parent = Workspace
	setupBallCollision(ball, player)
	setupBallStateLogging(ball, player)
	playerBalls[player.UserId] = ball
	print("[Server][Game] CreatePlayerBall player=" .. player.Name .. " stored=true")

	return ball
end

local function getServerPlayerBall(player)
	return playerBalls[player.UserId]
end

local function destroyPlayerBall(player)
	local ball = playerBalls[player.UserId]
	if ball and ball.Parent then
		destroySimulationBall(player, ball, "player removing")
	end
	playerBalls[player.UserId] = nil
	print("[Server][Game] DestroyPlayerBall player=" .. player.Name .. " stored=false")
end

local function placeSimulationBallAt(player, data, cf)
	local ball = getServerPlayerBall(player)
	if not ball or not ball.Parent then
		print("[Server][Game] PlaceBallFailed player=" .. player.Name)
		return nil
	end

	print(string.format(
		"[Server][Game] PlaceBallAtStart player=%s hole=%s pos=(%.3f, %.3f, %.3f)",
		player.Name,
		tostring(data.currentHole),
		cf.Position.X, cf.Position.Y, cf.Position.Z
	))
	data.isSimulating = false

	return ball
end

local setupBallForPlayer

local function triggerGoal(player, data, stoppedPos)
	if data.cleared then return end
	data.cleared  = true
	data.swinging = true

	if data.goalConnection then
		data.goalConnection:Disconnect()
		data.goalConnection = nil
	end

	local goalPos = data.goalPart.Position

	-- ─── 스코어 기록 ───
	local clearedHole = data.currentHole
	local swings      = data.swingCount or 0
	local elapsed     = os.clock() - (data.holeStartTime or os.clock())
	print(string.format(
		"[Server][Game] GoalDetected player=%s hole=%s pos=(%.3f, %.3f, %.3f)",
		player.Name,
		tostring(clearedHole),
		stoppedPos.X, stoppedPos.Y, stoppedPos.Z
	))

	if not playerScores[player.UserId] then
		playerScores[player.UserId] = {}
	end
	playerScores[player.UserId][clearedHole] = swings

	local term, exp, point = GolfScoring.GetScoreInfo(swings, clearedHole)
	print(string.format(
		"[Server][Game] ScoreRecorded player=%s hole=%s swings=%s term=%s elapsed=%.3f",
		player.Name,
		tostring(clearedHole),
		tostring(swings),
		tostring(term),
		elapsed
	))

	-- ─── 결과 전송 (GoalAnim과 동시에) ───
	print("[Server][Network] Send GoalResult player=" .. player.Name .. " | hole=" .. tostring(clearedHole) .. " swings=" .. tostring(swings))
	GoalResultEvent:FireClient(player, {
		hole    = clearedHole,
		swings  = swings,
		elapsed = elapsed,
		term    = term,
		exp     = exp,
		point   = point,
	})
	print("[Server][Network] Send GoalAnim player=" .. player.Name .. " | goal=" .. tostring(data.goalPart and data.goalPart.Name))
	GoalAnimEvent:FireClient(player, data.goalPart)

	task.wait(1.5)

	task.wait(2.7)

	playerData[player.UserId] = nil
	print("[Server][Network] Send ClearEvent player=" .. player.Name .. " | hole=" .. tostring(clearedHole))
	ClearEvent:FireClient(player, clearedHole)

	-- 스코어보드 전체 브로드캐스트
	broadcastScoreboard()

	local nextHole = clearedHole + 1
	if nextHole > MAX_HOLE then nextHole = 1 end

	-- ✅ 최종 홀이면 스코어보드 충분히 보여준 뒤 hole 1로
	local delayTime = (clearedHole == MAX_HOLE) and GolfConfig.FINAL_HOLE_DELAY or GolfConfig.NEXT_HOLE_DELAY
	print("[Server][Game] ScheduleNextHole player=" .. player.Name .. " fromHole=" .. tostring(clearedHole) .. " nextHole=" .. tostring(nextHole) .. " delay=" .. tostring(delayTime))

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
	print("[Server][Game] SetupHole player=" .. player.Name .. " hole=" .. tostring(targetHole))

	local prev = playerData[player.UserId]
	local ball = getServerPlayerBall(player)
	if prev and ball and ball.Parent then
		print("[Server][Game] ResetPreviousHoleBall player=" .. player.Name .. " hole=" .. tostring(prev.currentHole))
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
		print("[Server][Network] Send BallReady player=" .. player.Name .. " | snapCamera=true")
		BallReadyEvent:FireClient(player, ball.Name, true, targetHole, spawnCF)
	end
end

Players.PlayerAdded:Connect(function(player)
	assignSlot(player)
	playerScores[player.UserId] = {}
	createPlayerBall(player)
	broadcastSlots()
end)

Players.PlayerRemoving:Connect(function(player)
	playerData[player.UserId] = nil
	playerScores[player.UserId] = nil
	destroyPlayerBall(player)
	releaseSlot(player)
	broadcastSlots()
	broadcastScoreboard()
end)

StartGameEvent.OnServerEvent:Connect(function(player)
	print("[Server][Network] Receive StartGame player=" .. player.Name)
	local character = player.Character
	if character then
		-- 이때 플레이어의 캐릭터를 투명하게 만들고 1번 홀 공을 세팅합니다.
		task.spawn(setupBallForPlayer, player, character, 1)
	end
end)

GoalReachedEvent.OnServerEvent:Connect(function(player, stoppedPos, swingCount)
	print("[Server][Network] Receive GoalReached player=" .. player.Name .. " | swings=" .. tostring(swingCount))
	local data = playerData[player.UserId]
	if not data or data.cleared then return end

	data.swingCount = tonumber(swingCount) or data.swingCount or 0
	triggerGoal(player, data, stoppedPos)
end)
