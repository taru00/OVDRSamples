-- GolfClient.lua
-- Place in: StarterPlayerScripts

wait(2)

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

-- Dependencies:
--   - ReplicatedStorage.GolfShared.GolfConfig
--   - ReplicatedStorage.GolfShared.GolfRemotes
local GolfShared = ReplicatedStorage:WaitForChild("GolfShared")
local GolfConfig = require(GolfShared:WaitForChild("GolfConfig"))
local GolfRemotes = require(GolfShared:WaitForChild("GolfRemotes"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local Remotes = GolfRemotes.GetAllClient()
local BallReadyEvent        = Remotes.BallReady
local ClearEvent            = Remotes.ClearEvent
local GoalAnimEvent         = Remotes.GoalAnim
local WallHitEvent          = Remotes.WallHitEvent
local SlotAssignEvent       = Remotes.SlotAssign
local GoalResultEvent       = Remotes.GoalResult
local ScoreboardUpdateEvent = Remotes.ScoreboardUpdate
local StartGameEvent        = Remotes.StartGame
local GoalReachedEvent      = Remotes.GoalReached

local playerGui   = player:WaitForChild("PlayerGui")
local screenGui   = playerGui:WaitForChild("ScreenGui")
local bar         = screenGui:WaitForChild("Bar")
local tutorial	  = screenGui:WaitForChild("Tutorial")
local hitbox      = bar:WaitForChild("Hitbox")
local powerFrame  = bar:WaitForChild("Power")
local percentageU = bar:WaitForChild("PercentageU")
local percentageD = bar:WaitForChild("PercentageD")
local swingButton = bar:WaitForChild("Swing")

-- Result UI 요소
local resultGui   = screenGui:WaitForChild("Result")
local resultText  = resultGui:WaitForChild("Result")   -- 타수 & 용어
local timerText   = resultGui:WaitForChild("Timer")    -- 경과 시간
local rankWidget  = resultGui:WaitForChild("RANK")
local expWidget   = resultGui:WaitForChild("EXP")
local pointWidget = resultGui:WaitForChild("POINT")

-- Scoreboard UI
local scoreboardGui = screenGui:WaitForChild("Scoreboard")
local playButton  = screenGui:WaitForChild("PlayButton")

-- ─────────────────────────────────────────
-- 로비 / 게임 시작
-- ─────────────────────────────────────────
playButton.Activated:Connect(function()
	-- 버튼을 숨깁니다.
	playButton.Visible = false
	tutorial.Visible = false
	
	-- 서버에 게임을 시작하라고 신호를 보냅니다.
	print("[Client][Network] Send StartGame")
	StartGameEvent:FireServer()
end)

tutorial.Visible = true
playButton.Visible = true

local tutorialIndex = 1

local tutorialLeft = screenGui:WaitForChild("Tutorial"):WaitForChild("Left")
local tutorialRight = screenGui:WaitForChild("Tutorial"):WaitForChild("Right")

tutorialLeft.Activated:Connect(function()
	if tutorialIndex == 1 then
		return
	else
		tutorialIndex = tutorialIndex - 1
	end
	
	for i = 1, 3, 1 do
		tutorial:WaitForChild(tostring(i)).Visible = false
		tutorial:WaitForChild(tostring(i).."Text").Visible = false
	end
	
	tutorial:WaitForChild(tostring(tutorialIndex)).Visible = true
	tutorial:WaitForChild(tostring(tutorialIndex).."Text").Visible = true
end)

tutorialRight.Activated:Connect(function()
	if tutorialIndex == 3 then
		return
	else
		tutorialIndex = tutorialIndex + 1
	end
	
	for i = 1, 3, 1 do
		tutorial:WaitForChild(tostring(i)).Visible = false
		tutorial:WaitForChild(tostring(i).."Text").Visible = false
	end
	
	tutorial:WaitForChild(tostring(tutorialIndex)).Visible = true
	tutorial:WaitForChild(tostring(tutorialIndex).."Text").Visible = true
end)

-- ─────────────────────────────────────────
-- 사운드
-- ─────────────────────────────────────────
local soundsFolder = workspace:WaitForChild("Sounds")
local soundPower20  = soundsFolder:WaitForChild("Power20")
local soundPower40  = soundsFolder:WaitForChild("Power40")
local soundPower60  = soundsFolder:WaitForChild("Power60")
local soundPower80  = soundsFolder:WaitForChild("Power80")
local soundPower100 = soundsFolder:WaitForChild("Power100")
local soundGoal     = soundsFolder:WaitForChild("Goal")
local soundWall     = soundsFolder:WaitForChild("Wall")

-- ─────────────────────────────────────────
-- State
-- ─────────────────────────────────────────
local playerBall          = nil
local playerBallSignalConnections = {}
local canSwing            = false
local currentPower        = 50
local aimDir              = Vector3.new(0, 0, -1)
local isGoalAnim          = false
local goalCamTargetCFrame = nil
local currentHole         = nil
local currentGoalPart     = nil
local lastBallCFrame      = nil
local localSwingCount     = 0
local goalReportSent      = false

local blockBar          = false  -- Result/Scoreboard 표시 중 bar 억제
local pendingBarShow    = false  -- blockBar 해제 시 bar 올릴 예약
local lastScoreboardData = nil  -- 최신 스코어보드 전체 데이터
local destroyDirectionIndicator = nil

-- 팝업 애니메이션용 원본 사이즈 캐시 (최초 1회 저장)
local rankOrigSize  = nil
local expOrigSize   = nil
local pointOrigSize = nil

local cameraTarget = Instance.new("Part")
cameraTarget.Name        = "CameraTargetDummy"
cameraTarget.Transparency = 1
cameraTarget.CanCollide  = false
cameraTarget.CanQuery    = false
cameraTarget.Anchored    = true
cameraTarget.Size        = Vector3.new(1, 1, 1)
cameraTarget.Parent      = workspace

-- ─────────────────────────────────────────
-- 헬퍼
-- ─────────────────────────────────────────
local function formatTime(seconds)
	local totalMs = math.floor(seconds * 1000)
	local ms      = totalMs % 1000
	local totalS  = math.floor(totalMs / 1000)
	local s       = totalS % 60
	local m       = math.floor(totalS / 60)
	if m > 0 then
		return string.format("%dm %ds %dms", m, s, ms)
	else
		return string.format("%ds %dms", s, ms)
	end
end

-- 위젯을 0,0,0,0 → 원본 사이즈로 팝업
local function popupWidget(widget, origSize)
	widget.Visible = true
	widget.Size    = UDim2.new(0, 0, 0, 0)
	TweenService:Create(widget,
		TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = origSize }
	):Play()
end

-- ─────────────────────────────────────────
-- 파워 바
-- ─────────────────────────────────────────
local function setPowerBarVisible(isVisible)
	local targetYScale = isVisible and 0.95 or 1.5
	TweenService:Create(bar,
		TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
		{ Position = UDim2.new(bar.Position.X.Scale, bar.Position.X.Offset, targetYScale, bar.Position.Y.Offset) }
	):Play()
end

local function setPowerFromRelX(relX)
	relX         = math.clamp(relX, 0, 1)
	currentPower = math.max(1, relX * 100)
	powerFrame.Size = UDim2.new(1 - (currentPower / 100), 0, powerFrame.Size.Y.Scale, 0)
	local str = string.format("%.2f", currentPower) .. "%"
	percentageU.Text = str
	percentageD.Text = str
end

local function getBarRelX(screenPos)
	local ap = hitbox.AbsolutePosition
	local as = hitbox.AbsoluteSize
	if as.X == 0 then return 0.5 end
	return (screenPos.X - ap.X) / as.X
end

setPowerFromRelX(0.5)
local isDraggingBar = false

hitbox.InputBegan:Connect(function(input)
	if not canSwing then return end
	local t = input.UserInputType
	if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
		isDraggingBar = true
		setPowerFromRelX(getBarRelX(input.Position))
	end
end)
hitbox.InputChanged:Connect(function(input)
	if not isDraggingBar then return end
	local t = input.UserInputType
	if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseMovement then
		setPowerFromRelX(getBarRelX(input.Position))
	end
end)
hitbox.InputEnded:Connect(function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
		isDraggingBar = false
	end
end)

-- ─────────────────────────────────────────
-- 스코어보드 표시
-- ─────────────────────────────────────────
local function showScoreboard()
	local data = lastScoreboardData

	-- 총점 오름차순 정렬
	local sorted = {}
	if data then
		for _, pData in pairs(data) do
			table.insert(sorted, pData)
		end
		table.sort(sorted, function(a, b) return a.total < b.total end)
	end

	-- P1~P6 슬롯을 순위 순서로 채우기
	for rank = 1, GolfConfig.MAX_SLOTS do
		local pData    = sorted[rank]
		local nameLbl  = scoreboardGui:FindFirstChild("P" .. rank .. "Name")
		local totalLbl = scoreboardGui:FindFirstChild("P" .. rank .. "Total")
		local linePart = scoreboardGui:FindFirstChild("P" .. rank .. "Line")

		if pData then
			if nameLbl  then nameLbl.Text  = pData.name            ; nameLbl.Visible  = true end
			if totalLbl then totalLbl.Text = tostring(pData.total) ; totalLbl.Visible = true end

			-- 홀별 스코어 표시
			for hole = 1, GolfConfig.MAX_HOLE do
				local holeLbl = scoreboardGui:FindFirstChild("P" .. rank .. "-" .. hole)
				if holeLbl then
					holeLbl.Text    = pData.scores[hole] and tostring(pData.scores[hole]) or "-"
					holeLbl.Visible = true
				end
			end

			-- 내 행 강조 (PxLine)
			if linePart then
				linePart.Visible = (pData.userId == player.UserId)
			end
		else
			-- 빈 순위 슬롯 숨기기
			if nameLbl  then nameLbl.Visible  = false end
			if totalLbl then totalLbl.Visible = false end
			if linePart then linePart.Visible = false end
			for hole = 1, GolfConfig.MAX_HOLE do
				local holeLbl = scoreboardGui:FindFirstChild("P" .. rank .. "-" .. hole)
				if holeLbl then holeLbl.Visible = false end
			end
		end
	end

	scoreboardGui.Visible = true

	-- 3초 뒤 스코어보드 닫고 다음 홀 Bar 해제
	task.delay(3, function()
		scoreboardGui.Visible = false
		blockBar = false
		if pendingBarShow then
			pendingBarShow = false
			setPowerBarVisible(true)
		end
	end)
end

local function placeLocalBallAt(ball, cf, reason)
	if not ball or not cf then return end
	local pos = cf.Position
	print(string.format(
		"[Client][SimulationBall] PlaceLocalBall reason=%s cframePos=(%.3f, %.3f, %.3f)",
		tostring(reason),
		pos.X, pos.Y, pos.Z
	))
	pcall(function() ball:Stop() end)
	pcall(function() ball:SetPlaybackTime(0) end)
	pcall(function() ball.CFrame = cf end)
end

local function playLocalGoalSuction(ball, goalPart)
	if not ball or not goalPart then return end

	local ok, ballCFrame = pcall(function()
		return ball.BallCFrame
	end)
	if not ok or not ballCFrame then return end

	local startPos = ballCFrame.Position
	local goalPos = goalPart.Position
	local yDiff = startPos.Y - goalPos.Y
	if yDiff <= GolfConfig.SUCTION_Y_THRESHOLD then
		pcall(function() ball:Stop() end)
		pcall(function() ball:SetPlaybackTime(0) end)
		return
	end

	local STEPS = 30
	local INTERVAL = 1 / 30
	for i = 1, STEPS do
		if playerBall ~= ball then break end
		local t = i / STEPS
		local xzT = math.log(1 + t * 9) / math.log(10)
		local newX = startPos.X + (goalPos.X - startPos.X) * xzT
		local newZ = startPos.Z + (goalPos.Z - startPos.Z) * xzT
		local newY = startPos.Y
		pcall(function()
			ball.CFrame = CFrame.new(newX, newY, newZ)
		end)
		task.wait(INTERVAL)
	end

	pcall(function() ball:Stop() end)
	pcall(function() ball:SetPlaybackTime(0) end)
end

-- ─────────────────────────────────────────
-- 스윙
-- ─────────────────────────────────────────
local function doSwing()
	if not canSwing or not playerBall then return end

	local hasBallCFrame, ballCFrame = pcall(function()
		return playerBall.BallCFrame
	end)
	if not hasBallCFrame or not ballCFrame then
		playerBall = nil
		return
	end

	canSwing = false
	localSwingCount = localSwingCount + 1
	setPowerBarVisible(false)

	if currentPower <= 10 then
		soundPower20:Play()
	elseif currentPower <= 30 then
		soundPower40:Play()
	elseif currentPower <= 60 then
		soundPower60:Play()
	elseif currentPower <= 80 then
		soundPower80:Play()
	else
		soundPower100:Play()
	end

	local shotDir = aimDir
	local shotOrigin = ballCFrame.Position + Vector3.new(0, 3, 0)
	local startCF = CFrame.lookAt(shotOrigin, shotOrigin + shotDir * 10, Vector3.yAxis)
	local swingDetail = string.format(
		"power=%.2f dir=(%.3f, %.3f, %.3f) pos=(%.3f, %.3f, %.3f)",
		currentPower,
		shotDir.X, shotDir.Y, shotDir.Z,
		shotOrigin.X, shotOrigin.Y, shotOrigin.Z
	)

	print("[Client][SimulationBall] LocalSwing | " .. swingDetail)
	playerBall:Stop()
	playerBall:SetPlaybackTime(0)
	playerBall.CFrame = startCF
	playerBall.EnablePathMarker = true

	local ratio = math.clamp(currentPower / 100, 0, 1)
	local params = playerBall:GetEditorBallSimParams()
	params.Simsteps = GolfConfig.SIMULATION_STEPS
	params.StepsPerSecond = GolfConfig.SIMULATION_STEPS_PER_SECOND
	params.InitialSpeed = GolfConfig.SWING_POWER_MULTIPLIER * ratio

	playerBall:Simulate(params)
	playerBall:Play(true)

	local swingBall = playerBall
	task.spawn(function()
		local POLL_INTERVAL = 0.1
		local TIMEOUT_SECONDS = 10.0
		local elapsed = 0.0
		local slept = false

		while elapsed < TIMEOUT_SECONDS do
			-- Early-Out: 현재 스윙 중인 공이 바뀌면 이전 폴링은 더 이상 유효하지 않습니다.
			if playerBall ~= swingBall then return end

			-- Early-Out: 공 위치를 읽지 못하면 골인/정지 판정을 신뢰할 수 없으므로 폴링을 중단합니다.
			local ballOk, ballCFrame = pcall(function()
				return swingBall.BallCFrame
			end)
			if not ballOk or not ballCFrame then return end

			local ballPos = ballCFrame.Position

			-- 지정 홀 이탈 판정: 현재 스윙 중 다른 홀 위로 넘어가면 기준 위치로 되돌리고 다음 타를 허용합니다.
			if lastBallCFrame then
				local rayResult = workspace:Raycast(ballPos + Vector3.new(0, 5, 0), Vector3.new(0, -20, 0))
				if rayResult and rayResult.Instance then
					local parent = rayResult.Instance.Parent
					local parentName = parent and parent.Name or ""
					local hitHoleNum = parentName:match("^Hole(%d+)$")
					if hitHoleNum and tonumber(hitHoleNum) ~= currentHole then
						print("[Client][Game] ResetBall reason=otherHole currentHole=" .. tostring(currentHole) .. " hitHole=" .. tostring(hitHoleNum))
						swingBall:Stop()
						swingBall.CFrame = lastBallCFrame
						swingBall:SetPlaybackTime(0)
						canSwing = true
						setPowerBarVisible(true)
						return
					end
				end
			end

			-- 낙하 판정: 프레임마다 볼 필요 없이 스윙 폴링 주기마다 하한선 이탈 여부만 확인합니다.
			if lastBallCFrame and ballPos.Y < -150 then
				print("[Client][Game] ResetBall reason=fall y=" .. tostring(ballPos.Y))
				swingBall:Stop()
				swingBall.CFrame = lastBallCFrame
				swingBall:SetPlaybackTime(0)
				canSwing = true
				setPowerBarVisible(true)
				return
			end

			-- 골인 판정: 일반 홀은 골 파트 중심 기준의 2D 반경과 높이 범위로 확인합니다.
			if currentGoalPart and not goalReportSent then
				local goalRadius = math.min(currentGoalPart.Size.X, currentGoalPart.Size.Z) / 2 * 0.6
				local rel = currentGoalPart.CFrame:PointToObjectSpace(ballPos)
				local dist2D = math.sqrt(rel.X^2 + rel.Z^2)
				local isGoal = dist2D <= goalRadius
					and ballPos.Y < currentGoalPart.Position.Y + 2
					and ballPos.Y > currentGoalPart.Position.Y - 50

				-- 18번 홀은 사각 골 영역 전체를 판정 범위로 사용합니다.
				if currentHole == 18 then
					local halfX = currentGoalPart.Size.X / 2
					local halfZ = currentGoalPart.Size.Z / 2
					isGoal = math.abs(rel.X) <= halfX
						and math.abs(rel.Z) <= halfZ
						and ballPos.Y < currentGoalPart.Position.Y + 10
						and ballPos.Y > currentGoalPart.Position.Y - 50
				end

				-- 골인 처리: 서버에 결과를 보고하고 다음 타 준비가 켜지지 않도록 즉시 종료합니다.
				if isGoal then
					goalReportSent = true
					canSwing = false
					setPowerBarVisible(false)
					print("[Client][Network] Send GoalReached | hole=" .. tostring(currentHole) .. " swings=" .. tostring(localSwingCount))
					GoalReachedEvent:FireServer(ballPos, localSwingCount)
					return
				end
			end

			-- 루프 종료 판정: 공이 잠들면 샷이 끝난 것으로 보고 다음 타 준비 단계로 넘어갑니다.
			local sleepOk, sleeping = pcall(function()
				return swingBall:IsSleeping()
			end)
			if sleepOk and sleeping then
				slept = true
				break
			end

			-- 루프 유지 처리: 아직 골인도 정지도 아니면 짧게 대기한 뒤 다시 판정합니다.
			task.wait(POLL_INTERVAL)
			elapsed = elapsed + POLL_INTERVAL
		end

		-- Early-Out: 폴링 종료 직후 상태가 바뀌었거나 이미 골인이 보고되었으면 다음 타를 열지 않습니다.
		if playerBall ~= swingBall then return end
		if goalReportSent then return end

		if not slept then
			print(string.format(
				"[Client][Game] IsSleeping poll timeout (%.1fs) — proceeding to next stroke",
				TIMEOUT_SECONDS
			))
		end

		local ballOk, ballCFrame = pcall(function()
			return swingBall.BallCFrame
		end)
		if ballOk and ballCFrame then
			lastBallCFrame = ballCFrame
		end

		-- 다음 타 준비: 골인이 아닌 경우에만 스윙 입력과 파워바를 다시 활성화합니다.
		canSwing = true
		print("[Client][Game] NextStrokeReady reason=" .. (slept and "IsSleeping" or "timeout"))
		setPowerBarVisible(true)
	end)
end

swingButton.Activated:Connect(doSwing)

-- ─────────────────────────────────────────
-- 이벤트 수신
-- ─────────────────────────────────────────
GoalAnimEvent.OnClientEvent:Connect(function(goalPart)
	print("[Client][Network] Receive GoalAnim | goal=" .. tostring(goalPart and goalPart.Name))
	isGoalAnim = true
	camera.CameraType = Enum.CameraType.Scriptable
	soundGoal:Play()
	setPowerBarVisible(false)

	local goalBall = playerBall
	task.spawn(function()
		task.wait(1.5)
		playLocalGoalSuction(goalBall, goalPart)
	end)

	local holeFolder   = goalPart.Parent
	local finalCam     = holeFolder:FindFirstChild("FinalCam")
	local finalCamLook = holeFolder:FindFirstChild("FinalCamLook")

	if finalCam and finalCamLook then
		goalCamTargetCFrame = CFrame.new(finalCam.Position, finalCamLook.Position)
	elseif finalCam then
		goalCamTargetCFrame = finalCam.CFrame
	else
		local goalPole = holeFolder:FindFirstChild("GoalPole")
		local goalPos  = goalPart.Position
		if goalPole then
			goalCamTargetCFrame = CFrame.new(goalPole.Position + Vector3.new(15, 20, 25), goalPos)
		else
			goalCamTargetCFrame = CFrame.new(goalPos + Vector3.new(15, 20, 25), goalPos)
		end
	end
end)

GoalResultEvent.OnClientEvent:Connect(function(resultData)
	print("[Client][Network] Receive GoalResult | hole=" .. tostring(resultData.hole) .. " swings=" .. tostring(resultData.swings))
	blockBar = true

	-- 원본 사이즈 최초 1회 캐시
	if not rankOrigSize  then rankOrigSize  = rankWidget.Size  end
	if not expOrigSize   then expOrigSize   = expWidget.Size   end
	if not pointOrigSize then pointOrigSize = pointWidget.Size end

	-- ✅ 텍스트 세팅 수정: "X타 - 용어" 형식으로 출력되게 변경
	-- 예: "3타 - Birdie 🐦", "12타 - Heavy Bogey"
	resultText.Text = string.format("%s ( %d )", resultData.term, resultData.swings)
	timerText.Text  = formatTime(resultData.elapsed)

	-- RANK/EXP/POINT 초기 숨김
	rankWidget.Visible  = false
	expWidget.Visible   = false
	pointWidget.Visible = false

	-- Result 패널 슬라이드 업 (1.25 → 0.95)
	resultGui.Position = UDim2.new(0.5, 0, 1.25, 0)
	resultGui.Visible  = true
	TweenService:Create(resultGui,
		TweenInfo.new(0.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 0.95, 0) }
	):Play()

	-- RANK 팝업 (0.8s 후)
	task.delay(0.8, function()
		local rl = rankWidget:WaitForChild("TextLabel")
		if rl then rl.Text = "" end  -- ScoreboardUpdate 수신 시 갱신됨
		popupWidget(rankWidget, rankOrigSize)
	end)

	-- EXP 팝업 (1.3s 후)
	task.delay(1.3, function()
		local el = expWidget:WaitForChild("TextLabel")
		if el then el.Text = "+" .. tostring(resultData.exp) end
		popupWidget(expWidget, expOrigSize)
	end)

	-- POINT 팝업 (1.8s 후)
	task.delay(1.8, function()
		local pl = pointWidget:WaitForChild("TextLabel")
		if pl then pl.Text = "+" .. tostring(resultData.point) end
		popupWidget(pointWidget, pointOrigSize)
	end)
	
	-- 3.5s 후 Result 슬라이드 다운 → 스코어보드 표시
	task.delay(3.5, function()
		TweenService:Create(resultGui,
			TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
			{ Position = UDim2.new(0.5, 0, 1.25, 0) }
		):Play()
		task.wait(0.6)  -- 트윈 시간(0.5s) + 여유 0.1s
		resultGui.Visible = false
		showScoreboard()
	end)
end)

BallReadyEvent.OnClientEvent:Connect(function(ballName, snapCamera, serverHole, spawnCFrame)
	local spawnPos = spawnCFrame and spawnCFrame.Position
	print(string.format(
		"[Client][Network] Receive BallReady | snapCamera=%s cframePos=(%.3f, %.3f, %.3f)",
		tostring(snapCamera),
		spawnPos and spawnPos.X or 0,
		spawnPos and spawnPos.Y or 0,
		spawnPos and spawnPos.Z or 0
	))
	-- 서버에서 Clone한 SimulationBall이 클라이언트에 복제될 때까지 게임 시작 처리를 지연합니다.
	local ball = workspace:WaitForChild(ballName)

	for _, connection in ipairs(playerBallSignalConnections) do
		connection:Disconnect()
	end
	playerBallSignalConnections = {}
	playerBall          = ball
	currentHole         = serverHole or currentHole or 1
	placeLocalBallAt(playerBall, spawnCFrame, "BallReady")
	lastBallCFrame      = spawnCFrame
	local holeFolder    = workspace:WaitForChild("Holes"):WaitForChild("Hole" .. tostring(currentHole))
	currentGoalPart     = holeFolder:WaitForChild("Goal")
	localSwingCount     = 0
	goalReportSent      = false

	table.insert(playerBallSignalConnections, playerBall.Played:Connect(function()
		print("[Client][SimulationBall] Played")
	end))

	table.insert(playerBallSignalConnections, playerBall.Bounded:Connect(function(otherInstance, bounce)
		local otherName = otherInstance and otherInstance.Name or "nil"
		local parentName = (otherInstance and otherInstance.Parent) and otherInstance.Parent.Name or "nil"
		local hitPos = bounce and bounce.BouncedPosition
		local normal = bounce and bounce.ImpactNormal
		print(string.format(
			"[Client][SimulationBall] Bounded other=%s parent=%s pos=(%.3f, %.3f, %.3f) normal=(%.3f, %.3f, %.3f) bounced=%s sliding=%s",
			tostring(otherName),
			tostring(parentName),
			hitPos and hitPos.X or 0, hitPos and hitPos.Y or 0, hitPos and hitPos.Z or 0,
			normal and normal.X or 0, normal and normal.Y or 0, normal and normal.Z or 0,
			tostring(bounce and bounce.IsBouncedHit),
			tostring(bounce and bounce.IsSlidingHit)
		))
	end))

	table.insert(playerBallSignalConnections, playerBall.Stopped:Connect(function()
		print("[Client][SimulationBall] Stopped")
	end))

	table.insert(playerBallSignalConnections, playerBall.Paused:Connect(function()
		print("[Client][SimulationBall] Paused")
	end))

	canSwing            = true   -- ✅ 공 확인 후 세팅 (순서는 그대로)
	print(string.format(
		"[Client][Game] NextStrokeReady reason=BallReady snapCamera=%s cframePos=(%.3f, %.3f, %.3f)",
		tostring(snapCamera),
		spawnPos and spawnPos.X or 0,
		spawnPos and spawnPos.Y or 0,
		spawnPos and spawnPos.Z or 0
	))
	isGoalAnim          = false
	goalCamTargetCFrame = nil

	if blockBar then
		pendingBarShow = true
	else
		bar.Visible = true
		setPowerBarVisible(true)
	end

	if snapCamera then
		if spawnCFrame then
			cameraTarget.Position = spawnCFrame.Position
		else
			playerBall = nil
			canSwing = false
			return
		end
	end

	camera.CameraType            = Enum.CameraType.Custom
	camera.CameraSubject         = cameraTarget
	player.CameraMinZoomDistance = 1250
	player.CameraMaxZoomDistance = 5000
end)

ClearEvent.OnClientEvent:Connect(function(holeNumber)
	print("[Client][Network] Receive ClearEvent | hole=" .. tostring(holeNumber))
	canSwing     = false
	playerBall   = nil
	currentHole = nil
	currentGoalPart = nil
	lastBallCFrame = nil
	goalReportSent = false
	destroyDirectionIndicator()
	for _, connection in ipairs(playerBallSignalConnections) do
		connection:Disconnect()
	end
	playerBallSignalConnections = {}
end)

WallHitEvent.OnClientEvent:Connect(function()
	print("[Client][Network] Receive WallHitEvent")
	soundWall:Play()
end)

SlotAssignEvent.OnClientEvent:Connect(function(slotData, mySlotNum)
	print("[Client][Network] Receive SlotAssign | mySlot=" .. tostring(mySlotNum))
	-- Slot data is currently used by the server-side scoreboard order.
	-- Keep this listener so future UI can react to slot assignment without changing networking.
end)

ScoreboardUpdateEvent.OnClientEvent:Connect(function(data)
	print("[Client][Network] Receive ScoreboardUpdate")
	lastScoreboardData = data

	-- RANK 위젯이 이미 보이고 있으면 즉시 순위 업데이트
	if rankWidget.Visible then
		local sorted = {}
		for _, pData in pairs(data) do
			table.insert(sorted, pData)
		end
		table.sort(sorted, function(a, b) return a.total < b.total end)
		for rank, pData in ipairs(sorted) do
			if pData.userId == player.UserId then
				local rl = rankWidget:WaitForChild("TextLabel")
				if rl then rl.Text = "#" .. rank end
				break
			end
		end
	end
end)

-- ─────────────────────────────────────────
-- GoalPole 업데이트
-- ─────────────────────────────────────────
local polesData = {}
local function updateGoldPoles(ballPos)
	local holesFolder = workspace:FindFirstChild("Holes")
	if not holesFolder then return end

	for _, holeFolder in ipairs(holesFolder:GetChildren()) do
		local pole = holeFolder:FindFirstChild("GoalPole")
		if pole and pole:IsA("BasePart") then
			if not polesData[pole] then
				polesData[pole] = { originCF = pole.CFrame, isUp = false, tween = nil }
			end
			local pData = polesData[pole]
			local goal  = holeFolder:FindFirstChild("Goal")
			local dist  = (ballPos and goal) and (ballPos - goal.Position).Magnitude or math.huge

			if dist <= 1000 then
				if not pData.isUp then
					pData.isUp = true
					if pData.tween then pData.tween:Cancel() end
					pData.tween = TweenService:Create(pole,
						TweenInfo.new(1.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
						{ CFrame = pData.originCF * CFrame.new(0, 500, 0) }
					)
					pData.tween:Play()
				end
			else
				if pData.isUp then
					pData.isUp = false
					if pData.tween then pData.tween:Cancel() end
					pData.tween = TweenService:Create(pole,
						TweenInfo.new(1.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
						{ CFrame = pData.originCF }
					)
					pData.tween:Play()
				end
			end
		end
	end
end

-- ─────────────────────────────────────────
-- RenderStepped
-- ─────────────────────────────────────────
local activeDirectionIndicator = nil -- 지시기 캐시용 변수
local directionRelativeCFrame = nil  -- 상대 위치/회전 캐시
local setDirectionIndicatorVisible = nil

local function initDirectionIndicator()
	if activeDirectionIndicator then
		local ok, parent = pcall(function()
			return activeDirectionIndicator.Parent
		end)
		if ok and parent then
			return activeDirectionIndicator
		end
	end

	activeDirectionIndicator = workspace:FindFirstChild("Direction")
	if not activeDirectionIndicator then
		print("[Client][Direction] Warning: workspace.Direction not found")
		return nil
	end

	local setupOk = pcall(function()
		if activeDirectionIndicator:IsA("BasePart") then
			activeDirectionIndicator.Anchored = true
			activeDirectionIndicator.CanCollide = false
			activeDirectionIndicator.CanQuery = false
		end
	end)
	if not setupOk then
		activeDirectionIndicator = nil
		directionRelativeCFrame = nil
		return nil
	end
	setDirectionIndicatorVisible(false)

	local refBallPos = Vector3.new(5330.0, 425.697052, 1960.0)
	local refDirPos = Vector3.new(5621.75293, 377.949835, 1964.27478)
	local originalRot = activeDirectionIndicator:GetPivot().Rotation
	local refDirCFrame = CFrame.new(refDirPos) * originalRot
	directionRelativeCFrame = CFrame.new(refBallPos):Inverse() * refDirCFrame

	return activeDirectionIndicator
end

setDirectionIndicatorVisible = function(isVisible)
	if not activeDirectionIndicator then return end

	local transparency = isVisible and 0 or 1
	if activeDirectionIndicator:IsA("BasePart") then
		activeDirectionIndicator.Transparency = transparency
	else
		for _, desc in ipairs(activeDirectionIndicator:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.Transparency = transparency
			end
		end
	end
end

destroyDirectionIndicator = function()
	if activeDirectionIndicator then
		setDirectionIndicatorVisible(false)
		activeDirectionIndicator = nil
	end
	directionRelativeCFrame = nil
end

RunService.RenderStepped:Connect(function(dt)
	local ballPos = nil
	local ballCFrame = nil
	if playerBall then
		local ballOk, cf = pcall(function()
			return playerBall.BallCFrame
		end)
		if ballOk and cf then
			ballCFrame = cf
			ballPos = cf.Position
		else
			playerBall = nil
			canSwing = false
		end
	end

	local look = camera.CFrame.LookVector
	local lookFlat = Vector3.new(look.X, 0, look.Z)
	if lookFlat.Magnitude >= 0.001 then
		aimDir = lookFlat.Unit
	end

	if isGoalAnim and goalCamTargetCFrame then
		camera.CFrame = camera.CFrame:Lerp(goalCamTargetCFrame, math.clamp(dt * 3, 0, 1))
	elseif ballPos then
		cameraTarget.Position = cameraTarget.Position:Lerp(ballPos, math.clamp(dt * 15, 0, 1))
	end

	updateGoldPoles(ballPos)

	-- 방향 인디케이터는 조준 방향과 파워 변화에 즉시 반응해야 하므로 프레임 갱신으로 유지합니다.
	if canSwing and ballPos then
		initDirectionIndicator()

		if activeDirectionIndicator and directionRelativeCFrame then
			setDirectionIndicatorVisible(true)
			local angle = math.atan2(-aimDir.Z, aimDir.X)
			local rotationCFrame = CFrame.Angles(0, angle, 0)
			local targetCFrame = CFrame.new(ballPos) * rotationCFrame * directionRelativeCFrame
			local pivotOk = pcall(function()
				activeDirectionIndicator:PivotTo(targetCFrame)
			end)
			if not pivotOk then
				activeDirectionIndicator = nil
				directionRelativeCFrame = nil
				return
			end

			local powerRatio = math.clamp(currentPower / 100, 0, 1)
			local r = 254 + (254 - 254) * powerRatio
			local g = 223 + (0 - 223) * powerRatio
			local b = 0 + (0 - 0) * powerRatio
			local currentColor = Color3.fromRGB(math.round(r), math.round(g), math.round(b))
			
			local colorOk = pcall(function()
				if activeDirectionIndicator:IsA("BasePart") then
					activeDirectionIndicator.Color = currentColor
				else
					for _, desc in ipairs(activeDirectionIndicator:GetDescendants()) do
						if desc:IsA("BasePart") then
							desc.Color = currentColor
						end
					end
				end
			end)
			if not colorOk then
				activeDirectionIndicator = nil
				directionRelativeCFrame = nil
				return
			end
		end
	elseif activeDirectionIndicator then
		setDirectionIndicatorVisible(false)
	end
end)