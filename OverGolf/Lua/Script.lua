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

local function printBallState(player, ball, stateName, reason)
	local playerName = player and player.Name or "UnknownPlayer"
	local ballName = ball and ball.Name or "UnknownBall"
	local reasonText = reason and (" | " .. reason) or ""
	print(string.format("[Golf][SimulationBall] player=%s ball=%s state=%s%s", playerName, ballName, stateName, reasonText))
end

local function setupBallStateLogging(ball, player)
	-- SimulationBall 내부 재생 이벤트가 발생할 때마다 실제 상태 변화를 출력합니다.
	ball.Played:Connect(function()
		printBallState(player, ball, "Played", "SimulationBall event")
	end)

	ball.Paused:Connect(function()
		printBallState(player, ball, "Paused", "SimulationBall event")
	end)

	ball.Stopped:Connect(function()
		printBallState(player, ball, "Stopped", "SimulationBall event")
	end)
end

local function stopSimulationBall(player, ball, reason)
	-- Stop 호출은 재생/시뮬레이션 상태를 초기 정지 상태로 바꿉니다.
	printBallState(player, ball, "Stop()", reason)
	ball:Stop()
end

local function setSimulationBallPlaybackTime(player, ball, playbackTime, reason)
	-- PlaybackTime 변경은 현재 재생 커서를 지정 시간으로 이동시킵니다.
	printBallState(player, ball, "SetPlaybackTime(" .. tostring(playbackTime) .. ")", reason)
	ball:SetPlaybackTime(playbackTime)
end

local function setSimulationBallCFrame(player, ball, cf, reason)
	-- CFrame 변경은 다음 시뮬레이션 시작 위치/방향 또는 현재 공 위치를 바꿉니다.
	printBallState(player, ball, "CFrame", reason)
	ball.CFrame = cf
end

local function setSimulationBallPathMarker(player, ball, enabled, reason)
	-- EnablePathMarker 변경은 시뮬레이션 경로 표시 상태를 바꿉니다.
	printBallState(player, ball, "EnablePathMarker=" .. tostring(enabled), reason)
	ball.EnablePathMarker = enabled
end

local function simulateSimulationBall(player, ball, params, reason)
	-- Simulate 호출은 현재 CFrame과 파라미터로 새 궤적 스냅샷을 계산합니다.
	printBallState(player, ball, "Simulate()", reason)
	ball:Simulate(params)
end

local function playSimulationBall(player, ball, reset, reason)
	-- Play 호출은 계산된 궤적 재생 상태로 전환합니다.
	printBallState(player, ball, "Play(" .. tostring(reset) .. ")", reason)
	ball:Play(reset)
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
	stopSimulationBall(player, ball, "initialize cloned ball")
	setSimulationBallPlaybackTime(player, ball, 0, "initialize cloned ball")
	setupBallCollision(ball, player)
	setupBallStateLogging(ball, player)
	playerBalls[player.UserId] = ball

	return ball
end

local function getPlayerBall(player)
	return playerBalls[player.UserId]
end

local function destroyPlayerBall(player)
	local ball = playerBalls[player.UserId]
	if ball and ball.Parent then
		destroySimulationBall(player, ball, "player removing")
	end
	playerBalls[player.UserId] = nil
end

local function placeSimulationBallAt(player, data, cf)
	local ball = getPlayerBall(player)
	if not ball or not ball.Parent then
		return nil
	end

	stopSimulationBall(player, ball, "place ball at hole start")
	setSimulationBallPlaybackTime(player, ball, 0, "place ball at hole start")
	setSimulationBallCFrame(player, ball, cf, "place ball at hole start")

	data.isSimulating = false

	return ball
end

local setupBallForPlayer

local function playGoalSuctionAnim(player, ball, startPos, goalPos)
	local STEPS = 30
	local INTERVAL = 1 / 30

	for i = 1, STEPS do
		if not ball or not ball.Parent then break end
		local t = i / STEPS
		local xzT = math.log(1 + t * 9) / math.log(10)
		local newX = startPos.X + (goalPos.X - startPos.X) * xzT
		local newZ = startPos.Z + (goalPos.Z - startPos.Z) * xzT
		local newY = startPos.Y
		setSimulationBallCFrame(player, ball, CFrame.new(newX, newY, newZ), "goal suction step " .. tostring(i) .. "/" .. tostring(STEPS))
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

	local ball    = getPlayerBall(player)
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
			playGoalSuctionAnim(player, ball, stoppedPos, goalPos)
		end
		task.wait(0.2)
		stopSimulationBall(player, ball, "goal resolved")
		setSimulationBallPlaybackTime(player, ball, 0, "goal resolved")
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
	local ball = getPlayerBall(player)
	if prev and ball and ball.Parent then
		stopSimulationBall(player, ball, "setup new hole")
		setSimulationBallPlaybackTime(player, ball, 0, "setup new hole")
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
		BallReadyEvent:FireClient(player, ball.Name, true)
	end

	task.spawn(function()
		while playerData[player.UserId] == data do
			task.wait(0.2)
			if data.cleared then break end
	
				local ball = getPlayerBall(player)
				if not ball or not ball.Parent then break end

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
							stopSimulationBall(player, ball, "reset from other hole field")
							setSimulationBallCFrame(player, ball, data.lastCFrame, "reset from other hole field")
							setSimulationBallPlaybackTime(player, ball, 0, "reset from other hole field")
							BallReadyEvent:FireClient(player, ball.Name, true)
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
							stopSimulationBall(player, ball, "reset from fall")
							setSimulationBallCFrame(player, ball, data.lastCFrame, "reset from fall")
							setSimulationBallPlaybackTime(player, ball, 0, "reset from fall")
							BallReadyEvent:FireClient(player, ball.Name, true)
						end
					end
			end
		end
	end)
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
	local ball = getPlayerBall(player)
	if not ball or not ball.Parent then return end

	data.swingCount = (data.swingCount or 0) + 1
	data.swinging = true

	-- 첫 샷 직후에는 BallCFrame 갱신이 늦을 수 있어 서버가 저장한 안정 위치를 우선 사용합니다.
	local startCFrame = data.lastCFrame or ball.CFrame or ball.BallCFrame
	local startPos = startCFrame.Position
	local dir = Vector3.new(direction.X, 0, direction.Z)
	if dir.Magnitude < 0.001 then dir = Vector3.new(0, 0, -1) end
	dir = dir.Unit

	local shotOrigin = startPos + Vector3.new(0, 3, 0)
	local startCF = CFrame.lookAt(shotOrigin, shotOrigin + dir * 10, Vector3.yAxis)
	stopSimulationBall(player, ball, "prepare swing")
	setSimulationBallPlaybackTime(player, ball, 0, "prepare swing")
	setSimulationBallCFrame(player, ball, startCF, "prepare swing")
	setSimulationBallPathMarker(player, ball, true, "prepare swing")
	data.isSimulating = true

	local ratio = math.clamp(power / 100, 0, 1)
	local params = ball:GetEditorBallSimParams()
	params.Mass = 0.9
	params.BaseGravity = 3200
	params.DefaultRestitution = 0.2
	params.DefaultFriction = 1
	params.DampingLinear = 0.012
	params.Simsteps = GolfConfig.SIMULATION_STEPS
	params.StepsPerSecond = GolfConfig.SIMULATION_STEPS_PER_SECOND
	params.InitialSpeed = GolfConfig.SWING_POWER_MULTIPLIER * ratio

	simulateSimulationBall(player, ball, params, "swing trajectory")
	TrackBallEvent:FireClient(player, ball.Name)
	playSimulationBall(player, ball, true, "swing trajectory")
	ball.Paused:Wait()

	if playerData[player.UserId] ~= data or data.cleared then return end
	if not ball.Parent then return end

	local finalCF = ball.BallCFrame
	data.lastCFrame = finalCF
	data.isSimulating = false

	local goalPart = data.goalPart
	local goalRadius = math.min(goalPart.Size.X, goalPart.Size.Z) / 2 * 0.25
	local rel = goalPart.CFrame:PointToObjectSpace(finalCF.Position)
	local dist2D = math.sqrt(rel.X^2 + rel.Z^2)
	local isGoal = dist2D <= goalRadius

	if isGoal then
		triggerGoal(player, data, finalCF.Position)
	else
		data.swinging = false
		BallReadyEvent:FireClient(player, ball.Name, false)
	end
end)