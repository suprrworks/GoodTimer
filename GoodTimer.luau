--!strict

--[[
	GoodTimer
	Lightweight countdown timer module for Roblox.

	Copyright (c) 2026 suprrworks_

	Licensed under the MIT License.
	See the LICENSE file in the repository for details.

	API
		Timer.new(duration, autoStart?)
		:Start() :Stop() :Pause() :Resume() :Reset(duration?) :Destroy()
		:SetTime(t) :AddTime(t) :RemoveTime(t) :SetSpeed(s)
		:GetTime() :GetDuration() :GetElapsedTime() :GetProgress() :GetSpeed() :GetState()
		:IsRunning() :IsPaused()

	Signals
		Started()                    fired when the timer starts running
		PausedSignal()               fired when a running timer is paused
		Resumed()                    fired when a paused timer resumes
		Stopped()                    fired when a running/paused timer is stopped or reset
		Completed()                  fired once when the time reaches 0
		Tick(wholeSeconds)          fired every frame in which time actually passed
		TimeChanged(wholeSeconds)    fired with a whole number (math.ceil) whenever the
		                             displayed second changes, from ticking or manual changes

	States: "Idle" -> "Running" <-> "Paused", "Running" -> "Completed"
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Modules.Signal)

type Signal = typeof(Signal.new())

export type State = "Idle" | "Running" | "Paused" | "Completed"

local Timer = {}
Timer.__index = Timer

type Fields = {
	Started: Signal,
	PausedSignal: Signal,
	Resumed: Signal,
	Stopped: Signal,
	Completed: Signal,
	Tick: Signal,
	TimeChanged: Signal,

	_duration: number,
	_timeLeft: number,
	_elapsed: number,
	_speed: number,
	_state: State,
	_lastWhole: number,
	_runId: number,
	_connection: RBXScriptConnection?,
	_destroyed: boolean,
}

export type Timer = typeof(setmetatable({} :: Fields, Timer))

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Returns the value if it is a finite number, otherwise warns and returns nil.
local function readNumber(value: any, label: string): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		warn(string.format("Timer.%s: expected a finite number, got %s", label, tostring(value)))
		return nil
	end
	return value
end

--------------------------------------------------------------------------------
-- Internals
--------------------------------------------------------------------------------

-- Every state change goes through here. Bumping _runId lets an in-flight _step
-- notice that a signal callback changed the timer underneath it and bail out.
-- The Heartbeat connection only exists while Running, so there is never more
-- than one and nothing runs while paused/idle.
function Timer._transition(self: Timer, state: State)
	self._state = state
	self._runId += 1

	if state == "Running" then
		if not self._connection then
			self._connection = RunService.Heartbeat:Connect(function(deltaTime: number)
				self:_step(deltaTime)
			end)
		end
	else
		local connection = self._connection
		if connection then
			self._connection = nil
			connection:Disconnect()
		end
	end
end

-- Fires TimeChanged only if the displayed whole second actually changed.
function Timer._syncWhole(self: Timer)
	local whole = math.ceil(self._timeLeft)
	if whole ~= self._lastWhole then
		self._lastWhole = whole
		self.TimeChanged:Fire(whole)
	end
end

function Timer._step(self: Timer, deltaTime: number)
	if self._state ~= "Running" then
		return
	end

	local runId = self._runId

	if self._timeLeft > 0 then
		-- Never consume more than what is left, so TimeLeft hits exactly 0
		-- and Elapsed never overshoots.
		local consumed = math.min(deltaTime * self._speed, self._timeLeft)
		if consumed <= 0 then
			return -- speed is 0: no time passed, nothing to report
		end

		self._timeLeft -= consumed
		self._elapsed += consumed

		self.Tick:Fire(math.ceil(self._timeLeft))
		if self._runId ~= runId then
			return -- a Tick callback stopped/paused/reset/destroyed us
		end

		self:_syncWhole()
		if self._runId ~= runId then
			return
		end
	end

	-- Re-read TimeLeft: callbacks may have added or removed time.
	if self._timeLeft <= 0 then
		self:_transition("Completed")
		self.Completed:Fire()
	end
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function Timer.new(duration: number, autoStart: boolean?): Timer
	local safeDuration = math.max(0, readNumber(duration, "new") or 0)

	local self = setmetatable({
		Started = Signal.new(),
		PausedSignal = Signal.new(),
		Resumed = Signal.new(),
		Stopped = Signal.new(),
		Completed = Signal.new(),
		Tick = Signal.new(),
		TimeChanged = Signal.new(),

		_duration = safeDuration,
		_timeLeft = safeDuration,
		_elapsed = 0,
		_speed = 1,
		_state = "Idle" :: State,
		_lastWhole = math.ceil(safeDuration),
		_runId = 0,
		_connection = nil,
		_destroyed = false,
	} :: Fields, Timer)

	if autoStart then
		self:Start()
	end

	return self
end

--------------------------------------------------------------------------------
-- Control
--------------------------------------------------------------------------------

-- Starts (or continues after Stop) the countdown.
-- A completed timer is restarted from its duration.
function Timer.Start(self: Timer)
	if self._destroyed then
		return
	end

	local state = self._state
	if state == "Running" or state == "Paused" then
		return
	end

	if self._timeLeft <= 0 then
		self._timeLeft = self._duration
		self._elapsed = 0
		self:_syncWhole()

		-- A TimeChanged callback may have started, destroyed or otherwise changed us.
		if self._destroyed or self._state ~= state then
			return
		end
	end

	self:_transition("Running")
	self.Started:Fire()
end

function Timer.Stop(self: Timer)
	if self._destroyed then
		return
	end

	local state = self._state
	if state ~= "Running" and state ~= "Paused" then
		return
	end

	self:_transition("Idle")
	self.Stopped:Fire()
end

function Timer.Pause(self: Timer)
	if self._destroyed or self._state ~= "Running" then
		return
	end

	self:_transition("Paused")
	self.PausedSignal:Fire()
end

function Timer.Resume(self: Timer)
	if self._destroyed or self._state ~= "Paused" then
		return
	end

	self:_transition("Running")
	self.Resumed:Fire()
end

-- Stops the timer and restores the time. Optionally changes the duration.
function Timer.Reset(self: Timer, duration: number?)
	if self._destroyed then
		return
	end

	if duration ~= nil then
		local safeDuration = readNumber(duration, "Reset")
		if safeDuration then
			self._duration = math.max(0, safeDuration)
		end
	end

	local wasActive = self._state == "Running" or self._state == "Paused"

	self._timeLeft = self._duration
	self._elapsed = 0
	self:_transition("Idle")

	if wasActive then
		self.Stopped:Fire()
	end

	if not self._destroyed then
		self:_syncWhole()
	end
end

-- Stops the timer and releases every signal connection. Safe to call repeatedly,
-- including from inside a signal callback. Does not fire Stopped.
function Timer.Destroy(self: Timer)
	if self._destroyed then
		return
	end

	self._destroyed = true
	self:_transition("Idle")

	self.Started:Destroy()
	self.PausedSignal:Destroy()
	self.Resumed:Destroy()
	self.Stopped:Destroy()
	self.Completed:Destroy()
	self.Tick:Destroy()
	self.TimeChanged:Destroy()
end

--------------------------------------------------------------------------------
-- Time manipulation
--------------------------------------------------------------------------------

-- Sets the remaining time (clamped to >= 0). Setting 0 on a running timer
-- completes it on the next frame.
function Timer.SetTime(self: Timer, time: number)
	if self._destroyed then
		return
	end

	local safeTime = readNumber(time, "SetTime")
	if not safeTime then
		return
	end

	self._timeLeft = math.max(0, safeTime)
	self:_syncWhole()
end

function Timer.AddTime(self: Timer, amount: number)
	local safeAmount = readNumber(amount, "AddTime")
	if safeAmount then
		self:SetTime(self._timeLeft + safeAmount)
	end
end

function Timer.RemoveTime(self: Timer, amount: number)
	local safeAmount = readNumber(amount, "RemoveTime")
	if safeAmount then
		self:SetTime(self._timeLeft - safeAmount)
	end
end

-- 1 = normal, 2 = twice as fast, 0 = frozen. Negative values are clamped to 0.
function Timer.SetSpeed(self: Timer, speed: number)
	if self._destroyed then
		return
	end

	local safeSpeed = readNumber(speed, "SetSpeed")
	if safeSpeed then
		self._speed = math.max(0, safeSpeed)
	end
end

--------------------------------------------------------------------------------
-- Getters
--------------------------------------------------------------------------------

-- Remaining time as a whole number (10, 9, 8 ... 0).
function Timer.GetTime(self: Timer): number
	return math.ceil(self._timeLeft)
end

function Timer.GetDuration(self: Timer): number
	return self._duration
end

function Timer.GetElapsedTime(self: Timer): number
	return math.floor(self._elapsed)
end

-- 0 at the start, 1 when finished. Always within [0, 1].
function Timer.GetProgress(self: Timer): number
	if self._duration <= 0 then
		return 1
	end

	return math.clamp(1 - self._timeLeft / self._duration, 0, 1)
end

function Timer.GetSpeed(self: Timer): number
	return self._speed
end

function Timer.GetState(self: Timer): State
	return self._state
end

function Timer.IsRunning(self: Timer): boolean
	return self._state == "Running"
end

function Timer.IsPaused(self: Timer): boolean
	return self._state == "Paused"
end

return Timer
