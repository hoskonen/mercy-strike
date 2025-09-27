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

                                            -- Death-like KO block (unchanged; your current one lives here)
                                            -- (… existing death-like block …)

                                            -- Edge KO (unchanged)
                                            local thr = tonumber(cfg.hpThreshold) or 0.12
                                            local crossed = (hpPrev ~= nil) and (hpPrev > thr) and (hp <= thr)
                                            -- (… existing edge logic …)

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
