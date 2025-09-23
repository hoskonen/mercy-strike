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

-- Lua 5.1, no goto
local function CombatTick()
    -- still in combat?
    local okIC, inCombat = pcall(MS.IsInCombat)
    if not okIC then
        MS.LogCore("ERR: step=IsInCombat pcall"); return
    end
    if not inCombat then
        StopCombatPoller(); return
    end

    local cfg  = MS.config or {}
    local list = MS.ScanSoulsInSphere(cfg.scanRadiusM or 10.0, cfg.maxList or 48)
    if type(list) ~= "table" or #list == 0 then return end

    local maxN = tonumber(cfg.maxPerTick) or 8
    local seen = 0
    local tnow = nowSec()

    for i = 1, #list do
        if seen >= maxN then break end
        local rec = list[i]
        local e   = rec and rec.e
        if e then
            local name = MS.PrettyName and MS.PrettyName(e) or "<entity>"

            -- animal gate (optional)
            local animal = false
            if not cfg.includeAnimals then
                local okA, isAnimal = pcall(MS.IsAnimalByName, e)
                if not okA then
                    MS.LogCore("ERR: step=IsAnimalByName name=" .. name)
                    animal = true -- fail-closed: treat unknown as animal to skip
                else
                    animal = not not isAnimal
                end
            end

            if not animal then
                -- hostile gate
                local hostile = true
                if cfg.onlyHostile then
                    local okH, resH = pcall(MS.IsHostileToPlayer, e)
                    if not okH then
                        MS.LogCore("ERR: step=IsHostileToPlayer name=" .. name)
                        hostile = false
                    else
                        hostile = not not resH
                    end
                end

                if hostile then
                    -- per-entity rescan cooldown
                    if not cooldownActive(e, tnow) then
                        armCooldown(e, tnow)
                        seen = seen + 1

                        -- HP
                        local okHP, hp = pcall(MS.GetNormalizedHp, e)
                        if not okHP then
                            MS.LogCore("ERR: step=GetNormalizedHp name=" .. name)
                        else
                            if MS.LogProbe and cfg.logging and cfg.logging.probe then
                                MS.LogProbe(string.format("name=%s hp=%.3f", name, hp or -1))
                            end

                            if (hp or 1) <= (cfg.hpThreshold or 0.12) then
                                -- chance + apply (single-lane soul:AddBuff)
                                if math.random() < (cfg.applyChance or 0.20) then
                                    local okApply = (MS_Unconscious and MS_Unconscious.Apply)
                                        and MS_Unconscious.Apply(e, cfg.buffId or "unconscious_permanent")
                                    if okApply then
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
                    end
                    -- else: in rescan cooldown → silent skip
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
