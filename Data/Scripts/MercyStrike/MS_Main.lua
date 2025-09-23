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

local function CombatTick()
    -- trust world detector; don't call IsInCombat() here
    if not combatActive then return end

    local cfg = MS.config or {}

    -- souls-only scan; pcall in case scene is hot-swapping entities
    local listOk, list = pcall(MS.ScanSoulsInSphere, cfg.scanRadiusM or 10.0, cfg.maxList or 48)
    if not listOk or type(list) ~= "table" or #list == 0 then return end

    local maxN = tonumber(cfg.maxPerTick) or 8
    local seen = 0
    local tnow = nowSec()

    for i = 1, #list do
        if seen >= maxN then break end

        local rec = list[i]
        local e   = rec and rec.e
        if e then
            local name = "<entity>"
            if MS.PrettyName then
                local okN, pretty = pcall(MS.PrettyName, e)
                if okN and pretty then name = tostring(pretty) end
            end

            -- animal gate (optional)
            local animal = false
            if not cfg.includeAnimals then
                local okA, isAnimal = pcall(MS.IsAnimalByName, e)
                animal = (not okA) and true or (not not isAnimal)
                if animal and cfg.logging and cfg.logging.skip then
                    MS.LogSkip("animal name=" .. name)
                end
            end

            if not animal then
                -- hostile gate (UH-style: faction/publicEnemy/aggression/soul-combat)
                local hostile = true
                if cfg.onlyHostile then
                    local okH, resH = pcall(MS.IsHostileToPlayer, e)
                    if not okH then
                        if cfg.logging and cfg.logging.core then
                            MS.LogCore("ERR: step=IsHostileToPlayer name=" .. name)
                        end
                        hostile = false
                    else
                        hostile = not not resH
                        if (not hostile) and cfg.logging and cfg.logging.skip then
                            MS.LogSkip("notHostile name=" .. name)
                        end
                    end
                end

                if hostile then
                    if cooldownActive(e, tnow) then
                        -- still cooling down → skip silently (or log if you want)
                        -- if cfg.logging and cfg.logging.skip then MS.LogSkip("cooldown name=" .. name) end
                    else
                        seen = seen + 1

                        -- HP
                        local okHP, hp = pcall(MS.GetNormalizedHp, e)
                        if not okHP then
                            if cfg.logging and cfg.logging.core then
                                MS.LogCore("ERR: step=GetNormalizedHp name=" .. name)
                            end
                            -- don't arm cooldown on failure → we'll retry soon
                        else
                            -- we successfully touched HP → arm cooldown now
                            armCooldown(e, tnow)

                            if MS.LogProbe and cfg.logging and cfg.logging.probe then
                                MS.LogProbe(string.format("name=%s hp=%.3f", name, hp or -1))
                            end

                            if (hp or 1) <= (cfg.hpThreshold or 0.12) then
                                -- compute effective chance
                                local chance, warfare = MS.GetEffectiveApplyChance()

                                -- static vs scaled log
                                if MS.LogProbe and cfg.logging and cfg.logging.probe then
                                    if cfg.scaleWithWarfare then
                                        MS.LogProbe(string.format("chance=%.3f warfare=%d", chance,
                                            tonumber(warfare or 0)))
                                    else
                                        local base = tonumber(cfg.applyBaseChance) or chance
                                        MS.LogProbe(string.format("chance=%.3f (static) base=%.3f scale=false", chance,
                                            base))
                                    end
                                end

                                -- dead guard
                                local isDead = (hp or 0) <= 0
                                if isDead then
                                    if cfg.logging and cfg.logging.skip then
                                        MS.LogSkip("deadOrZeroHp name=" .. name)
                                    end
                                else
                                    -- single roll → single apply
                                    if math.random() < chance then
                                        local applied = false
                                        if MS_Unconscious and MS_Unconscious.Apply then
                                            local okA, resA = pcall(MS_Unconscious.Apply, e,
                                                cfg.buffId or "unconscious_permanent")
                                            applied = okA and resA or false
                                            if (not okA) and cfg.logging and cfg.logging.core then
                                                MS.LogCore("ERR: step=Unconscious.Apply name=" .. name)
                                            end
                                        end

                                        if applied then
                                            MS.LogApply(
                                                "KO applied '" .. tostring(cfg.buffId or "unconscious_permanent") ..
                                                "' name=" .. name ..
                                                " hp=" .. string.format("%.2f", hp or -1) ..
                                                (cfg.scaleWithWarfare and (" (warfare=" .. tostring(warfare) ..
                                                        ", p=" .. string.format("%.2f", chance) .. ")") or
                                                    (" (p=" .. string.format("%.2f", chance) .. " static)"))
                                            )
                                            MS.ClampHealthPostKO(e)
                                        elseif cfg.logging and cfg.logging.skip then
                                            MS.LogSkip("applyFail name=" .. name)
                                        end
                                    else
                                        if cfg.logging and cfg.logging.skip then
                                            MS.LogSkip("rollFail name=" .. name)
                                        end
                                    end
                                end
                            elseif cfg.logging and cfg.logging.skip then
                                MS.LogSkip("hpAboveThreshold name=" .. name .. " hp=" .. string.format("%.3f", hp or -1))
                            end
                        end
                    end
                end
            end
        end
    end
end

local function StartCombatPoller()
    if combatActive then return end
    combatActive = true
    local ms = tonumber(MS.config and MS.config.pollCombatMs) or 500

    -- log effective chance + warfare level
    local chance, warfare = MS.GetEffectiveApplyChance()
    if chance then
        if MS.config and MS.config.scaleWithWarfare then
            MS.LogCore(string.format(
                "combat detected → starting combat poller @%d ms (KO chance=%.1f%%, warfare=%d)",
                ms, (chance * 100.0), tonumber(warfare or 0)
            ))
        else
            local base = tonumber(MS.config and MS.config.applyBaseChance) or chance
            MS.LogCore(string.format(
                "combat detected → starting combat poller @%d ms (KO chance=%.1f%% static; base=%.1f%%)",
                ms, (chance * 100.0), (base * 100.0)
            ))
        end
    else
        MS.LogCore("combat detected → starting combat poller @" .. tostring(ms) .. " ms")
    end


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
