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

-- ------------------------
-- State
-- ------------------------
local combatActive = false
local rescanUntil = {} -- ent.id -> time (sec) before reconsidering
MercyStrike._combatEndTimer = MercyStrike._combatEndTimer or nil

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

    MS._tickIndex = (MS._tickIndex or 0) + 1

    local cfg = MS.config or {}

    local player = MS.GetPlayer and MS.GetPlayer() or (System and System.GetEntity and System.GetEntity(g_localActorId))

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

            -- 1) Corpse gate (API + name-substring)
            local corpse = false
            if MS.IsCorpse then
                local okC, resC = pcall(MS.IsCorpse, e)
                corpse = okC and (resC == true) or false
            end
            if (not corpse) and MS.NameMatches then
                local pats = (MS.config and MS.config.corpseNamePatterns) or { "corpse" }
                local okNm, hit = pcall(MS.NameMatches, name, pats)
                if okNm and hit then corpse = true end
            end

            if corpse then
                stat.filtered = stat.filtered + 1

                if cfg.logging and (cfg.logging.skip or cfg.logging.filters) then
                    MS.LogSkip("corpse name=" .. name)
                end
            else
                -- 2) Dog gate
                local isDog = false
                if MS.IsDog then
                    local okD, resD = pcall(MS.IsDog, e)
                    isDog = okD and (resD == true) or false
                end
                if (not isDog) and MS.NameMatches then
                    local pats = (MS.config and MS.config.dogNamePatterns) or {}
                    local okNm, hit = pcall(MS.NameMatches, name, pats)
                    if okNm and hit then isDog = true end
                end

                if isDog then
                    stat.filtered = stat.filtered + 1
                    if cfg.logging and (cfg.logging.skip or cfg.logging.filters) then
                        MS.LogSkip("dog name=" .. name)
                    end
                else
                    -- animal gate (optional)
                    local animal = false
                    if not cfg.includeAnimals then
                        local okA, isAnimal = pcall(MS.IsAnimalByName, e)
                        animal = okA and (isAnimal and true or false) or false
                        if animal then
                            stat.filtered = stat.filtered + 1
                            if cfg.logging and (cfg.logging.skip or cfg.logging.filters) then
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
                                    if cfg.logging and (cfg.logging.skip or cfg.logging.filters) then
                                        MS.LogSkip("notHostile name=" .. name)
                                    end
                                end
                            end
                        end

                        if hostile then
                            -- Ensure per-entity scratch FIRST (always exists, even on cooldown)
                            MercyStrike._per = MercyStrike._per or {}
                            MercyStrike._per[e.id] = MercyStrike._per[e.id] or {}
                            local S = MercyStrike._per[e.id]
                            local isBoss = MS.IsBoss and MS.IsBoss(e) or false

                            -- KO maintenance (if already KO'd)
                            if S.koApplied then
                                local cfg = MS.config or {}
                                local maintain = true
                                if cfg.koMaintainOnlyLast then
                                    maintain = (MercyStrike.lastKOId == e.id)
                                    local n = tonumber(cfg.koMaintainSweepNTicks) or 0
                                    if n and n > 0 then
                                        MS._tickIndex = (MS._tickIndex or 0)
                                        if (MS._tickIndex % n) == 0 then maintain = true end
                                    end
                                    local r = tonumber(cfg.koMaintainNearPlayerM) or 0
                                    if r > 0 then
                                        local player = System.GetEntity and System.GetEntity(g_localActorId or 0)
                                        if player and e.GetWorldPos and player.GetWorldPos then
                                            local pe, pp = { 0, 0, 0 }, { 0, 0, 0 }
                                            pcall(function() e:GetWorldPos(pe) end)
                                            pcall(function() player:GetWorldPos(pp) end)
                                            local dx, dy, dz = pe[1] - pp[1], pe[2] - pp[2], pe[3] - pp[3]
                                            if (dx * dx + dy * dy + dz * dz) <= (r * r) then maintain = true end
                                        end
                                    end
                                end
                                if maintain then
                                    if MS and MS.ClampHealthMin then
                                        MS.ClampHealthMin(e)
                                    else
                                        if MS and MS.ClampHealthPostKO then MS.ClampHealthPostKO(e) end
                                    end
                                end
                                -- done with KO’d targets
                            else
                                -- ALWAYS read + track HP (even during cooldown)
                                local okHP, hp = pcall(MS.GetNormalizedHp, e)

                                -- Early dead check (fallback to soul health if needed)
                                local isDead = false
                                if okHP and hp ~= nil then
                                    isDead = (hp <= 0)
                                else
                                    local s = e and e.soul
                                    if s then
                                        local okH, curHp = pcall(function() return s:GetHealth() end)
                                        isDead = okH and (curHp and curHp <= 0) or false
                                    end
                                end
                                if isDead then
                                    if S.koApplied and MS and MS.ClampHealthMin then MS.ClampHealthMin(e) end
                                else
                                    if not okHP then
                                        if cfg.logging and cfg.logging.core then
                                            MS.LogCore("ERR: step=GetNormalizedHp name=" .. name)
                                        end
                                    else
                                        -- track hp BEFORE cooldown gating so edges aren't missed
                                        local hpPrev = MercyStrike.TrackHp and MercyStrike.TrackHp(e, hp) or nil
                                        S.hpNow = hp

                                        -- quick stamp on visible drop while near player (helps ownership logs)
                                        if S.hpPrev and S.hpNow and S.hpNow < S.hpPrev then
                                            local close = false
                                            if player and player.GetWorldPos and e.GetWorldPos then
                                                local p, q = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
                                                pcall(player.GetWorldPos, player, p); pcall(e.GetWorldPos, e, q)
                                                local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
                                                local dMax = tonumber(cfg.hitsenseMaxDistance) or 7.0
                                                close = (dx * dx + dy * dy + dz * dz) <= (dMax * dMax)
                                            end
                                            if close and MercyStrike.RecordHit and player and player.id then
                                                MercyStrike.RecordHit(e.id, player.id)
                                            end
                                        end

                                        -- NOW gate the heavy work on cooldown
                                        if cooldownActive(e, tnow) then
                                            -- skip heavy work this tick, but we already tracked HP
                                        else
                                            -- HEAVY WORK
                                            seen = seen + 1
                                            stat.scanned = stat.scanned + 1

                                            if MS.LogProbe and cfg.logging and cfg.logging.probe then
                                                MS.LogProbe(string.format("name=%s hp=%.3f", name, hp or -1))
                                            end

                                            -- Death-like KO: intercept lethal or near-lethal drops
                                            do
                                                -- derive all signals once
                                                local lethalThr = tonumber(cfg.deathLikeLethalThr) or 0.05
                                                local dropMin   = tonumber(cfg.deathLikeMinDelta) or 0.30
                                                local atZero    = (hp or 0) <= 0
                                                local lethalNow = (hp or 0) <= lethalThr
                                                local bigDrop   = (hpPrev ~= nil and hp ~= nil) and
                                                    ((hpPrev - hp) >= dropMin) or
                                                    false

                                                if cfg.deathLikeKO and (hp ~= nil) then
                                                    -- Bosses: block death-like entirely if configured
                                                    if isBoss and cfg.boss and cfg.boss.blockDeathLike then
                                                        if cfg.logging and cfg.logging.probe then
                                                            MS.LogProbe("deathLike blocked (boss) name=" .. name)
                                                        end
                                                    else
                                                        -- AND/OR mode
                                                        local requireBoth = (cfg.deathLikeModeAND == true)
                                                        local shouldArm   = requireBoth and (lethalNow and bigDrop) or
                                                            (lethalNow or bigDrop)

                                                        if shouldArm then
                                                            -- ownership gate
                                                            local pass = true
                                                            if cfg.deathLikeRequireStamp and MS and MS.WasRecentlyHitByPlayer then
                                                                local okOwn, resOwn = pcall(MS.WasRecentlyHitByPlayer, e,
                                                                    cfg.ownershipWindowS or 1.2)
                                                                pass = okOwn and (resOwn and true or false) or false
                                                            end
                                                            if cfg.deathLikeRequireStamp and (not pass) and cfg.logging and cfg.logging.probe then
                                                                MS.LogProbe(("deathLike blocked (no ownership) name=%s")
                                                                    :format(
                                                                        name))
                                                            end

                                                            -- Big-dip extra roll (only for bigDrop without lethalNow)
                                                            if pass and (cfg.bigDipExtraRollEnabled == true) and bigDrop and (not lethalNow) then
                                                                local base  = tonumber(cfg.bigDipBaseChance) or 0.33
                                                                local bonus = tonumber(cfg.bigDipBonusAtCap) or 0.33
                                                                local cap   = tonumber(cfg.strengthCap) or 20
                                                                local str   = tonumber(MS.GetPlayerStrength and
                                                                    MS.GetPlayerStrength() or 0) or 0
                                                                if str < 0 then str = 0 elseif str > cap then str = cap end
                                                                local pExtra = base + bonus * (str / cap)
                                                                local pCap   = tonumber(cfg.applyChanceMax) or 1.0
                                                                if pExtra > pCap then pExtra = pCap end

                                                                local roll = math.random()
                                                                if cfg.logging and cfg.logging.probe then
                                                                    MS.LogProbe(("bigDip extra roll name=%s p=%.2f roll=%.2f str=%d/%d")
                                                                        :format(name, pExtra, roll, str, cap))
                                                                end
                                                                if roll > pExtra then
                                                                    pass = false
                                                                    if cfg.logging and cfg.logging.probe then
                                                                        MS.LogProbe("bigDip extra roll FAIL name=" ..
                                                                            name)
                                                                    end
                                                                end
                                                            end

                                                            if pass then
                                                                if cfg.deathLikeRequireStamp and cfg.logging and cfg.logging.hitsense then
                                                                    MS.LogProbe("deathLike ownership ✓ name=" .. name)
                                                                end
                                                                if cfg.logging and cfg.logging.probe then
                                                                    MS.LogProbe(("deathLike arm name=%s hpPrev=%s hp=%.3f lethalNow=%s bigDrop=%s")
                                                                        :format(name, tostring(hpPrev), hp or -1,
                                                                            tostring(lethalNow), tostring(bigDrop)))
                                                                end

                                                                -- suppress edge this tick
                                                                MercyStrike._per[e.id] = MercyStrike._per[e.id] or {}
                                                                MercyStrike._per[e.id]._armedDeathLike = true

                                                                -- rescue on zero so KO can land
                                                                if atZero and MS and MS.ClampHealthMin then
                                                                    MS.ClampHealthMin(e, (lethalThr * 0.6))
                                                                end

                                                                -- micro-delay (snap fast on lethal/zero)
                                                                local delay = tonumber(cfg.deathLikeDelayMs) or 120
                                                                if lethalNow or atZero then delay = math.min(delay, 30) end

                                                                Script.SetTimer(delay, function()
                                                                    local applied = false
                                                                    if MS_Unconscious and MS_Unconscious.Apply then
                                                                        local okA, resA = pcall(MS_Unconscious.Apply, e,
                                                                            cfg.buffId or "unconscious_permanent")
                                                                        applied = okA and resA or false
                                                                    end
                                                                    if applied then
                                                                        if cfg.logging and cfg.logging.probe then
                                                                            MS.LogProbe("deathLike KO applied name=" ..
                                                                                name)
                                                                        end
                                                                        stat.applied = stat.applied + 1
                                                                        if MS.ClampHealthPostKO then
                                                                            MS
                                                                                .ClampHealthPostKO(e)
                                                                        end
                                                                        MercyStrike._per[e.id]._armedDeathLike = nil
                                                                        armCooldown(e, nowSec())
                                                                    end
                                                                end)
                                                            end
                                                        end
                                                    end
                                                end
                                            end

                                            -- Edge KO (unchanged)
                                            local thr = tonumber(cfg.hpThreshold) or 0.12
                                            local crossed = (hpPrev ~= nil) and (hpPrev > thr) and (hp <= thr)
                                            if (not (MercyStrike and MercyStrike._per and e and e.id and MercyStrike._per[e.id] and MercyStrike._per[e.id]._armedDeathLike)) and crossed then
                                                stat.edges = stat.edges + 1

                                                -- ownership (logging only; based on HitSense stamps)
                                                local isYours = false
                                                if MS and MS.WasRecentlyHitByPlayer then
                                                    local okOwn, resOwn = pcall(MS.WasRecentlyHitByPlayer, e,
                                                        cfg.ownershipWindowS or 1.2)
                                                    isYours = okOwn and (resOwn and true or false) or false
                                                end
                                                if isYours then stat.yours = stat.yours + 1 end

                                                -- compute effective chance (static or scaled)
                                                local baseChance, warfare = MS.GetEffectiveApplyChance()

                                                -- ramp: 0.25..1.0 as HP drops deeper below thr
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

                                                -- Boss edge nerf
                                                if isBoss and cfg.boss and cfg.boss.edgeChanceFactor then
                                                    local f = tonumber(cfg.boss.edgeChanceFactor) or 1.0
                                                    chance = chance * f
                                                end
                                                if chance < 0 then chance = 0 elseif chance > 1 then chance = 1 end

                                                if cfg.logging and cfg.logging.probe then
                                                    MS.LogProbe(("edge name=%s hp=%.3f thr=%.2f ramp=%.2f p=%.2f")
                                                        :format(name, hp or -1, thr, ramp, chance))
                                                end

                                                -- single roll → single apply
                                                stat.rolled = stat.rolled + 1
                                                if (hp or 0) > 0 and math.random() < chance then
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
                                                        MS.LogApply("KO applied '" ..
                                                            tostring(cfg.buffId or "unconscious_permanent") ..
                                                            "' name=" .. name ..
                                                            " hp=" .. string.format("%.2f", hp or -1) ..
                                                            (cfg.scaleWithWarfare and (" (warfare=" .. tostring(warfare) ..
                                                                    ", p=" .. string.format("%.2f", chance) .. ")")
                                                                or (" (p=" .. string.format("%.2f", chance) .. " static)")))
                                                        if MS.ClampHealthPostKO then MS.ClampHealthPostKO(e) end
                                                        armCooldown(e, tnow)
                                                    else
                                                        if cfg.logging and cfg.logging.skip then
                                                            MS.LogSkip("rollFail name=" ..
                                                                name .. " (edge)")
                                                        end
                                                    end
                                                else
                                                    if cfg.logging and cfg.logging.skip then
                                                        MS.LogSkip("rollFail name=" ..
                                                            name .. " (edge)")
                                                    end
                                                end
                                            elseif cfg.logging and cfg.logging.skip then
                                                -- No edge this tick
                                                if (hp or 1) > thr then
                                                    -- still above threshold, just informational
                                                    MS.LogSkip("hpAboveThreshold name=" ..
                                                        name .. " hp=" .. string.format("%.3f", hp or -1))
                                                else
                                                    local prevStr = (hpPrev ~= nil) and string.format("%.3f", hpPrev) or
                                                        "nil"
                                                    MS.LogSkip("belowThresholdNoEdge name=" .. name ..
                                                        " hpPrev=" .. prevStr ..
                                                        " hp=" .. string.format("%.3f", hp or -1) ..
                                                        " thr=" .. tostring(thr))

                                                    -- One-time grace roll on first sighting under threshold (no ownership gating)
                                                    if hpPrev == nil then
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

                                                        if cfg.logging and cfg.logging.probe then
                                                            MS.LogProbe(("graceRoll name=%s hp=%.3f thr=%.2f ramp=%.2f p=%.2f")
                                                                :format(name, hp or -1, thr, ramp, chance))
                                                        end

                                                        stat.rolled = stat.rolled + 1
                                                        if (hp or 0) > 0 and math.random() < chance then
                                                            local applied = false
                                                            if MS_Unconscious and MS_Unconscious.Apply then
                                                                local okA, resA = pcall(MS_Unconscious.Apply, e,
                                                                    cfg.buffId or "unconscious_permanent")
                                                                applied = okA and resA or false
                                                                if (not okA) and cfg.logging and cfg.logging.core then
                                                                    MS.LogCore("ERR: step=Unconscious.Apply name=" ..
                                                                        name)
                                                                end
                                                            end
                                                            if applied then
                                                                stat.applied = stat.applied + 1
                                                                MS.LogApply("KO applied (grace) '" ..
                                                                    tostring(cfg.buffId or "unconscious_permanent") ..
                                                                    "' name=" .. name ..
                                                                    " hp=" .. string.format("%.2f", hp or -1) ..
                                                                    (cfg.scaleWithWarfare
                                                                        and (" (warfare=" .. tostring(warfare) ..
                                                                            ", p=" .. string.format("%.2f", chance) .. ")")
                                                                        or (" (p=" .. string.format("%.2f", chance) .. " static)")))

                                                                if MS.ClampHealthPostKO then MS.ClampHealthPostKO(e) end
                                                                armCooldown(e, tnow)
                                                            else
                                                                if cfg.logging and cfg.logging.skip then
                                                                    MS.LogSkip("rollFail name=" ..
                                                                        name .. " (grace)")
                                                                end
                                                            end
                                                        else
                                                            if cfg.logging and cfg.logging.skip then
                                                                MS.LogSkip("rollFail name=" ..
                                                                    name .. " (grace)")
                                                            end
                                                        end
                                                    end
                                                end
                                            elseif S.koApplied and MS and MS.ClampHealthMin then
                                                -- Optional: if they were KO'd already but engine shows dead, keep them floored
                                                MS.ClampHealthMin(e)
                                            end

                                            -- arm cooldown ONCE when heavy work done
                                            armCooldown(e, tnow)
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
    local dbg       = MS.config and MS.config.logging
    local wantZeros = dbg and (dbg.scanZeros == true) -- add this flag if you want
    local anyWork   = (stat.scanned > 0) or (stat.edges > 0) or (stat.rolled > 0) or (stat.applied > 0)
    if wantZeros or anyWork then
        MS.LogCore(string.format(
            "[KO] scan ▸ scanned=%d filtered=%d edges=%d yours=%d rolled=%d applied=%d",
            stat.scanned, stat.filtered, stat.edges, stat.yours, stat.rolled, stat.applied))
    end
end

local function StartCombatPoller()
    -- cancel pending end debounce if combat restarted
    if MercyStrike._combatEndTimer then
        Script.KillTimer(MercyStrike._combatEndTimer)
        MercyStrike._combatEndTimer = nil
    end

    if combatActive then return end
    combatActive  = true
    local ms      = tonumber(MS.config and MS.config.combatPollMs) or 500

    -- compute once
    local chance  = select(1, MS.GetEffectiveApplyChance())          -- only the chance
    local warfare = MS.GetWarfareLevel and MS.GetWarfareLevel() or 0 -- real warfare, even if scaling is off

    -- strength for big-dip logging
    local str     = tonumber(MS.GetPlayerStrength and MS.GetPlayerStrength() or 0) or 0
    local base    = tonumber(MS.config and MS.config.bigDipBaseChance) or 0.33
    local bonus   = tonumber(MS.config and MS.config.bigDipBonusAtCap) or 0.33
    local cap     = tonumber(MS.config and MS.config.strengthCap) or 20
    if str < 0 then str = 0 elseif str > cap then str = cap end

    local pExtra = base + bonus * (str / cap)
    local pCap   = tonumber(MS.config and MS.config.applyChanceMax) or 1.0
    if pExtra > pCap then pExtra = pCap end

    local leth = tonumber(MS.config and MS.config.deathLikeLethalThr) or 0.05
    local dMin = tonumber(MS.config and MS.config.deathLikeMinDelta) or 0.30
    local andM = (MS.config and MS.config.deathLikeModeAND) and "AND" or "OR"

    -- unified core log (always the same shape)
    if MS.config and MS.config.scaleWithWarfare then
        MS.LogCore(string.format(
            "combat detected → starting combat poller @%d ms (KO chance=%.1f%%, warfare=%d, strength=%d, bigDip p=%.1f%%, lethalThr=%.2f, minDelta=%.2f, mode=%s)",
            ms, (tonumber(chance or 0) * 100.0), tonumber(warfare or 0), str, (pExtra * 100.0), leth, dMin, andM
        ))
    else
        local baseApply = tonumber(MS.config and MS.config.applyBaseChance) or tonumber(chance or 0)
        MS.LogCore(string.format(
            "combat detected → starting combat poller @%d ms (KO chance=%.1f%% static; base=%.1f%%, warfare=%d, strength=%d, bigDip p=%.1f%%, lethalThr=%.2f, minDelta=%.2f, mode=%s)",
            ms, (tonumber(chance or 0) * 100.0), (baseApply * 100.0), tonumber(warfare or 0), str, (pExtra * 100.0), leth,
            dMin, andM
        ))
    end

    -- optional developer snapshot
    if MS.config and MS.config.logging and MS.config.logging.probe then
        MS.LogProbe(string.format(
            "[snapshot] warfare=%d strength=%d bigDip(p=%.2f base=%.2f bonus@cap=%.2f) lethalThr=%.2f minDelta=%.2f mode=%s",
            tonumber(warfare or 0), str, pExtra, base, bonus, leth, dMin, andM
        ))
    end

    if MS.config and MS.config.logging and MS.config.logging.probe then
        local scanR = (MS.config and MS.config.scanRadiusM) or 12
        local okList, near = pcall(MS.ScanSoulsInSphere, scanR, 48)
        if okList and type(near) == "table" then
            for i = 1, #near do
                local rec = near[i]
                local e   = rec and rec.e
                if e and MS.IsBoss and MS.IsBoss(e) then
                    local n = (e and e.GetName and pcall(e.GetName, e) and e:GetName()) or (e and e.id) or "<entity>"

                    MS.LogProbe("[snapshot] boss detected: " .. tostring(n))
                end
            end
        end
    end

    MS_Poller.StartNamed("combat", ms, CombatTick, true)

    -- ensure HitSense poller runs during combat
    if MS_Poller and MS_Poller.StartNamed and HS and HS.Tick then
        local hsMs = tonumber(MS.config and MS.config.hitsenseTickMs) or 200
        MS_Poller.StartNamed("hitsense", hsMs, HS.Tick, true)
    end
end

local function StopCombatPoller()
    if not combatActive then return end
    combatActive = false
    if MS_Poller and MS_Poller.StopNamed then
        MS_Poller.StopNamed("combat")
        MS_Poller.StopNamed("hitsense")
    end
    MS.LogCore("combat ended → poller[combat] stopped")
end

-- ------------------------
-- World detector (slow) → starts/stops combat poller
-- ------------------------
local function WorldTick()
    local inCombat = MS.IsInCombat()
    MS.LogCore("world tick (inCombat=" .. tostring(inCombat) .. ")")

    if inCombat then
        if not combatActive then
            StartCombatPoller()
        end
        return
    end

    -- not in combat
    if combatActive and (not inCombat) and (not MercyStrike._combatEndTimer) then
        MS.LogCore("combat maybe ended → debouncing 3s")
        MercyStrike._combatEndTimer = Script.SetTimer(3000, function()
            MercyStrike._combatEndTimer = nil
            local still = MS.IsInCombat() -- use the same world detector
            if not still then
                StopCombatPoller()
            else
                MS.LogCore("combat persisted → keeping poller[combat] running")
            end
        end)
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
    if MS_Poller and MS_Poller.StopNamed then
        MS_Poller.StopNamed("hitsense") -- add this
        MS_Poller.StopNamed("combat")
        MS_Poller.StopNamed("world")
    end
    -- also clear any pending end-debounce
    if MercyStrike._combatEndTimer then
        Script.KillTimer(MercyStrike._combatEndTimer)
        MercyStrike._combatEndTimer = nil
    end
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

-- Kick off after functions exist
if MS and MS.Bootstrap then MS.Bootstrap() end
