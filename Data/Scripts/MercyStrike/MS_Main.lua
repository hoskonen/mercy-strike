-- Scripts/MercyStrike/MS_Main.lua  (Lua 5.1)
-- World detector (3.5s) + combat KO poller (500ms)

MercyStrike = MercyStrike or { version = "0.2.1" }
local MS = MercyStrike

-- Load modules
Script.ReloadScript("Scripts/MercyStrike/MS_Config.lua")
Script.ReloadScript("Scripts/MercyStrike/MS_Log.lua")
Script.ReloadScript("Scripts/MercyStrike/MS_Util.lua")
Script.ReloadScript("Scripts/MercyStrike/MS_Unconscious.lua")
Script.ReloadScript("Scripts/MercyStrike/MS_Poller.lua")

-- ------------------------
-- State
-- ------------------------
local combatActive = false
local rescanUntil = {} -- ent.id -> time (sec) before reconsidering
local function nowSec() return math.floor((os.clock() or 0) + 0.5) end

local function cooldownActive(e, tnow)
    if not (e and e.id) then return false end
    local untilT = rescanUntil[e.id]
    return untilT and tnow < untilT
end
local function armCooldown(e, tnow)
    if not (e and e.id) then return end
    local cd = tonumber(MS.config.rescanCooldownS) or 3.0
    rescanUntil[e.id] = tnow + cd
end

local _onceErr = {} -- step -> true (log each failure only once)

local function onceErr(step, msg)
    if not _onceErr[step] then
        _onceErr[step] = true
        MS.LogCore("ERR: step=" .. tostring(step) .. " " .. tostring(msg or ""))
    end
end

local function CombatTick()
    -- fence: IsInCombat
    local okIC, inCombat = pcall(MS.IsInCombat)
    if not okIC then
        onceErr("IsInCombat", "pcall failed"); return
    end
    if not inCombat then
        StopCombatPoller(); return
    end

    -- config
    local cfg = MS.config or {}
    local radius = cfg.scanRadiusM or 10.0
    local maxList = cfg.maxList or 48
    local maxN = tonumber(cfg.maxPerTick) or 8
    local tnow = nowSec()

    -- scan (souls only)
    local listOk, list = pcall(MS.ScanSoulsInSphere, radius, maxList)
    if not listOk then
        onceErr("ScanSoulsInSphere", list); return
    end
    if type(list) ~= "table" or #list == 0 then return end

    local seen = 0
    for i = 1, #list do
        if seen >= maxN then break end

        local rec = list[i]; local e = rec and rec.e
        if e then
            local name = (MS.PrettyName and MS.PrettyName(e)) or "<entity>"

            -- animal gate
            local animal = false
            if not cfg.includeAnimals then
                local aOk, aVal = pcall(MS.IsAnimalByName, e)
                if not aOk then
                    onceErr("IsAnimalByName", "name=" .. name)
                    animal = true
                else
                    animal = not not aVal
                end
            end

            if not animal then
                -- hostile gate
                local hostile = true
                if cfg.onlyHostile then
                    local hOk, hVal = pcall(MS.IsHostileToPlayer, e)
                    if not hOk then
                        onceErr("IsHostileToPlayer", "name=" .. name)
                        hostile = false
                    else
                        hostile = not not hVal
                    end
                end

                if hostile then
                    -- per-entity rescan cooldown
                    if not cooldownActive(e, tnow) then
                        armCooldown(e, tnow)
                        seen = seen + 1

                        -- HP
                        local hpOk, hp = pcall(MS.GetNormalizedHp, e)
                        if not hpOk then
                            onceErr("GetNormalizedHp", "name=" .. name)
                        else
                            if MS.LogProbe and cfg.logging and cfg.logging.probe then
                                MS.LogProbe(string.format("name=%s hp=%.3f", name, hp or -1))
                            end

                            if (hp or 1) <= (cfg.hpThreshold or 0.12) then
                                -- chance + apply
                                if math.random() < (cfg.applyChance or 0.20) then
                                    local applied = false
                                    if MS_Unconscious and MS_Unconscious.Apply then
                                        local okApply, res = pcall(MS_Unconscious.Apply, e,
                                            cfg.buffId or "unconscious_permanent")
                                        applied = okApply and res
                                        if not okApply then onceErr("Unconscious.Apply", "name=" .. name) end
                                    end
                                    if applied then
                                        MS.LogApply("KO applied '" .. tostring(cfg.buffId or "unconscious_permanent") ..
                                            "' name=" .. name ..
                                            " hp=" .. string.format("%.2f", hp or -1))
                                    elseif cfg.logging and cfg.logging.probe then
                                        MS.LogSkip("apply fail name=" .. name)
                                    end
                                elseif cfg.logging and cfg.logging.probe then
                                    MS.LogSkip("roll failed name=" .. name)
                                end
                            end
                        end
                    end -- cooldown
                elseif cfg.logging and cfg.logging.probe then
                    MS.LogSkip("skip notHostile name=" .. name)
                end
            elseif cfg.logging and cfg.logging.probe then
                MS.LogSkip("skip animal name=" .. name)
            end
        end
    end
end

local function StartCombatPoller()
    if combatActive then return end
    -- double-check combat *now* before arming
    local ok, inCombat = pcall(MS.IsInCombat)
    if not ok or not inCombat then return end

    combatActive = true
    local ms = tonumber(MS.config and MS.config.pollCombatMs) or 500
    MS.LogCore("combat detected → starting combat poller @" .. tostring(ms) .. " ms")
    MS_Poller.StartNamed("combat", ms, CombatTick, true)
end

local function StopCombatPoller()
    if not combatActive then return end
    combatActive = false
    MS_Poller.StopNamed("combat")
    MS.LogCore("combat ended → combat poller stopped")
end

-- ------------------------
-- World detector (slow) → starts/stops combat poller
-- ------------------------
local exitDebounceUntil = 0
local function WorldTick()
    local inCombat = MS.IsInCombat()
    MS.LogCore("world tick (inCombat=" .. tostring(inCombat) .. ")")

    if inCombat then
        exitDebounceUntil = 0
        if not combatActive then
            StartCombatPoller()
        end
        return
    end

    -- not in combat
    if combatActive then
        if exitDebounceUntil == 0 then
            exitDebounceUntil = nowSec() + 3 -- debounce 3s
            MS.LogCore("combat maybe ended → debouncing 3s")
        elseif nowSec() >= exitDebounceUntil then
            StopCombatPoller()
        end
    end
end

-- ------------------------
-- Lifecycle
-- ------------------------
function MS.Start()
    local worldMs = tonumber(MS.config and MS.config.pollWorldMs) or 3500
    MS.LogCore("starting world detector @ " .. tostring(worldMs) .. " ms")
    MS_Poller.StartNamed("world", worldMs, WorldTick, true)
end

function MS.Stop()
    MS_Poller.StopNamed("combat")
    MS_Poller.StopNamed("world")
end

function MS.Bootstrap()
    if MS._booted then return end
    MS._booted = true
    if MS.ReloadConfig then MS.ReloadConfig() end
    MS.LogCore("boot ok v" .. tostring(MS.version))
    math.randomseed(os.time() % 2147483647)
    MS.Start()
end

function MS:OnGameplayStarted()
    MS.LogCore("OnGameplayStarted → (re)start world detector")
    MS.Start()
end
