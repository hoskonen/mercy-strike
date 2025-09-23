-- Scripts/MercyStrike/MS_Main.lua
-- Mercy Strike core logic (heartbeat-first)

MercyStrike = MercyStrike or { version = "0.1.0" }
local MS = MercyStrike

MS.config = {
    pollCombatMs = 500,
    pollIdleMs   = 2000,
    verbose      = true,
}

local function log(s) if MS.config.verbose then System.LogAlways("[MS] " .. tostring(s)) end end

-- Load the shared poller (reschedules itself, kills by id)
Script.ReloadScript("Scripts/MercyStrike/MS_Poller.lua")

-- === Helpers ===
local function GetPlayer()
    return System.GetEntityByName("Henry") or System.GetEntityByName("dude")
end

local function IsInCombat()
    local p = GetPlayer(); local soul = p and p.soul
    if soul and type(soul.IsInCombatDanger) == "function" then
        local ok, v = pcall(soul.IsInCombatDanger, soul)
        return ok and (v == true or v == 1) or false
    end
    return false
end

-- === Tick body ===
local function Tick()
    local combat = IsInCombat()
    log("tick (combat=" .. tostring(combat) .. ")")
    -- TODO: add scan + unconscious buff logic here
end

-- === API ===
function MS.Start()
    local ms = IsInCombat() and (MS.config.pollCombatMs or 500) or (MS.config.pollIdleMs or 2000)
    MS_Poller.Start(ms, function()
        Tick()
        -- Optional: re-evaluate cadence on every tick
        local desired = IsInCombat() and (MS.config.pollCombatMs or 500) or (MS.config.pollIdleMs or 2000)
        if desired ~= ms then
            ms = desired
            MS_Poller.Start(ms, Tick, false) -- re-register with new cadence
        end
    end, true)
end

function MS.Stop()
    MS_Poller.Stop()
end

function MS.Bootstrap()
    if MS._booted then return end
    MS._booted = true
    log("boot ok v" .. tostring(MS.version))
    MS.Start()
end

function MS:OnGameplayStarted()
    log("OnGameplayStarted → (re)start poller")
    MS.Start()
end
