-- GolfConfig.lua
-- Dependencies: none
-- Shared golf game constants used by both server and client.

local GolfConfig = {}

GolfConfig.MAX_SLOTS = 6
GolfConfig.MAX_HOLE = 18
GolfConfig.SUCTION_Y_THRESHOLD = 30
GolfConfig.SWING_POWER_MULTIPLIER = 100
GolfConfig.SIMULATION_STEPS = 300
GolfConfig.SIMULATION_DELTA_TIME = 1 / 30
GolfConfig.BALL_READY_DELAY = 0.2
GolfConfig.PHYSICAL_BALL_UNANCHOR_DELAY = 0.15
GolfConfig.NEXT_HOLE_DELAY = 3
GolfConfig.FINAL_HOLE_DELAY = 7

GolfConfig.HOLE_PAR = {3, 4, 3, 4, 5, 3, 4, 3, 5, 4, 3, 4, 5, 3, 4, 3, 4, 5}

GolfConfig.EVENT_NAMES = {
	SwingEvent = "SwingEvent",
	BallReady = "BallReady",
	ClearEvent = "ClearEvent",
	GoalAnim = "GoalAnim",
	TrackBallEvent = "TrackBallEvent",
	WallHitEvent = "WallHitEvent",
	SlotAssign = "SlotAssign",
	GoalResult = "GoalResult",
	ScoreboardUpdate = "ScoreboardUpdate",
	StartGame = "StartGame",
}

return GolfConfig