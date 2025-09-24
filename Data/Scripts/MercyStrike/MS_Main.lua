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
Script.ReloadScript("Scripts/MercyStrike/MS_HitSense.lua")
-- Start ownership sampling first (cheap)
if MercyStrike and MercyStrike.HitSense and MercyStrike.HitSense.Start then
    MercyStrike.HitSense.Start()
end

-- IMPORTANT: start world/combat pollers
if MercyStrike and MercyStrike.Bootstrap then
    MercyStrike.Bootstrap()
else
    System.LogAlways("[MercyStrike] ERROR: Bootstrap missing")
end

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

    -- Per-tick stats
    local stat = {
        scanned  = 0, -- entities we looked at (not on cooldown)
        filtered = 0, -- skipped by gates (notHostile/animal/name/etc.)
        edges    = 0, -- crossed >thr -> <=thr this tick
        yours    = 0, -- of edges, owned by your hit (heuristic/bridge)
        rolled   = 0, -- we performed a KO roll
        applied  = 0, -- KO buff actually applied
    }
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
                if animal then
                    stat.filtered = stat.filtered + 1
                    if animal and cfg.logging and cfg.logging.skip then
                        MS.LogSkip("animal name=" .. name)
                    end
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
                        if not hostile then
                            stat.filtered = stat.filtered + 1
                            if (not hostile) and cfg.logging and cfg.logging.skip then
                                MS.LogSkip("notHostile name=" .. name)
                            end
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
                            stat.scanned = stat.scanned + 1
                            -- we successfully touched HP → arm cooldown now
                            armCooldown(e, tnow)

                            if MS.LogProbe and cfg.logging and cfg.logging.probe then
                                MS.LogProbe(string.format("name=%s hp=%.3f", name, hp or -1))
                            end

                            -- Edge-trigger KO tied to your hit
                            local thr = (cfg.hpThreshold or 0.12)

                            -- Track previous HP → detect crossing from above → below threshold
                            local hpPrev = nil
                            if MercyStrike.TrackHp then
                                hpPrev = MercyStrike.TrackHp(e, hp) -- single LHS grabs first return
                            end

                            -- (optional) stash current for heuristics that read it
                            if MercyStrike._per then
                                local k = e and e.id
                                if k then
                                    MercyStrike._per[k] = MercyStrike._per[k] or {}
                                    MercyStrike._per[k].hpNow = hp
                                end
                            end

                            local crossed = (hpPrev ~= nil) and (hpPrev > thr) and (hp <= thr)

                            if crossed then
                                stat.edges = stat.edges + 1
                                -- tie to "your hit" (heuristic/bridge only; no non-existent engine API)
                                local player = MS.GetPlayer and MS.GetPlayer() or
                                    (System and System.GetEntity and System.GetEntity(g_localActorId))
                                local recentYou = true
                                if MercyStrike.IsRecentPlayerHit then
                                    local okY, resY = pcall(MercyStrike.IsRecentPlayerHit, e, player, 0.6) -- 0.6s window
                                    recentYou = okY and resY or false
                                end

                                if recentYou then
                                    -- compute effective chance (static or scaled)
                                    local baseChance, warfare = MS.GetEffectiveApplyChance()

                                    -- soften edge at the threshold: ramp 0.25..1.0 as HP drops deeper below thr
                                    local ramp = 1.0
                                    if thr > 0 then
                                        local x = (hp or 0) / thr
                                        if x < 0 then x = 0 elseif x > 1 then x = 1 end
                                        ramp = 0.25 + (1.0 - x) * 0.75
                                    end
                                    local chance = baseChance * ramp
                                    if cfg.applyChanceMax and chance > cfg.applyChanceMax then
                                        chance = cfg.applyChanceMax
                                    end

                                    if cfg.logging and cfg.logging.probe then
                                        MS.LogProbe(("edge name=%s hp=%.3f thr=%.2f ramp=%.2f p=%.2f")
                                            :format(name, hp or -1, thr, ramp, chance))
                                    end

                                    stat.yours = stat.yours + 1

                                    -- logs
                                    if MS.LogProbe and cfg.logging and cfg.logging.probe then
                                        if cfg.scaleWithWarfare then
                                            MS.LogProbe(string.format(
                                                "edge chance=%.3f warfare=%d ramp=%.2f thr=%.2f hp=%.3f",
                                                chance, tonumber(warfare or 0), ramp, thr, hp or -1))
                                        else
                                            MS.LogProbe(string.format(
                                                "edge chance=%.3f (static) ramp=%.2f thr=%.2f hp=%.3f base=%.3f",
                                                chance, ramp, thr, hp or -1, baseChance))
                                        end
                                    end

                                    -- dead guard (shouldn’t happen on an edge, but be safe)
                                    if (hp or 0) <= 0 then
                                        if cfg.logging and cfg.logging.skip then MS.LogSkip("deadOrZeroHp name=" .. name) end
                                    else
                                        -- single roll → single apply
                                        stat.rolled = stat.rolled + 1
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
                                                stat.applied = stat.applied + 1
                                                MS.LogApply(
                                                    "KO applied '" .. tostring(cfg.buffId or "unconscious_permanent") ..
                                                    "' name=" .. name ..
                                                    " hp=" .. string.format("%.2f", hp or -1) ..
                                                    (cfg.scaleWithWarfare and (" (warfare=" .. tostring(warfare) ..
                                                            ", p=" .. string.format("%.2f", chance) .. ")") or
                                                        (" (p=" .. string.format("%.2f", chance) .. " static)"))
                                                )
                                                -- clamp after KO (uses your config floors)
                                                if MS.ClampHealthPostKO then MS.ClampHealthPostKO(e) end
                                                -- cooldown so we don’t immediately reconsider
                                                armCooldown(e, tnow)
                                            elseif cfg.logging and cfg.logging.skip then
                                                MS.LogSkip("rollFail name=" .. name)
                                            end
                                        else
                                            if cfg.logging and cfg.logging.skip then MS.LogSkip("rollFail name=" .. name) end
                                        end
                                    end
                                else
                                    -- crossed threshold but not your hit → ignore (prevents random delayed KO)
                                    if cfg.logging and cfg.logging.skip then
                                        MS.LogSkip(("edgeCrossedButNotYours name=%s hp=%.3f thr=%.2f")
                                            :format(name, hp or -1, thr))
                                    end
                                end
                            elseif cfg.logging and cfg.logging.skip then
                                -- No edge this tick
                                if (hp or 1) > thr then
                                    -- still above threshold, just informational
                                    MS.LogSkip("hpAboveThreshold name=" ..
                                        name .. " hp=" .. string.format("%.3f", hp or -1))
                                else
                                    -- already below threshold, but no edge observed this tick
                                    local prevStr = (hpPrev ~= nil) and string.format("%.3f", hpPrev) or "nil"
                                    MS.LogSkip("belowThresholdNoEdge name=" .. name ..
                                        " hpPrev=" .. prevStr ..
                                        " hp=" .. string.format("%.3f", hp or -1) ..
                                        " thr=" .. tostring(thr))

                                    -- NEW: grace roll if this is the first sighting and player hit recently
                                    if hpPrev == nil then
                                        local recentYou = false
                                        if MercyStrike.IsRecentPlayerHit then
                                            local okY, resY = pcall(MercyStrike.IsRecentPlayerHit, e, player, 0.7)
                                            recentYou = okY and resY or false
                                        end
                                        if recentYou then
                                            local baseChance, warfare = MS.GetEffectiveApplyChance()
                                            local ramp = 1.0
                                            if thr > 0 then
                                                local x = (hp or 0) / thr
                                                if x < 0 then x = 0 elseif x > 1 then x = 1 end
                                                ramp = 0.25 + (1.0 - x) * 0.75
                                            end
                                            local chance = baseChance * ramp
                                            if cfg.applyChanceMax and chance > cfg.applyChanceMax then
                                                chance = cfg.applyChanceMax
                                            end

                                            stat.rolled = stat.rolled + 1
                                            if cfg.logging and cfg.logging.probe then
                                                MS.LogProbe(("graceRoll name=%s hp=%.3f thr=%.2f ramp=%.2f p=%.2f")
                                                    :format(name, hp or -1, thr, ramp, chance))
                                            end

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
                                                    stat.applied = stat.applied + 1
                                                    MS.LogApply("KO applied (grace) '" ..
                                                        tostring(cfg.buffId or "unconscious_permanent") ..
                                                        "' name=" .. name ..
                                                        " hp=" .. string.format("%.2f", hp or -1) ..
                                                        (cfg.scaleWithWarfare and
                                                            (" (warfare=" .. tostring(warfare) ..
                                                                ", p=" .. string.format("%.2f", chance) .. ")") or
                                                            (" (p=" .. string.format("%.2f", chance) .. " static)")))
                                                    if MS.ClampHealthPostKO then MS.ClampHealthPostKO(e) end
                                                    armCooldown(e, tnow)
                                                else
                                                    MS.LogSkip("rollFail name=" .. name .. " (grace)")
                                                end
                                            else
                                                MS.LogSkip("rollFail name=" .. name .. " (grace)")
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- Per-tick summary
    if MS.LogCore and cfg.logging and (cfg.logging.probe or cfg.logging.core) then
        MS.LogCore(string.format(
            "[KO] scan ▸ scanned=%d filtered=%d edges=%d yours=%d rolled=%d applied=%d",
            stat.scanned, stat.filtered, stat.edges, stat.yours, stat.rolled, stat.applied
        ))
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
