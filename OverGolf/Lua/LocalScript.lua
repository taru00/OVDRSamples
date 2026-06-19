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

local function printClientNetwork(direction, eventName, detail)
	local detailText = detail and (" | " .. detail) or ""
	print("[Client][Network] " .. direction .. " " .. eventName .. detailText)
end

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
	printClientNetwork("Send", "StartGame")
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
		swingBall.Paused:Wait()
		if playerBall ~= swingBall then return end
		canSwing = true
		print("[Client][Game] NextStrokeReady reason=localPaused")
		setPowerBarVisible(true)
	end)
end

swingButton.Activated:Connect(doSwing)

-- ─────────────────────────────────────────
-- 이벤트 수신
-- ─────────────────────────────────────────
GoalAnimEvent.OnClientEvent:Connect(function(goalPart)
	printClientNetwork("Receive", "GoalAnim", "goal=" .. tostring(goalPart and goalPart.Name))
	isGoalAnim = true
	camera.CameraType = Enum.CameraType.Scriptable
	soundGoal:Play()
	setPowerBarVisible(false)

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
	printClientNetwork("Receive", "GoalResult", "hole=" .. tostring(resultData.hole) .. " swings=" .. tostring(resultData.swings))
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

BallReadyEvent.OnClientEvent:Connect(function(ballName, snapCamera)
	printClientNetwork("Receive", "BallReady", "snapCamera=" .. tostring(snapCamera))
	-- 서버에서 Clone한 SimulationBall이 클라이언트에 복제될 때까지 게임 시작 처리를 지연합니다.
	local ball = workspace:WaitForChild(ballName)

	for _, connection in ipairs(playerBallSignalConnections) do
		connection:Disconnect()
	end
	playerBallSignalConnections = {}
	playerBall          = ball

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
	print("[Client][Game] NextStrokeReady reason=BallReady snapCamera=" .. tostring(snapCamera))
	isGoalAnim          = false
	goalCamTargetCFrame = nil

	if blockBar then
		pendingBarShow = true
	else
		bar.Visible = true
		setPowerBarVisible(true)
	end

	if snapCamera then
		local ballOk, ballCFrame = pcall(function()
			return playerBall.BallCFrame
		end)
		if ballOk and ballCFrame then
			cameraTarget.Position = ballCFrame.Position
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
	printClientNetwork("Receive", "ClearEvent", "hole=" .. tostring(holeNumber))
	canSwing     = false
	playerBall   = nil
	destroyDirectionIndicator()
	for _, connection in ipairs(playerBallSignalConnections) do
		connection:Disconnect()
	end
	playerBallSignalConnections = {}
end)

WallHitEvent.OnClientEvent:Connect(function()
	printClientNetwork("Receive", "WallHitEvent")
	soundWall:Play()
end)

SlotAssignEvent.OnClientEvent:Connect(function(slotData, mySlotNum)
	printClientNetwork("Receive", "SlotAssign", "mySlot=" .. tostring(mySlotNum))
	-- Slot data is currently used by the server-side scoreboard order.
	-- Keep this listener so future UI can react to slot assignment without changing networking.
end)

ScoreboardUpdateEvent.OnClientEvent:Connect(function(data)
	printClientNetwork("Receive", "ScoreboardUpdate")
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
	local pivotOk, pivot = pcall(function()
		return activeDirectionIndicator:GetPivot()
	end)
	if not pivotOk or not pivot then
		activeDirectionIndicator = nil
		directionRelativeCFrame = nil
		return nil
	end
	local originalRot = pivot.Rotation
	local refDirCFrame = CFrame.new(refDirPos) * originalRot
	directionRelativeCFrame = CFrame.new(refBallPos):Inverse() * refDirCFrame

	return activeDirectionIndicator
end

setDirectionIndicatorVisible = function(isVisible)
	if not activeDirectionIndicator then return end

	local transparency = isVisible and 0 or 1
	local ok = pcall(function()
		if activeDirectionIndicator:IsA("BasePart") then
			activeDirectionIndicator.Transparency = transparency
		else
			for _, desc in ipairs(activeDirectionIndicator:GetDescendants()) do
				if desc:IsA("BasePart") then
					desc.Transparency = transparency
				end
			end
		end
	end)
	if not ok then
		activeDirectionIndicator = nil
		directionRelativeCFrame = nil
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
	if playerBall then
		local ballOk, ballCFrame = pcall(function()
			return playerBall.BallCFrame
		end)
		if ballOk and ballCFrame then
			ballPos = ballCFrame.Position
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

	-- [기존 카메라 추적 로직]
	if isGoalAnim and goalCamTargetCFrame then
		camera.CFrame = camera.CFrame:Lerp(goalCamTargetCFrame, math.clamp(dt * 3, 0, 1))
	elseif ballPos then
		cameraTarget.Position = cameraTarget.Position:Lerp(ballPos, math.clamp(dt * 15, 0, 1))
	end

	updateGoldPoles(ballPos)

	-- [새로 추가된 방향 지시기(Direction) 궤도 회전 로직]
	if canSwing and ballPos then
		initDirectionIndicator()

		-- 2. 회전 및 위치 실시간 업데이트 (Pivot 중심 회전)
		if activeDirectionIndicator and directionRelativeCFrame then
			setDirectionIndicatorVisible(true)
			-- 제시해주신 오프셋 위치가 대략 +X축(5621 > 5330)이므로, 카메라 방향을 X축 기준 각도로 변환합니다.
			local angle = math.atan2(-aimDir.Z, aimDir.X)
			
			-- 로블록스는 상하 축이 'Y축'이므로 좌우 조준을 하려면 Y축 회전이 필요합니다.
			local rotationCFrame = CFrame.Angles(0, angle, 0)
			
			-- (만약 파트 자체의 로컬축이 뒤틀려 있어 정말 수직축 기준의 Roll 형태인 Z축 회전이 필요하다면 위 코드를 지우고 아래를 켜세요)
			-- local rotationCFrame = CFrame.Angles(0, 0, angle)

			-- 새로운 위치/회전 = 현재 공 위치 * 회전 * 초기 상대 오프셋
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

			-- 1. 시작 RGB: (254, 223, 0)
			-- 2. 끝 RGB:   (254, 0, 0)
			-- 비율(powerRatio)에 따라 각 R, G, B 값을 직접 계산 (수동 Lerp)
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