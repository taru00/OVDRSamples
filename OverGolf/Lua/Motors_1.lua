-- MotorRotation.lua
-- Place in: StarterPlayerScripts 또는 StarterCharacterScripts

local RunService = game:GetService("RunService")
local workspace  = game:GetService("Workspace")

-- Motors 폴더 대기 및 가져오기
local motorsFolder = workspace:WaitForChild("Motors")

-- ⚙️ 설정 (수정 가능한 변수)
-- 초당 회전할 각도 (현재 1초에 90도 회전)
local ROTATION_SPEED = 30

RunService.RenderStepped:Connect(function(deltaTime)
    -- deltaTime을 곱해주어 컴퓨터 성능(프레임)에 상관없이 일정한 속도로 회전하게 만듭니다.
    local rotationAngle = math.rad(ROTATION_SPEED * deltaTime)
    
    -- Y축(위아래 축)을 기준으로 회전하는 CFrame 생성
    -- X나 Z축으로 회전하고 싶다면 CFrame.Angles(rotationAngle, 0, 0) 등으로 변경하세요.
    local rotationCFrame = CFrame.Angles(0, rotationAngle, 0)

    -- Motors 폴더 안의 모든 객체를 순회하며 회전시킵니다.
    for _, motor in ipairs(motorsFolder:GetChildren()) do
        if motor:IsA("BasePart") then
        	if motor.Name == "Part" then
        		rotationCFrame = CFrame.Angles(0, 0, rotationAngle)
        	else
        		rotationCFrame = CFrame.Angles(0, rotationAngle, 0)
        	end
            -- 일반 Part, MeshPart 등일 경우
            motor.CFrame = motor.CFrame * rotationCFrame
            
        elseif motor:IsA("Model") then
            -- Model일 경우 (내부 파트들이 함께 회전함)
            motor:PivotTo(motor:GetPivot() * rotationCFrame)
        end
    end
end)