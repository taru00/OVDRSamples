-- GolfScoring.lua
-- Dependencies:
--   - GolfConfig
-- Converts stroke counts into golf result text and rewards.

local GolfConfig = require(script.Parent:WaitForChild("GolfConfig"))

local GolfScoring = {}

function GolfScoring.GetScoreInfo(swings: number, hole: number): (string, number, number)
	local par = GolfConfig.HOLE_PAR[hole] or 3
	local diff = swings - par
	local term: string
	local exp: number
	local point: number

	if swings >= 10 then
		term, exp, point = "Heavy Bogey", 2, 1
	elseif swings == 1 then
		term, exp, point = "Hole in One", 150, 15
	elseif diff <= -3 then
		term, exp, point = "Albatross", 100, 10
	elseif diff == -2 then
		term, exp, point = "Eagle", 70, 7
	elseif diff == -1 then
		term, exp, point = "Birdie", 45, 5
	elseif diff == 0 then
		term, exp, point = "Par", 25, 3
	elseif diff == 1 then
		term, exp, point = "Bogey", 15, 2
	elseif diff == 2 then
		term, exp, point = "Double Bogey", 10, 1
	elseif diff == 3 then
		term, exp, point = "Triple Bogey", 5, 1
	elseif diff == 4 then
		term, exp, point = "Quadruple Bogey", 5, 1
	else
		term, exp, point = "+" .. diff .. " Over", 5, 1
	end

	return term, exp, point
end

return GolfScoring