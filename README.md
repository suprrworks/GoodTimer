# GoodTimer-RBLX-
A simple and reusable countdown timer module for Roblox.

# RobloxTimer

A lightweight countdown timer module for Roblox, written in Luau.

## Features
- Start, stop, pause and resume
- Adjustable countdown speed
- Add or remove time
- Progress tracking
- Signals for timer events
- Automatic cleanup

## Installation

Place `Timer.luau` inside your Roblox game's ModuleScript location and make sure the required Signal module is available at:

`ReplicatedStorage.Shared.Modules.Signal`

## Example

```lua
local Timer = require(path.To.Timer)

local countdown = Timer.new(60, true)

countdown.TimeChanged:Connect(function(seconds)
    print("Time left:", seconds)
end)

countdown.Completed:Connect(function()
    print("Timer finished!")
end)
```
