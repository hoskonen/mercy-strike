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
Script.ReloadScript("Scripts/MercyStrike/MS_Diagnostics.lua")

-- ------------------------
-- State
-- ------------------------
local combatActive = false
local rescanUntil = {} -- ent.id -> time (sec) before reconsidering
MercyStrike._combatEndTimer = MercyStrike._combatEndTimer or nil
MercyStrike._sessionGeneration = MercyStrike._sessionGeneration or 0
local lastDiagnosticError = nil

local function RunDiagnostic(name, fn, ...)
    if type(fn) ~= "function" then return end
    local ok, err = pcall(fn, ...)
    if not ok then
        local message = tostring(name) .. ": " .. tostring(err)
        if lastDiagnosticError ~= message then
            lastDiagnosticError = message
            MS.LogCore("[Diag] error " .. message)
        end
    end
end

local function nowSec()
    if MS and MS.NowTime then
        local ok, value = pcall(MS.NowTime)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return tonumber(os.clock()) or 0
end

local function SessionGeneration()
    return tonumber(MercyStrike._sessionGeneration) or 0
end

local function SessionIsCurrent(generation)
    return generation == SessionGeneration()
end

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

-- ───────────────── helpers: filters ─────────────────

local function PrettyName(e)
    local name = "<entity>"
    if MS.PrettyName then
        local ok, res = pcall(MS.PrettyName, e)
        if ok and res then name = tostring(res) end
    end
    return name
end

local function IsCorpseByApiOrName(e, name, cfg)
    -- API
    local corpse = false
    if MS.IsCorpse then
        local ok, res = pcall(MS.IsCorpse, e)
        corpse = ok and (res == true) or false
    end
    -- name pattern
    if (not corpse) and MS.NameMatches then
        local pats = (cfg and cfg.corpseNamePatterns) or { "corpse" }
        local okNm, hit = pcall(MS.NameMatches, name, pats)
        if okNm and hit then corpse = true end
    end
    return corpse
end

local function IsDogByApiOrName(e, name, cfg)
    local dog = false
    if MS.IsDog then
        local ok, res = pcall(MS.IsDog, e)
        dog = ok and (res == true) or false
    end
    if (not dog) and MS.NameMatches then
        local pats = (cfg and cfg.dogNamePatterns) or {}
        local okNm, hit = pcall(MS.NameMatches, name, pats)
        if okNm and hit then dog = true end
    end
    return dog
end

local function IsAnimal(e, cfg)
    if cfg and cfg.includeAnimals then return false end
    local okA, isAnimal = pcall(MS.IsAnimalByName, e)
    return okA and (isAnimal == true) or false
end

local function IsHostile(e, cfg, name)
    if not (cfg and cfg.onlyHostile) then return true end
    local okH, resH = pcall(MS.IsHostileToPlayer, e)
    if not okH then
        if cfg.logging and cfg.logging.core then
            MS.LogCore("ERR: step=IsHostileToPlayer name=" .. name)
        end
        return false
    end
    return not not resH
end

-- ───────────────── helpers: per-entity scratch & KO maintenance ─────────────────

local function EnsurePer(e)
    MercyStrike._per = MercyStrike._per or {}
    MercyStrike._per[e.id] = MercyStrike._per[e.id] or {}
    return MercyStrike._per[e.id]
end

local function MaintainKOIfNeeded(e, S, cfg)
    if not S.koApplied then return end
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
            local pl = System.GetEntity and System.GetEntity(g_localActorId or 0)
            if pl and e.GetWorldPos and pl.GetWorldPos then
                local pe, pp = { 0, 0, 0 }, { 0, 0, 0 }
                pcall(function() e:GetWorldPos(pe) end)
                pcall(function() pl:GetWorldPos(pp) end)
                local dx, dy, dz = pe[1] - pp[1], pe[2] - pp[2], pe[3] - pp[3]
                if (dx * dx + dy * dy + dz * dz) <= (r * r) then maintain = true end
            end
        end
    end
    if maintain then
        if MS and MS.ClampHealthMin then
            MS.ClampHealthMin(e)
        elseif MS and MS.ClampHealthPostKO then
            MS.ClampHealthPostKO(e)
        end
    end
end

-- ───────────────── helpers: HP read/track ─────────────────

local function ReadHpNormalized(e)
    local ok, hp = pcall(MS.GetNormalizedHp, e)
    if not ok then return false, nil, false end
    local isDead = (hp ~= nil and hp <= 0)
    if not isDead and (hp == nil) then
        local s = e and e.soul
        if s then
            local okH, curHp = pcall(function() return s:GetHealth() end)
            isDead = okH and (curHp and curHp <= 0) or false
        end
    end
    return true, hp, isDead
end

local function CallObjectMethod(object, methodName)
    local okLookup, method = pcall(function()
        return object and object[methodName]
    end)
    if not okLookup or type(method) ~= "function" then
        return false, false, nil
    end
    local ok, result = pcall(method, object)
    return true, ok, ok and result or nil
end

local function ReadFinisherState(entity)
    local okTargetActor, targetActor = pcall(function()
        return entity and entity.actor
    end)
    if not okTargetActor then targetActor = nil end

    local player = nil
    if MS.GetPlayer then
        local okPlayer, value = pcall(MS.GetPlayer)
        if okPlayer then player = value end
    end
    local okPlayerActor, playerActor = pcall(function()
        return player and player.actor
    end)
    if not okPlayerActor then playerActor = nil end

    local unconsciousAvailable, unconsciousOk, unconscious =
        CallObjectMethod(targetActor, "IsUnconscious")
    local mercyAvailable, mercyOk, canMercy =
        CallObjectMethod(playerActor, "CanDoMercyKill")
    return {
        unconsciousAvailable = unconsciousAvailable,
        unconsciousOk = unconsciousOk,
        unconscious = unconscious,
        mercyAvailable = mercyAvailable,
        mercyOk = mercyOk,
        canMercy = canMercy,
    }
end

local function FinisherStateSignature(state)
    return table.concat({
        tostring(state and state.unconsciousAvailable),
        tostring(state and state.unconsciousOk),
        tostring(state and state.unconscious),
        tostring(state and state.mercyAvailable),
        tostring(state and state.mercyOk),
        tostring(state and state.canMercy),
    }, "|")
end

local function VectorComponent(value, name, index)
    if not value then return nil end
    local component = value[name]
    if component == nil then component = value[index] end
    return tonumber(component)
end

local function ReadWorldPos(entity)
    if not (entity and type(entity.GetWorldPos) == "function") then return nil end
    local ok, value = pcall(entity.GetWorldPos, entity)
    if ok and value then return value end
    local out = { x = 0, y = 0, z = 0 }
    ok = pcall(entity.GetWorldPos, entity, out)
    if ok then return out end
    return nil
end

local function DistanceMeters(a, b)
    local p, q = ReadWorldPos(a), ReadWorldPos(b)
    if not (p and q) then return nil end
    local px, py, pz = VectorComponent(p, "x", 1), VectorComponent(p, "y", 2), VectorComponent(p, "z", 3)
    local qx, qy, qz = VectorComponent(q, "x", 1), VectorComponent(q, "y", 2), VectorComponent(q, "z", 3)
    if not (px and py and pz and qx and qy and qz) then return nil end
    local dx, dy, dz = px - qx, py - qy, pz - qz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function DeathRescueAllowed(entity, cfg)
    if not (cfg and cfg.deathRescueAllow == true and cfg.deathLikeKO == true) then
        return false
    end
    if cfg.boss and cfg.boss.blockDeathLike and MS.IsBoss then
        local okBoss, isBoss = pcall(MS.IsBoss, entity)
        if okBoss and isBoss then return false end
    end
    return true
end

local WatchNaturalFall
local EnsureTransitionPoller
local StartMercyGuard
local StopMercyGuardPoller

local function ImmortalityProbeState(S)
    if not S then return "none" end
    if S.immortalityProbeReleasePending then return "releasePending" end
    if S.immortalityProbeReleaseScheduled then return "releaseScheduled" end
    if S.immortalityNaturalDowned then return "naturalDowned" end
    if S.immortalityTransitionWatching then return "watching" end
    if S.immortalityProbeApplied then return "armedOrphaned" end
    if S.immortalityProbeAttempted then return "attemptedOnly" end
    return "inactive"
end

local function ApplyImmortalityProbe(entity, S, cfg, name)
    if not (cfg and cfg.immortalityProbeEnabled == true) then return false end
    if not (entity and entity.soul and S) then return false end
    if cfg.boss and cfg.boss.blockDeathLike and MS.IsBoss then
        local okBoss, isBoss = pcall(MS.IsBoss, entity)
        if okBoss and isBoss then return false end
    end
    if S.immortalityProbeApplied or S.immortalityProbeAttempted then
        return S.immortalityProbeApplied == true
    end

    local guid = tostring(cfg.immortalityProbeBuffId or "")
    local add = entity.soul.AddBuff
    S.immortalityProbeAttempted = true
    if guid == "" or type(add) ~= "function" then
        MS.LogCore(string.format(
            "[ImmortalityProbe] add name=%s id=%s available=%s ok=false result=unavailable",
            name, tostring(entity.id), tostring(type(add) == "function")))
        return false
    end

    local ok, result = pcall(add, entity.soul, guid)
    S.immortalityProbeApplied = ok and true or false
    if ok then
        S.immortalityProbeEntity = entity
        S.immortalityProbeAppliedAt = nowSec()
        S.immortalityProbeAppliedGeneration = SessionGeneration()
        S.immortalityProbeReleaseAttempts = 0
    end
    MS.LogCore(string.format(
        "[ImmortalityProbe] add generation=%d name=%s id=%s buff=%s available=true ok=%s result=%s",
        SessionGeneration(), name, tostring(entity.id), guid, tostring(ok),
        tostring(result)))
    if S.immortalityProbeApplied and
            cfg.immortalityProbeObserveNaturalFall == true and
            type(WatchNaturalFall) == "function" then
        local _, hp = ReadHpNormalized(entity)
        WatchNaturalFall(entity, S, cfg, name, hp)
    end
    return S.immortalityProbeApplied
end

local function RemoveImmortalityProbe(entity, S, cfg, name, reason)
    if not (S and (S.immortalityProbeApplied or S.immortalityProbeAttempted)) then
        return false
    end
    entity = entity or S.immortalityProbeEntity
    local soul = entity and entity.soul
    local remove = soul and soul.RemoveAllBuffsByGuid
    local guid = tostring((cfg and cfg.immortalityProbeBuffId) or "")
    local available = type(remove) == "function" and guid ~= ""
    local callOk, result = false, nil
    if available then callOk, result = pcall(remove, soul, guid) end
    local tnow = nowSec()
    local age = S.immortalityProbeAppliedAt and
        math.max(0, tnow - S.immortalityProbeAppliedAt) or nil
    local state = ImmortalityProbeState(S)
    MS.LogCore(string.format(
        "[ImmortalityProbe] remove name=%s id=%s buff=%s reason=%s available=%s ok=%s result=%s",
        tostring(name or "<entity>"), tostring(entity and entity.id), guid,
        tostring(reason), tostring(available), tostring(callOk),
        tostring(result)))
    MS.LogCore(string.format(
        "[ProbeAudit] terminal generation=%d armedGeneration=%s name=%s id=%s state=%s reason=%s ageS=%s removeAvailable=%s removeCallOk=%s",
        SessionGeneration(), tostring(S.immortalityProbeAppliedGeneration),
        tostring(name or "<entity>"), tostring(entity and entity.id),
        state, tostring(reason),
        age and string.format("%.2f", age) or "unavailable",
        tostring(available), tostring(callOk)))
    S.immortalityProbeApplied = nil
    S.immortalityProbeAttempted = nil
    S.immortalityProbeEntity = nil
    S.immortalityProbeAppliedAt = nil
    S.immortalityProbeAppliedGeneration = nil
    S.immortalityProbeReleaseAttempts = nil
    S.immortalityNaturalDowned = nil
    S.immortalityNaturalDownedAt = nil
    S.immortalityProbeMonitorSeen = nil
    S.immortalityProbeMonitorHp = nil
    S.immortalityProbeMonitorDead = nil
    S.immortalityProbeMonitorCorpse = nil
    S.immortalityProbeFinisherSignature = nil
    S.immortalityProbeKOReadyAt = nil
    S.immortalityProbeKOScheduledHp = nil
    S.immortalityProbeReleaseScheduled = nil
    S.immortalityProbeReleasePending = nil
    S.immortalityProbeReleaseTrigger = nil
    S.immortalityProbeReleaseStartedAt = nil
    S.immortalityProbeReleaseUnconsciousAdded = nil
    S.immortalityProbeReleaseStateUnavailableLogged = nil
    S.immortalityTransitionWatching = nil
    S.immortalityTransitionEntity = nil
    S.immortalityTransitionName = nil
    S.immortalityTransitionStartedAt = nil
    S.immortalityTransitionLastHpChangeAt = nil
    S.immortalityTransitionHpPrev = nil
    S.immortalityTransitionStateFailures = nil
    S.immortalityTransitionInactivityLogged = nil
    return callOk
end

local function ClearMercyGuardState(S)
    if not S then return end
    S.mercyGuardActive = nil
    S.mercyGuardEntity = nil
    S.mercyGuardName = nil
    S.mercyGuardStartedAt = nil
    S.mercyGuardOutsideSince = nil
    S.mercyGuardStateFailures = nil
    S.mercyGuardDistanceFailures = nil
    S.mercyGuardClampCount = nil
    S.mercyGuardLastClampAt = nil
    S.mercyGuardLastHeartbeatAt = nil
end

local function StopMercyGuard(S, reason, hp, distance)
    if not (S and S.mercyGuardActive) then return end
    local entity = S.mercyGuardEntity
    local name = S.mercyGuardName or PrettyName(entity)
    local clamps = S.mercyGuardClampCount or 0
    ClearMercyGuardState(S)
    MS.LogCore(string.format(
        "[MercyGuard] stopped name=%s id=%s reason=%s hp=%s distanceM=%s clamps=%d",
        tostring(name), tostring(entity and entity.id), tostring(reason),
        tostring(hp), tostring(distance), clamps))
end

local function MercyGuardTick()
    local cfg = MS.config or {}
    local floorHp = tonumber(cfg.mercyGuardFloorHp) or 0.10
    local triggerHp = tonumber(cfg.mercyGuardTriggerHp) or 0.08
    if triggerHp > floorHp then triggerHp = floorHp end
    local clampCooldownS =
        (tonumber(cfg.mercyGuardClampCooldownMs) or 1000) / 1000
    if clampCooldownS < 0 then clampCooldownS = 0 end
    local radius = tonumber(cfg.mercyGuardRadiusM) or 10
    local outsideGrace = tonumber(cfg.mercyGuardOutsideGraceS) or 10
    local failureLimit = tonumber(cfg.mercyGuardStateFailureLimit) or 10
    local heartbeatS = tonumber(cfg.mercyGuardHeartbeatS) or 10
    local tnow = nowSec()
    local active = 0
    local player = nil
    if MS.GetPlayer then
        local okPlayer, value = pcall(MS.GetPlayer)
        if okPlayer then player = value end
    end

    for _, S in pairs(MercyStrike._per or {}) do
        if S and S.mercyGuardActive then
            active = active + 1
            local entity = S.mercyGuardEntity
            local okHP, hp, isDead = ReadHpNormalized(entity)
            local finisher = ReadFinisherState(entity)
            local unconscious = finisher.unconsciousOk and
                (finisher.unconscious == true or finisher.unconscious == 1)
            local distance = player and entity and
                DistanceMeters(player, entity) or nil

            if not entity then
                StopMercyGuard(S, "entityUnavailable", hp, distance)
                active = active - 1
            elseif isDead or (hp ~= nil and hp <= 0) then
                StopMercyGuard(S, "deadOrFinished", hp, distance)
                active = active - 1
            elseif finisher.unconsciousAvailable and
                    finisher.unconsciousOk and not unconscious then
                StopMercyGuard(S, "noLongerUnconscious", hp, distance)
                active = active - 1
            elseif not okHP or hp == nil or
                    not finisher.unconsciousAvailable or
                    not finisher.unconsciousOk then
                S.mercyGuardStateFailures =
                    (S.mercyGuardStateFailures or 0) + 1
                if S.mercyGuardStateFailures >= failureLimit then
                    StopMercyGuard(S, "stateUnavailable", hp, distance)
                    active = active - 1
                end
            else
                S.mercyGuardStateFailures = 0
                if distance == nil then
                    S.mercyGuardDistanceFailures =
                        (S.mercyGuardDistanceFailures or 0) + 1
                    if S.mercyGuardDistanceFailures >= failureLimit then
                        StopMercyGuard(S, "distanceUnavailable", hp, distance)
                        active = active - 1
                    end
                else
                    S.mercyGuardDistanceFailures = 0
                end

                if S.mercyGuardActive and distance and radius > 0 and
                        distance > radius then
                    S.mercyGuardOutsideSince =
                        S.mercyGuardOutsideSince or tnow
                    if outsideGrace <= 0 or
                            (tnow - S.mercyGuardOutsideSince) >= outsideGrace then
                        StopMercyGuard(S, "outsideGrace", hp, distance)
                        active = active - 1
                    end
                elseif S.mercyGuardActive and distance then
                    S.mercyGuardOutsideSince = nil
                end

                local lastClampAt = S.mercyGuardLastClampAt
                local clampReady = lastClampAt == nil or
                    (tnow - lastClampAt) >= clampCooldownS
                if S.mercyGuardActive and hp <= triggerHp and clampReady then
                    S.mercyGuardLastClampAt = tnow
                    local clamped = false
                    local clampMethod = "unavailable"
                    if MS.ClampHealthMin then
                        local okCall, changed, method =
                            pcall(MS.ClampHealthMin, entity, floorHp)
                        clamped = okCall and changed == true
                        clampMethod = okCall and tostring(method) or
                            ("error:" .. tostring(changed))
                    elseif MS.ClampHealthPostKO then
                        local okCall, changed, method =
                            pcall(MS.ClampHealthPostKO, entity)
                        clamped = okCall and changed == true
                        clampMethod = okCall and tostring(method) or
                            ("error:" .. tostring(changed))
                    end
                    local _, hpAfter = ReadHpNormalized(entity)
                    S.mercyGuardClampCount =
                        (S.mercyGuardClampCount or 0) + 1
                    local count = S.mercyGuardClampCount
                    if count == 1 or (count % 10) == 0 then
                        MS.LogCore(string.format(
                            "[MercyGuard] clamp name=%s id=%s hpBefore=%s hpAfter=%s trigger=%s floor=%s cooldownS=%s ok=%s method=%s count=%d",
                            tostring(S.mercyGuardName),
                            tostring(entity and entity.id), tostring(hp),
                            tostring(hpAfter), tostring(triggerHp),
                            tostring(floorHp), tostring(clampCooldownS),
                            tostring(clamped), tostring(clampMethod), count))
                    end
                end

                if S.mercyGuardActive and heartbeatS > 0 then
                    local lastHeartbeat =
                        S.mercyGuardLastHeartbeatAt or
                        S.mercyGuardStartedAt or tnow
                    if (tnow - lastHeartbeat) >= heartbeatS then
                        S.mercyGuardLastHeartbeatAt = tnow
                        MS.LogCore(string.format(
                            "[MercyGuard] heartbeat generation=%d name=%s id=%s hp=%s distanceM=%s unconscious=%s clamps=%d",
                            SessionGeneration(), tostring(S.mercyGuardName),
                            tostring(entity.id), tostring(hp),
                            tostring(distance), tostring(unconscious),
                            S.mercyGuardClampCount or 0))
                    end
                end
            end
        end
    end
    return active > 0
end

local function EnsureMercyGuardPoller()
    if MercyStrike._mercyGuardTimerId then return true end
    if not (Script and type(Script.SetTimer) == "function") then return false end

    local interval = tonumber(MS.config and MS.config.mercyGuardPollMs) or 100
    local generation = SessionGeneration()
    local function tick()
        if not SessionIsCurrent(generation) then return end
        MercyStrike._mercyGuardTimerId = nil
        local ok, hasActive = xpcall(MercyGuardTick, debug.traceback)
        if not ok then
            MS.LogCore("[MercyGuard] poller error: " .. tostring(hasActive))
            return
        end
        if hasActive and SessionIsCurrent(generation) then
            MercyStrike._mercyGuardTimerId = Script.SetTimer(interval, tick)
        else
            MS.LogCore("[MercyGuard] poller stopped reason=idle")
        end
    end

    local ok, hasActive = xpcall(MercyGuardTick, debug.traceback)
    if not ok then
        MS.LogCore("[MercyGuard] poller start error: " .. tostring(hasActive))
        return false
    end
    if not hasActive then return false end
    MercyStrike._mercyGuardTimerId = Script.SetTimer(interval, tick)
    MS.LogCore("[MercyGuard] poller started (" .. tostring(interval) .. " ms)")
    return true
end

StartMercyGuard = function(entity, S, cfg, name, hp)
    if not (cfg and cfg.mercyGuardEnabled == true) then return false end
    if not (entity and S) or S.mercyGuardActive then return false end
    S.mercyGuardActive = true
    S.mercyGuardEntity = entity
    S.mercyGuardName = name
    S.mercyGuardStartedAt = nowSec()
    S.mercyGuardOutsideSince = nil
    S.mercyGuardStateFailures = 0
    S.mercyGuardDistanceFailures = 0
    S.mercyGuardClampCount = 0
    S.mercyGuardLastClampAt = nil
    S.mercyGuardLastHeartbeatAt = nowSec()
    MS.LogCore(string.format(
        "[MercyGuard] started name=%s id=%s hp=%s trigger=%s floor=%s pollMs=%s clampCooldownMs=%s radiusM=%s outsideGraceS=%s",
        tostring(name), tostring(entity.id), tostring(hp),
        tostring(cfg.mercyGuardTriggerHp or 0.08),
        tostring(cfg.mercyGuardFloorHp or 0.10),
        tostring(cfg.mercyGuardPollMs or 100),
        tostring(cfg.mercyGuardClampCooldownMs or 1000),
        tostring(cfg.mercyGuardRadiusM or 10),
        tostring(cfg.mercyGuardOutsideGraceS or 10)))
    local started = EnsureMercyGuardPoller()
    if not started and S.mercyGuardActive then
        StopMercyGuard(S, "pollerUnavailable", hp, nil)
    end
    return started
end

StopMercyGuardPoller = function(reason)
    local timerId = MercyStrike._mercyGuardTimerId
    if timerId then
        pcall(Script.KillTimer, timerId)
        MercyStrike._mercyGuardTimerId = nil
        MS.LogCore("[MercyGuard] poller stopped reason=" ..
            tostring(reason or "manual"))
    end
end

local function CompleteImmortalityProbeRelease(entity, S, cfg, name, reason)
    if not (entity and S and S.immortalityProbeApplied) then return false end

    local trigger = tostring(S.immortalityProbeReleaseTrigger or "unknown")
    local unconsciousAdded =
        S.immortalityProbeReleaseUnconsciousAdded == true
    local releaseMinHp =
        tonumber(cfg and cfg.immortalityProbeReleaseMinHp) or 0.25
    local okBefore, hpBefore, deadBefore = ReadHpNormalized(entity)
    local corpseBefore = IsCorpseByApiOrName(entity, name, cfg)

    local clampCallOk = false
    local clampSuccess = false
    local clampMethod = "unavailable"
    local clampBeforeAbs = nil
    local clampAfterAbs = nil
    if MS.ClampHealthMin then
        clampCallOk, clampSuccess, clampMethod, clampBeforeAbs, clampAfterAbs =
            pcall(MS.ClampHealthMin, entity, releaseMinHp)
    elseif MS.ClampHealthPostKO then
        clampCallOk, clampSuccess, clampMethod, clampBeforeAbs, clampAfterAbs =
            pcall(MS.ClampHealthPostKO, entity)
    end
    MS.LogCore(string.format(
        "[HealthClamp] release name=%s id=%s floor=%s callOk=%s success=%s method=%s hpAbsBefore=%s hpAbsAfter=%s",
        tostring(name), tostring(entity.id), tostring(releaseMinHp),
        tostring(clampCallOk), tostring(clampSuccess), tostring(clampMethod),
        tostring(clampBeforeAbs), tostring(clampAfterAbs)))

    local okClamped, hpClamped, deadClamped = ReadHpNormalized(entity)
    local removed = RemoveImmortalityProbe(entity, S, cfg, name,
        trigger .. "StableRelease")
    S.immortalityProbeReleasedForFinisher = removed and true or false
    S.immortalityProbeReleasedEntity = entity
    S.immortalityProbeReleasedName = name

    local okAfter, hpAfter, deadAfter = ReadHpNormalized(entity)
    local corpseAfter = IsCorpseByApiOrName(entity, name, cfg)
    local finisherAfter = ReadFinisherState(entity)
    S.immortalityProbeReleasedMonitorSeen = true
    S.immortalityProbeReleasedMonitorHp = hpAfter
    S.immortalityProbeReleasedMonitorDead = deadAfter
    S.immortalityProbeReleasedMonitorCorpse = corpseAfter
    S.immortalityProbeReleasedFinisherSignature =
        FinisherStateSignature(finisherAfter)
    MS.LogCore(string.format(
        "[ImmortalityProbe] stable release name=%s id=%s trigger=%s reason=%s removed=%s unconsciousPreexisting=%s unconsciousAdded=%s hpBefore=%s hpClamped=%s releaseMinHp=%s deadBefore=%s deadClamped=%s corpseBefore=%s hpAfter=%s deadAfter=%s corpseAfter=%s targetIsUnconscious=%s stateReadBeforeOk=%s stateReadClampedOk=%s stateReadAfterOk=%s",
        tostring(name), tostring(entity.id), trigger, tostring(reason),
        tostring(removed), tostring(S.koApplied == true and
            not unconsciousAdded), tostring(unconsciousAdded),
        tostring(hpBefore), tostring(hpClamped), tostring(releaseMinHp),
        tostring(deadBefore), tostring(deadClamped), tostring(corpseBefore),
        tostring(hpAfter), tostring(deadAfter), tostring(corpseAfter),
        tostring(finisherAfter.unconscious), tostring(okBefore),
        tostring(okClamped), tostring(okAfter)))
    local unconsciousAfter = finisherAfter.unconsciousOk and
        (finisherAfter.unconscious == true or
            finisherAfter.unconscious == 1)
    if removed and okAfter and not deadAfter and unconsciousAfter and
            type(StartMercyGuard) == "function" then
        StartMercyGuard(entity, S, cfg, name, hpAfter)
    end
    return removed
end

local function ScheduleImmortalityProbeRelease(entity, S, cfg, name, trigger,
        delayOverride)
    trigger = tostring(trigger or "naturalDown")
    local enabled = cfg and cfg.immortalityProbeReleaseAfterNaturalDown == true
    local delay = tonumber(cfg and cfg.immortalityProbeReleaseDelayMs) or 1000
    if trigger == "confirmedKO" then
        enabled = cfg and cfg.immortalityProbeReleaseAfterKO == true
        delay = tonumber(cfg and cfg.immortalityProbeReleaseAfterKODelayMs) or 1500
    elseif trigger == "engineDown" then
        delay = tonumber(cfg and cfg.immortalityProbeEngineDownSettleMs) or 1500
    elseif trigger == "timeoutFallback" or
            trigger == "inactivityFallback" or
            trigger == "absoluteTimeoutFallback" then
        delay = tonumber(cfg and
            cfg.immortalityProbeTimeoutFallbackDelayMs) or 750
    end
    if delayOverride ~= nil then
        delay = tonumber(delayOverride) or delay
    end
    if not enabled then return end
    if not (entity and S and S.immortalityProbeApplied) then return end
    if S.immortalityProbeReleaseScheduled or
            S.immortalityProbeReleasedForFinisher then
        return
    end
    if not (Script and type(Script.SetTimer) == "function") then
        MS.LogCore("[ImmortalityProbe] release unavailable name=" ..
            tostring(name) .. " reason=Script.SetTimer")
        return
    end

    if delay < 0 then delay = 0 end
    S.immortalityProbeReleaseScheduled = true
    local sessionGeneration = SessionGeneration()
    MS.LogCore(string.format(
        "[ImmortalityProbe] release scheduled generation=%d name=%s id=%s trigger=%s delayMs=%d koApplied=%s",
        sessionGeneration,
        tostring(name), tostring(entity.id), trigger, delay,
        tostring(S.koApplied == true)))

    local function releaseCallback()
        if not SessionIsCurrent(sessionGeneration) then return end
        S.immortalityProbeReleaseScheduled = nil
        if not S.immortalityProbeApplied then
            MS.LogCore("[ImmortalityProbe] release skipped name=" ..
                tostring(name) .. " reason=probeNoLongerActive")
            return
        end

        local okBefore, hpBefore, deadBefore = ReadHpNormalized(entity)
        local corpseBefore = IsCorpseByApiOrName(entity, name, cfg)
        S.immortalityProbeReleaseAttempts =
            (S.immortalityProbeReleaseAttempts or 0) + 1
        local attempt = S.immortalityProbeReleaseAttempts
        local unconsciousReady = S.koApplied == true
        local unconsciousAdded = false
        if not unconsciousReady and MS_Unconscious and MS_Unconscious.Apply then
            local okApply, result = pcall(MS_Unconscious.Apply, entity,
                cfg.buffId or "unconscious_permanent")
            unconsciousAdded = okApply and result or false
            unconsciousReady = unconsciousAdded
            if not okApply then
                MS.LogCore("ERR: step=ImmortalityProbe.Release.Unconscious.Apply name=" ..
                    tostring(name))
            end
        end

        if not unconsciousReady then
            local retryLimit = tonumber(
                cfg.immortalityProbeReleaseRetryLimit) or 3
            local retryMs = tonumber(
                cfg.immortalityProbeReleaseRetryMs) or 500
            if retryLimit < 1 then retryLimit = 1 end
            if attempt < retryLimit then
                MS.LogCore(string.format(
                    "[ProbeAudit] release retry generation=%d name=%s id=%s trigger=%s attempt=%d limit=%d delayMs=%d hp=%s dead=%s corpse=%s reason=unconsciousNotReady",
                    SessionGeneration(), tostring(name), tostring(entity.id),
                    trigger, attempt, retryLimit, retryMs,
                    tostring(hpBefore), tostring(deadBefore),
                    tostring(corpseBefore)))
                ScheduleImmortalityProbeRelease(entity, S, cfg, name,
                    trigger, retryMs)
            else
                MS.LogCore(string.format(
                    "[ProbeAudit] release failed name=%s id=%s trigger=%s attempts=%d hp=%s dead=%s corpse=%s action=removeImmortality",
                    tostring(name), tostring(entity.id), trigger, attempt,
                    tostring(hpBefore), tostring(deadBefore),
                    tostring(corpseBefore)))
                RemoveImmortalityProbe(entity, S, cfg, name,
                    "releaseUnconsciousFailed")
            end
            return
        end

        local startedAt = nowSec()
        S.immortalityProbeReleasePending = true
        S.immortalityProbeReleaseTrigger = trigger
        S.immortalityProbeReleaseStartedAt = startedAt
        S.immortalityProbeReleaseUnconsciousAdded =
            unconsciousAdded and true or false
        S.immortalityTransitionWatching = true
        S.immortalityTransitionEntity = entity
        S.immortalityTransitionName = name
        S.immortalityTransitionStartedAt = startedAt
        S.immortalityTransitionLastHpChangeAt = startedAt
        S.immortalityTransitionHpPrev = hpBefore
        S.immortalityTransitionStateFailures = 0
        MS.LogCore(string.format(
            "[ImmortalityProbe] release stabilization started name=%s id=%s trigger=%s unconsciousPreexisting=%s unconsciousAdded=%s hp=%s dead=%s corpse=%s stableTargetS=%s absoluteTimeoutS=%s releaseMinHp=%s stateReadOk=%s",
            tostring(name), tostring(entity.id), trigger,
            tostring(S.koApplied == true and not unconsciousAdded),
            tostring(unconsciousAdded), tostring(hpBefore),
            tostring(deadBefore), tostring(corpseBefore),
            tostring(cfg.immortalityProbeReleaseStableS or 5),
            tostring(cfg.immortalityProbeReleaseAbsoluteTimeoutS or 60),
            tostring(cfg.immortalityProbeReleaseMinHp or 0.25),
            tostring(okBefore)))
        if type(EnsureTransitionPoller) == "function" then
            EnsureTransitionPoller()
        end
    end

    local timerOk, timerResult = pcall(Script.SetTimer, delay,
        releaseCallback)
    if not timerOk or timerResult == nil then
        S.immortalityProbeReleaseScheduled = nil
        MS.LogCore(string.format(
            "[ProbeAudit] release timer failed name=%s id=%s trigger=%s delayMs=%d callOk=%s result=%s action=removeImmortality",
            tostring(name), tostring(entity.id), trigger, delay,
            tostring(timerOk), tostring(timerResult)))
        RemoveImmortalityProbe(entity, S, cfg, name,
            "releaseTimerUnavailable")
    end
end

local function TransitionTick()
    local cfg = MS.config or {}
    local inactivityTimeout =
        tonumber(cfg.immortalityProbeTransitionWatchTimeoutS) or 20
    local absoluteTimeout =
        tonumber(cfg.immortalityProbeTransitionAbsoluteTimeoutS) or 90
    local safeRecoveryHp =
        tonumber(cfg.immortalityProbeSafeRecoveryHp) or 0.25
    local timeoutFallbackHp =
        tonumber(cfg.immortalityProbeTimeoutFallbackHp) or 0.15
    local safeStableS =
        tonumber(cfg.immortalityProbeSafeRecoveryStableS) or 5
    local failureLimit =
        tonumber(cfg.immortalityProbeStateFailureLimit) or 10
    local releaseStableS =
        tonumber(cfg.immortalityProbeReleaseStableS) or 5
    local releaseAbsoluteTimeout =
        tonumber(cfg.immortalityProbeReleaseAbsoluteTimeoutS) or 60
    local tnow = nowSec()
    local inCombat = false
    if MS.IsInCombat then
        local okCombat, value = pcall(MS.IsInCombat)
        inCombat = okCombat and value == true
    end
    local active = 0

    for _, S in pairs(MercyStrike._per or {}) do
        if S and S.immortalityTransitionWatching then
            active = active + 1
            local entity = S.immortalityTransitionEntity
            local name = S.immortalityTransitionName or PrettyName(entity)
            if not (entity and S.immortalityProbeApplied) then
                S.immortalityTransitionWatching = nil
                active = active - 1
            else
                local okHP, hp, isDead = ReadHpNormalized(entity)
                local finisher = ReadFinisherState(entity)
                local engineUnconscious = finisher.unconsciousOk and
                    (finisher.unconscious == true or finisher.unconscious == 1)
                local hpPrev = S.immortalityTransitionHpPrev
                local fromMax = tonumber(cfg.naturalDownResetFromMax) or 0.50
                local toMin = tonumber(cfg.naturalDownResetToMin) or 0.90
                local riseMin = tonumber(cfg.naturalDownResetRiseMin) or 0.50
                local rise = hpPrev ~= nil and hp ~= nil and (hp - hpPrev) or nil
                local resetObserved = hpPrev ~= nil and hp ~= nil and
                    hpPrev <= fromMax and hp >= toMin and rise >= riseMin

                if okHP and hp ~= nil then
                    S.immortalityTransitionStateFailures = 0
                    S.immortalityProbeReleaseStateUnavailableLogged = nil
                    if hpPrev == nil or math.abs(hp - hpPrev) >= 0.00001 then
                        S.immortalityTransitionLastHpChangeAt = tnow
                        S.immortalityTransitionInactivityLogged = nil
                    end
                    S.immortalityTransitionHpPrev = hp
                else
                    S.immortalityTransitionStateFailures =
                        (S.immortalityTransitionStateFailures or 0) + 1
                end

                local startedAt = S.immortalityTransitionStartedAt or tnow
                local lastChangeAt =
                    S.immortalityTransitionLastHpChangeAt or startedAt
                local inactiveFor = tnow - lastChangeAt
                local age = tnow - startedAt
                local stateUnavailable =
                    (S.immortalityTransitionStateFailures or 0) >= failureLimit
                local recoveredConscious = not inCombat and not engineUnconscious and
                    hp ~= nil and hp >= safeRecoveryHp and
                    inactiveFor >= safeStableS
                local timedOut = not inCombat and inactivityTimeout > 0 and
                    inactiveFor >= inactivityTimeout
                local absoluteTimedOut = absoluteTimeout > 0 and
                    age >= absoluteTimeout

                if S.immortalityProbeReleasePending then
                    local releaseStartedAt =
                        S.immortalityProbeReleaseStartedAt or startedAt
                    local releaseAge = tnow - releaseStartedAt
                    local releaseStable = okHP and hp ~= nil and
                        not isDead and inactiveFor >= releaseStableS
                    local releaseTimedOut = releaseAbsoluteTimeout > 0 and
                        releaseAge >= releaseAbsoluteTimeout
                    if releaseStable or releaseTimedOut then
                        S.immortalityTransitionWatching = nil
                        active = active - 1
                        MS.LogCore(string.format(
                            "[ImmortalityProbe] release stabilization complete name=%s id=%s hp=%s stableS=%.2f ageS=%.2f timedOut=%s",
                            tostring(name), tostring(entity.id), tostring(hp),
                            inactiveFor, releaseAge,
                            tostring(releaseTimedOut)))
                        CompleteImmortalityProbeRelease(entity, S, cfg, name,
                            releaseStable and "hpStable" or "absoluteTimeout")
                    elseif stateUnavailable then
                        if not S.immortalityProbeReleaseStateUnavailableLogged then
                            S.immortalityProbeReleaseStateUnavailableLogged = true
                            MS.LogCore(string.format(
                                "[ImmortalityProbe] release stabilization waiting name=%s id=%s failures=%d reason=stateUnavailable probeRetained=true",
                                tostring(name), tostring(entity.id),
                                S.immortalityTransitionStateFailures or 0))
                        end
                    end
                elseif engineUnconscious or resetObserved then
                    S.immortalityTransitionWatching = nil
                    active = active - 1
                    S.immortalityNaturalDowned = true
                    S.immortalityNaturalDownedAt = tnow
                    MS.LogCore(string.format(
                        "[ImmortalityProbe] engine down observed name=%s id=%s hpPrev=%s hp=%s resetObserved=%s targetIsUnconscious=%s dead=%s ageS=%.2f stateReadOk=%s",
                        tostring(name), tostring(entity.id), tostring(hpPrev),
                        tostring(hp), tostring(resetObserved),
                        tostring(finisher.unconscious), tostring(isDead),
                        age,
                        tostring(okHP)))
                    ScheduleImmortalityProbeRelease(entity, S, cfg, name,
                        "engineDown")
                elseif recoveredConscious then
                    S.immortalityTransitionWatching = nil
                    active = active - 1
                    MS.LogCore(string.format(
                        "[ImmortalityProbe] protection safely cancelled name=%s id=%s hp=%s stableS=%.2f ageS=%.2f reason=recoveredConscious",
                        tostring(name), tostring(entity.id), tostring(hp),
                        inactiveFor, age))
                    RemoveImmortalityProbe(entity, S, cfg, name,
                        "recoveredConscious")
                elseif stateUnavailable then
                    S.immortalityTransitionWatching = nil
                    active = active - 1
                    MS.LogCore(string.format(
                        "[ImmortalityProbe] protection cleanup name=%s id=%s failures=%d reason=stateUnavailable",
                        tostring(name), tostring(entity.id),
                        S.immortalityTransitionStateFailures or 0))
                    RemoveImmortalityProbe(entity, S, cfg, name,
                        "stateUnavailable")
                elseif absoluteTimedOut then
                    S.immortalityTransitionWatching = nil
                    active = active - 1
                    if hp ~= nil and hp <= timeoutFallbackHp then
                        MS.LogCore(string.format(
                            "[ImmortalityProbe] protection absolute timeout fallback name=%s id=%s hp=%s inactiveS=%.2f ageS=%.2f fallbackHp=%s targetIsUnconscious=%s",
                            tostring(name), tostring(entity.id), tostring(hp),
                            inactiveFor, age, tostring(timeoutFallbackHp),
                            tostring(finisher.unconscious)))
                        ScheduleImmortalityProbeRelease(entity, S, cfg, name,
                            "absoluteTimeoutFallback")
                    else
                        MS.LogCore(string.format(
                            "[ImmortalityProbe] protection absolute timeout cleanup name=%s id=%s hp=%s inactiveS=%.2f ageS=%.2f fallback=false",
                            tostring(name), tostring(entity.id), tostring(hp),
                            inactiveFor, age))
                        RemoveImmortalityProbe(entity, S, cfg, name,
                            "absoluteTimeoutConscious")
                    end
                elseif timedOut and hp ~= nil and hp <= timeoutFallbackHp then
                    S.immortalityTransitionWatching = nil
                    active = active - 1
                    MS.LogCore(string.format(
                        "[ImmortalityProbe] protection inactivity fallback name=%s id=%s hp=%s inactiveS=%.2f ageS=%.2f fallbackHp=%s targetIsUnconscious=%s",
                        tostring(name), tostring(entity.id), tostring(hp),
                        inactiveFor, age, tostring(timeoutFallbackHp),
                        tostring(finisher.unconscious)))
                    ScheduleImmortalityProbeRelease(entity, S, cfg, name,
                        "inactivityFallback")
                elseif timedOut and
                        cfg.immortalityProbeCleanupWoundedConsciousOnTimeout ==
                            true then
                    S.immortalityTransitionWatching = nil
                    active = active - 1
                    MS.LogCore(string.format(
                        "[ProbeAudit] protection timeout cleanup name=%s id=%s hp=%s inactiveS=%.2f ageS=%.2f fallbackHp=%s recoveryHp=%s inCombat=%s reason=woundedConsciousStable",
                        tostring(name), tostring(entity.id), tostring(hp),
                        inactiveFor, age, tostring(timeoutFallbackHp),
                        tostring(safeRecoveryHp), tostring(inCombat)))
                    RemoveImmortalityProbe(entity, S, cfg, name,
                        "inactivityWoundedConscious")
                elseif timedOut and not
                        S.immortalityTransitionInactivityLogged then
                    S.immortalityTransitionInactivityLogged = true
                    MS.LogCore(string.format(
                        "[ImmortalityProbe] protection retained name=%s id=%s hp=%s inactiveS=%.2f ageS=%.2f fallbackHp=%s recoveryHp=%s reason=woundedConsciousWaiting cleanupOnTimeout=false",
                        tostring(name), tostring(entity.id), tostring(hp),
                        inactiveFor, age, tostring(timeoutFallbackHp),
                        tostring(safeRecoveryHp)))
                end
            end
        end
    end
    return active > 0
end

local function StopTransitionPoller(reason)
    local timerId = MercyStrike._transitionTimerId
    if timerId then
        pcall(Script.KillTimer, timerId)
        MercyStrike._transitionTimerId = nil
        MS.LogCore("[ImmortalityProbe] transition poller stopped reason=" ..
            tostring(reason or "idle"))
    end
end

EnsureTransitionPoller = function()
    if MercyStrike._transitionTimerId then return true end
    if not (Script and type(Script.SetTimer) == "function") then return false end

    -- Stop a transition channel left by an older hot-reloaded build.
    if MS_Poller and MS_Poller.StopNamed then
        MS_Poller.StopNamed("transition")
    end

    local interval = tonumber(MS.config and
        MS.config.immortalityProbeTransitionPollMs) or 100
    local generation = SessionGeneration()
    local function tick()
        if not SessionIsCurrent(generation) then return end
        MercyStrike._transitionTimerId = nil
        local ok, hasActive = xpcall(TransitionTick, debug.traceback)
        if not ok then
            MS.LogCore("[ImmortalityProbe] transition poller error: " ..
                tostring(hasActive))
            return
        end
        if hasActive and SessionIsCurrent(generation) then
            MercyStrike._transitionTimerId =
                Script.SetTimer(interval, tick)
        else
            MS.LogCore(
                "[ImmortalityProbe] transition poller stopped reason=idle")
        end
    end

    local ok, hasActive = xpcall(TransitionTick, debug.traceback)
    if not ok then
        MS.LogCore("[ImmortalityProbe] transition poller start error: " ..
            tostring(hasActive))
        return false
    end
    if not hasActive then return false end
    MercyStrike._transitionTimerId = Script.SetTimer(interval, tick)
    MS.LogCore("[ImmortalityProbe] transition poller started (" ..
        tostring(interval) .. " ms)")
    return true
end

WatchNaturalFall = function(entity, S, cfg, name, hp)
    if not (entity and S and S.immortalityProbeApplied) then return false end
    if S.immortalityTransitionWatching or S.immortalityNaturalDowned then
        return true
    end
    S.immortalityTransitionWatching = true
    S.immortalityTransitionEntity = entity
    S.immortalityTransitionName = name
    S.immortalityTransitionStartedAt = nowSec()
    S.immortalityTransitionLastHpChangeAt =
        S.immortalityTransitionStartedAt
    S.immortalityTransitionHpPrev = hp
    S.immortalityTransitionStateFailures = 0
    S.immortalityTransitionInactivityLogged = nil
    S.immortalityProbeKOReadyAt = nil
    S.immortalityProbeKOScheduledHp = nil
    MS.LogCore(string.format(
        "[ImmortalityProbe] natural fall watch started name=%s id=%s hp=%s inactivityTimeoutS=%s absoluteTimeoutS=%s",
        tostring(name), tostring(entity.id), tostring(hp),
        tostring(cfg.immortalityProbeTransitionWatchTimeoutS or 20),
        tostring(cfg.immortalityProbeTransitionAbsoluteTimeoutS or 90)))
    local started = EnsureTransitionPoller()
    if not started then
        S.immortalityTransitionWatching = nil
        MS.LogCore(string.format(
            "[ProbeAudit] natural fall watch failed name=%s id=%s action=terminalCleanupRequired",
            tostring(name), tostring(entity.id)))
    end
    return started
end

function MercyStrike.CleanupImmortalityProbes(reason)
    local attempted = 0
    local removed = 0
    for _, S in pairs(MercyStrike._per or {}) do
        if S and (S.immortalityProbeApplied or S.immortalityProbeAttempted) then
            attempted = attempted + 1
            local entity = S.immortalityProbeEntity
            if RemoveImmortalityProbe(entity, S, MS.config or {},
                    PrettyName(entity), reason or "manualCleanup") then
                removed = removed + 1
            end
        end
    end
    MS.LogCore(string.format(
        "[ImmortalityProbe] cleanup complete reason=%s attempted=%d removed=%d failed=%d",
        tostring(reason or "manualCleanup"), attempted, removed,
        attempted - removed))
    return removed
end

local function MonitorRetainedImmortalityProbes()
    for _, S in pairs(MercyStrike._per or {}) do
        local retainAll = MS.config and
            MS.config.immortalityProbeRetainAllCandidates == true
        local retained = S and (retainAll or S.koApplied or
            S.immortalityNaturalDowned)
        if retained and S.immortalityProbeApplied then
            local entity = S.immortalityProbeEntity
            local name = PrettyName(entity)
            local okHP, hp, isDead = ReadHpNormalized(entity)
            local corpse = IsCorpseByApiOrName(entity, name, MS.config or {})
            local finisher = ReadFinisherState(entity)
            local finisherSignature = FinisherStateSignature(finisher)
            local managed = S.immortalityTransitionWatching or
                S.immortalityProbeReleaseScheduled or
                S.immortalityProbeReleasePending
            if not managed then
                local stateBefore = ImmortalityProbeState(S)
                MS.LogCore(string.format(
                    "[ProbeAudit] orphan detected generation=%d name=%s id=%s state=%s hp=%s dead=%s corpse=%s naturalDowned=%s action=restartTerminalPath",
                    SessionGeneration(), tostring(name),
                    tostring(entity and entity.id), stateBefore,
                    tostring(hp), tostring(isDead), tostring(corpse),
                    tostring(S.immortalityNaturalDowned == true)))
                if S.immortalityNaturalDowned then
                    ScheduleImmortalityProbeRelease(entity, S,
                        MS.config or {}, name, "engineDown")
                else
                    WatchNaturalFall(entity, S, MS.config or {}, name, hp)
                end
                managed = S.immortalityTransitionWatching or
                    S.immortalityProbeReleaseScheduled or
                    S.immortalityProbeReleasePending
                if not managed and S.immortalityProbeApplied then
                    MS.LogCore(string.format(
                        "[ProbeAudit] orphan recovery failed name=%s id=%s state=%s action=removeImmortality",
                        tostring(name), tostring(entity and entity.id),
                        ImmortalityProbeState(S)))
                    RemoveImmortalityProbe(entity, S, MS.config or {},
                        name, "orphanRecoveryFailed")
                end
            end
            local previousHp = S.immortalityProbeMonitorHp
            local stateChanged = S.immortalityProbeMonitorDead ~= isDead or
                S.immortalityProbeMonitorCorpse ~= corpse
            local hpChanged = hp ~= nil and (previousHp == nil or
                math.abs(hp - previousHp) >= 0.005 or hp <= 0.01)
            local finisherChanged =
                S.immortalityProbeFinisherSignature ~= finisherSignature
            if S.immortalityProbeApplied and
                    (stateChanged or hpChanged or finisherChanged or
                    not S.immortalityProbeMonitorSeen) then
                MS.LogCore(string.format(
                    "[ImmortalityProbe] retained monitor name=%s id=%s hp=%s dead=%s corpse=%s koApplied=%s naturalDowned=%s targetIsUnconsciousAvail=%s targetIsUnconsciousOk=%s targetIsUnconscious=%s playerCanMercyAvail=%s playerCanMercyOk=%s playerCanMercy=%s stateReadOk=%s",
                    name, tostring(entity and entity.id), tostring(hp),
                    tostring(isDead), tostring(corpse), tostring(S.koApplied == true),
                    tostring(S.immortalityNaturalDowned == true),
                    tostring(finisher.unconsciousAvailable),
                    tostring(finisher.unconsciousOk),
                    tostring(finisher.unconscious),
                    tostring(finisher.mercyAvailable),
                    tostring(finisher.mercyOk),
                    tostring(finisher.canMercy), tostring(okHP)))
                S.immortalityProbeMonitorSeen = true
                S.immortalityProbeMonitorHp = hp
                S.immortalityProbeMonitorDead = isDead
                S.immortalityProbeMonitorCorpse = corpse
                S.immortalityProbeFinisherSignature = finisherSignature
            end
            if S.immortalityProbeApplied and corpse and MS.config and
                    MS.config.immortalityProbeCleanupOnCorpse == true then
                RemoveImmortalityProbe(entity, S, MS.config or {}, name,
                    "retainedMonitorCorpse")
            end
        elseif S and S.immortalityProbeReleasedForFinisher and
                S.immortalityProbeReleasedEntity then
            local entity = S.immortalityProbeReleasedEntity
            local name = S.immortalityProbeReleasedName or PrettyName(entity)
            local okHP, hp, isDead = ReadHpNormalized(entity)
            local corpse = IsCorpseByApiOrName(entity, name, MS.config or {})
            local finisher = ReadFinisherState(entity)
            local finisherSignature = FinisherStateSignature(finisher)
            local previousHp = S.immortalityProbeReleasedMonitorHp
            local stateChanged =
                S.immortalityProbeReleasedMonitorDead ~= isDead or
                S.immortalityProbeReleasedMonitorCorpse ~= corpse
            local hpChanged = hp ~= nil and (previousHp == nil or
                math.abs(hp - previousHp) >= 0.005)
            local finisherChanged =
                S.immortalityProbeReleasedFinisherSignature ~= finisherSignature
            if stateChanged or hpChanged or finisherChanged or
                    not S.immortalityProbeReleasedMonitorSeen then
                MS.LogCore(string.format(
                    "[ImmortalityProbe] released monitor name=%s id=%s hp=%s dead=%s corpse=%s koApplied=%s targetIsUnconsciousAvail=%s targetIsUnconsciousOk=%s targetIsUnconscious=%s playerCanMercyAvail=%s playerCanMercyOk=%s playerCanMercy=%s stateReadOk=%s",
                    tostring(name), tostring(entity.id), tostring(hp),
                    tostring(isDead), tostring(corpse),
                    tostring(S.koApplied == true),
                    tostring(finisher.unconsciousAvailable),
                    tostring(finisher.unconsciousOk),
                    tostring(finisher.unconscious),
                    tostring(finisher.mercyAvailable),
                    tostring(finisher.mercyOk),
                    tostring(finisher.canMercy), tostring(okHP)))
                S.immortalityProbeReleasedMonitorSeen = true
                S.immortalityProbeReleasedMonitorHp = hp
                S.immortalityProbeReleasedMonitorDead = isDead
                S.immortalityProbeReleasedMonitorCorpse = corpse
                S.immortalityProbeReleasedFinisherSignature =
                    finisherSignature
            end
        end
    end
end

local function ObserveCombatCandidates(list, cfg)
    if type(list) ~= "table" then return end
    local okPlayer, player = false, nil
    if MS.GetPlayer then okPlayer, player = pcall(MS.GetPlayer) end
    if not okPlayer then player = nil end
    if not player then return end
    local session = MS._candidateSession or 0
    local tnow = nowSec()
    local minDrop = tonumber(cfg.candidateDropMin) or 0.10
    local maxDistance = tonumber(cfg.candidateMaxDistanceM) or 4.0
    local window = tonumber(cfg.candidateWindowS) or 2.0

    for i = 1, #list do
        local entity = list[i] and list[i].e
        if entity and entity.id then
            local name = PrettyName(entity)
            local corpseBefore = IsCorpseByApiOrName(entity, name, cfg)
            local excluded = IsDogByApiOrName(entity, name, cfg) or IsAnimal(entity, cfg)
            if not excluded then
                local S = EnsurePer(entity)
                if S.candidateSession ~= session then
                    S.candidateSession = session
                    S.discoveryHpPrev = nil
                    S.candidatePending = nil
                    S.candidateHpPrev = nil
                    S.candidateUntil = nil
                    S.pendingEdgeHpPrev = nil
                    S.pendingEdgeHp = nil
                    S.zeroRescuePending = nil
                end

                -- A live entity may become a corpse before the next 200 ms poll.
                -- Continue reading only if this session already observed it alive;
                -- this keeps static corpses from entering candidate logic.
                local mayBeNewlyDead = S.discoveryHpPrev ~= nil or S.candidatePending == true
                local okHP, hp = false, nil
                if (not corpseBefore) or mayBeNewlyDead then
                    okHP, hp = ReadHpNormalized(entity)
                end
                if okHP and hp ~= nil then
                    local hpPrev = S.discoveryHpPrev
                    S.discoveryHpPrev = hp
                    if S.immortalityProbeApplied and hpPrev ~= nil and
                            not S.immortalityNaturalDowned and
                            cfg.immortalityProbeObserveNaturalFall ~= true then
                        local fromMax = tonumber(cfg.naturalDownResetFromMax) or 0.50
                        local toMin = tonumber(cfg.naturalDownResetToMin) or 0.90
                        local riseMin = tonumber(cfg.naturalDownResetRiseMin) or 0.50
                        local rise = hp - hpPrev
                        if hpPrev <= fromMax and hp >= toMin and rise >= riseMin then
                            S.immortalityNaturalDowned = true
                            S.immortalityNaturalDownedAt = tnow
                            MS.LogCore(string.format(
                                "[ImmortalityProbe] natural down detected id=%s name=%s hpPrev=%.4f hp=%.4f rise=%.4f",
                                tostring(entity.id), name, hpPrev, hp, rise))
                            ScheduleImmortalityProbeRelease(entity, S, cfg, name,
                                "naturalDown")
                        end
                    end
                    if hpPrev ~= nil and hp < hpPrev then
                        local drop = hpPrev - hp
                        if drop >= minDrop then
                            local distance = DistanceMeters(player, entity)
                            if distance and distance <= maxDistance then
                                if not S.candidatePending or not S.candidateHpPrev or
                                        hpPrev > S.candidateHpPrev then
                                    S.candidateHpPrev = hpPrev
                                end
                                S.candidateHpNow = hp
                                S.candidatePending = true
                                S.candidateUntil = tnow + window
                                S.candidateDrop = drop
                                S.candidateDistance = distance
                                if MS.RecordHit and player.id then
                                    pcall(MS.RecordHit, entity.id, player.id)
                                end
                                MS.LogCore(string.format(
                                    "[Candidate] stamp id=%s name=%s hpPrev=%.4f hp=%.4f drop=%.4f distM=%.2f windowS=%.2f",
                                    tostring(entity.id), name, hpPrev, hp, drop, distance, window))

                                if hp > 0 and not corpseBefore then
                                    ApplyImmortalityProbe(entity, S, cfg, name)
                                end

                                if hp <= 0 and DeathRescueAllowed(entity, cfg) then
                                    S.zeroRescuePending = true
                                    S.zeroRescueObservedAt = tnow
                                    local rescueFloor = (tonumber(cfg.deathLikeLethalThr) or 0.05) * 0.6
                                    MS.LogCore(string.format(
                                        "[Rescue] zero observed id=%s name=%s hpPrev=%.4f drop=%.4f distM=%.2f corpseBefore=%s floor=%.4f",
                                        tostring(entity.id), name, hpPrev, drop, distance,
                                        tostring(corpseBefore), rescueFloor))

                                    if MS.ClampHealthMin then
                                        pcall(MS.ClampHealthMin, entity, rescueFloor)
                                    end
                                    local okAfter, hpAfter, deadAfter = ReadHpNormalized(entity)
                                    local corpseAfter = IsCorpseByApiOrName(entity, name, cfg)
                                    if okAfter and hpAfter ~= nil then
                                        S.discoveryHpPrev = hpAfter
                                    end
                                    MS.LogCore(string.format(
                                        "[Rescue] clamp result id=%s name=%s hpAfter=%s deadAfter=%s corpseAfter=%s",
                                        tostring(entity.id), name, tostring(hpAfter),
                                        tostring(deadAfter), tostring(corpseAfter)))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function TrackHpAndMaybeStamp(e, S, hp, cfg, player)
    local hpPrev = MercyStrike.TrackHp and MercyStrike.TrackHp(e, hp) or nil
    S.hpNow = hp
    -- cheap ownership stamp on visible drops
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
    return hpPrev
end

-- ───────────────── helpers: KO logic blocks ─────────────────

local function DeathLikeKO(e, name, S, hpPrev, hp, cfg, tnow, isBoss, stat)
    if not (cfg.deathLikeKO and hp ~= nil) then return end
    if S.immortalityProbeApplied and
            cfg.immortalityProbeObserveNaturalFall == true then
        return
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
                local shouldArm
                if requireBoth then
                    shouldArm = lethalNow and bigDrop
                else
                    shouldArm = lethalNow or bigDrop
                end

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
                        local probeDelay = S.immortalityProbeApplied == true
                        if probeDelay then
                            delay = tonumber(cfg.immortalityProbeKODelayMs) or 450
                        elseif lethalNow or atZero then
                            delay = math.min(delay, 30)
                        end
                        MS.LogCore(string.format(
                            "[ImmortalityProbe] deathLike KO scheduled name=%s hp=%.4f delayMs=%d probeProtected=%s",
                            name, hp or -1, delay, tostring(probeDelay)))

                        local sessionGeneration = SessionGeneration()
                        Script.SetTimer(delay, function()
                            if not SessionIsCurrent(sessionGeneration) then
                                return
                            end
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
                                local hadProbe = S.immortalityProbeApplied == true
                                local retainProbe = hadProbe and
                                    cfg.immortalityProbeRetainAfterKO == true
                                local probeRemoved = false
                                if not retainProbe then
                                    probeRemoved = RemoveImmortalityProbe(e, S, cfg, name,
                                        "deathLikeKOApplied")
                                end
                                if hadProbe then
                                    local okAfter, hpAfter, deadAfter = ReadHpNormalized(e)
                                    local corpseAfter = IsCorpseByApiOrName(e, name, cfg)
                                    MS.LogCore(string.format(
                                        "[ImmortalityProbe] post-deathLike name=%s hpAfter=%s deadAfter=%s corpseAfter=%s probeRetained=%s probeRemoved=%s stateReadOk=%s",
                                        name, tostring(hpAfter), tostring(deadAfter),
                                        tostring(corpseAfter), tostring(retainProbe),
                                        tostring(probeRemoved), tostring(okAfter)))
                                end
                                if retainProbe then
                                    ScheduleImmortalityProbeRelease(e, S, cfg, name,
                                        "confirmedKO")
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
end

local function EdgeKO(e, name, S, hpPrev, hp, cfg, isBoss, stat)
    -- >>> PASTE your existing edge block body here (the one you restored) <<<
    -- (ramped chance, boss factor, grace roll, Apply+Clamp, logging)

    -- Edge KO (unchanged)
    local thr = tonumber(cfg.hpThreshold) or 0.12
    local deathLikeArmed = MercyStrike and MercyStrike._per and e and e.id and
        MercyStrike._per[e.id] and MercyStrike._per[e.id]._armedDeathLike
    local probeReady = S.immortalityProbeApplied == true and hp ~= nil and
        hp <= thr and not deathLikeArmed

    -- Natural-fall feasibility path: the threshold only starts a durable
    -- observer. Immortality remains active while the engine processes the
    -- eventual lethal/down transition; no unconscious buff is forced here.
    if cfg.immortalityProbeObserveNaturalFall == true and
            S.immortalityProbeApplied then
        if probeReady then
            WatchNaturalFall(e, S, cfg, name, hp)
            return
        end
        if S.immortalityTransitionWatching or S.immortalityNaturalDowned then
            return
        end
    end

    -- Deterministic feasibility path. The probe already proves that this is a
    -- close-range combat candidate; keep it eligible after the short discovery
    -- window and apply unconsciousness before removing immortality.
    if not probeReady and S.immortalityProbeKOReadyAt ~= nil then
        MS.LogCore(string.format(
            "[ImmortalityProbe] threshold KO cancelled name=%s hp=%s reason=leftThresholdOrDeathLikeArmed",
            name, tostring(hp)))
        S.immortalityProbeKOReadyAt = nil
        S.immortalityProbeKOScheduledHp = nil
    end
    if probeReady then
        local tnow = nowSec()
        local delayMs = tonumber(cfg.immortalityProbeKODelayMs) or 450
        if S.immortalityProbeKOReadyAt == nil then
            S.immortalityProbeKOReadyAt = tnow + (delayMs / 1000)
            S.immortalityProbeKOScheduledHp = hp
            MS.LogCore(string.format(
                "[ImmortalityProbe] threshold KO scheduled name=%s hp=%.4f thr=%.4f delayMs=%d",
                name, hp, thr, delayMs))
            return
        end
        if tnow < S.immortalityProbeKOReadyAt then return end

        local scheduledHp = S.immortalityProbeKOScheduledHp
        S.immortalityProbeKOReadyAt = nil
        S.immortalityProbeKOScheduledHp = nil
        stat.edges = stat.edges + 1
        stat.yours = stat.yours + 1
        stat.rolled = stat.rolled + 1
        MS.LogProbe(string.format(
            "[ImmortalityProbe] threshold name=%s hp=%.4f scheduledHp=%s thr=%.4f hpPrev=%s deterministic=true",
            name, hp, tostring(scheduledHp), thr, tostring(hpPrev)))

        local applied = false
        if MS_Unconscious and MS_Unconscious.Apply then
            local okApply, result = pcall(MS_Unconscious.Apply, e,
                cfg.buffId or "unconscious_permanent")
            applied = okApply and result or false
            if not okApply then
                MS.LogCore("ERR: step=ImmortalityProbe.Unconscious.Apply name=" .. name)
            end
        end

        if applied then
            stat.applied = stat.applied + 1
            if MS.ClampHealthPostKO then MS.ClampHealthPostKO(e) end
            local retainProbe = cfg.immortalityProbeRetainAfterKO == true
            local removed = false
            if not retainProbe then
                removed = RemoveImmortalityProbe(e, S, cfg, name,
                    "deterministicProbeKOApplied")
            end
            local okAfter, hpAfter, deadAfter = ReadHpNormalized(e)
            local corpseAfter = IsCorpseByApiOrName(e, name, cfg)
            MS.LogApply(string.format(
                "KO applied (immortality probe) name=%s hpBefore=%.4f hpAfter=%s deadAfter=%s corpseAfter=%s probeRetained=%s probeRemoved=%s stateReadOk=%s",
                name, hp, tostring(hpAfter), tostring(deadAfter),
                tostring(corpseAfter), tostring(retainProbe),
                tostring(removed), tostring(okAfter)))
            if retainProbe then
                ScheduleImmortalityProbeRelease(e, S, cfg, name, "confirmedKO")
            end
        else
            MS.LogCore(string.format(
                "[ImmortalityProbe] deterministic KO apply failed name=%s hp=%.4f; probe retained for retry",
                name, hp))
        end
        return
    end

    local crossed = (hpPrev ~= nil) and (hpPrev > thr) and (hp <= thr)
    if (not deathLikeArmed) and crossed then
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
                RemoveImmortalityProbe(e, S, cfg, name, "edgeKOApplied")
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
        if (hp or 1) <= thr then
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
                        RemoveImmortalityProbe(e, S, cfg, name, "graceKOApplied")
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
end


local function CombatTick()
    -- if not combatActive then return end
    if not combatActive then return end

    MS._tickIndex = (MS._tickIndex or 0) + 1
    local cfg = MS.config or {}
    local listOk, list = pcall(MS.ScanSoulsInSphere, cfg.scanRadiusM or 10.0, cfg.maxList or 48)
    if listOk and type(list) == "table" then
        ObserveCombatCandidates(list, cfg)
    end
    if MS.Diagnostics and MS.Diagnostics.Scan then
        RunDiagnostic("scan", MS.Diagnostics.Scan,
            (listOk and type(list) == "table") and list or {}, cfg)
    end
    if not listOk or type(list) ~= "table" or #list == 0 then return end
    local maxN = tonumber(cfg.maxPerTick) or 8
    local seen = 0

    -- Per-tick stats
    local stat = {
        scanned  = 0, -- entities we looked at (not on cooldown)
        filtered = 0, -- skipped by gates (notHostile/animal/name/etc.)
        edges    = 0, -- crossed >thr -> <=thr this tick
        yours    = 0, -- of edges, owned by your hit (heuristic/bridge)
        rolled   = 0, -- we performed a KO roll
        applied  = 0, -- KO buff actually applied
    }

    -- Handle exactly one target; early-out with 'return' instead of goto/break tricks
    local function processEntity(e)
        local cfg    = MS.config or {}
        local player = MS.GetPlayer and MS.GetPlayer() or
            (System and System.GetEntity and System.GetEntity(g_localActorId))
        local tnow   = nowSec()
        if not e then return end

        -- name once
        local name = PrettyName(e)
        local S = EnsurePer(e)
        local zeroRescuePending = (S.zeroRescuePending == true)

        -- 1) corpse gate
        if IsCorpseByApiOrName(e, name, cfg) and not zeroRescuePending and
                not S.immortalityProbeApplied then
            stat.filtered = stat.filtered + 1
            return
        end

        -- 2) dog gate
        if IsDogByApiOrName(e, name, cfg) then
            stat.filtered = stat.filtered + 1
            return
        end

        -- 3) animal gate
        if IsAnimal(e, cfg) then
            stat.filtered = stat.filtered + 1
            return
        end

        -- 4) hostile gate
        if not IsHostile(e, cfg, name) then
            stat.filtered = stat.filtered + 1
            return
        end

        -- 5) per-entity scratch & KO maintenance
        if S.koApplied then
            MaintainKOIfNeeded(e, S, cfg)
            return
        end

        -- 6) ALWAYS read + track HP BEFORE cooldown gating
        local okHP, hp, isDead = ReadHpNormalized(e)
        if isDead and not zeroRescuePending and
                not S.immortalityProbeApplied then
            if S.koApplied and MS and MS.ClampHealthMin then MS.ClampHealthMin(e) end
            return
        end
        if not okHP then
            if cfg.logging and cfg.logging.core then MS.LogCore("ERR: step=GetNormalizedHp name=" .. name) end
            return
        end
        local trackedPrev = TrackHpAndMaybeStamp(e, S, hp, cfg, player)
        local threshold = tonumber(cfg.hpThreshold) or 0.12
        if trackedPrev ~= nil and trackedPrev > threshold and hp <= threshold then
            S.pendingEdgeHpPrev = trackedPrev
            S.pendingEdgeHp = hp
        end

        local hpPrev = trackedPrev
        if S.candidatePending and S.candidateHpPrev ~= nil then
            hpPrev = S.candidateHpPrev
        end
        if S.pendingEdgeHpPrev ~= nil then
            hpPrev = S.pendingEdgeHpPrev
        end

        -- 7) cooldown throttles HEAVY work only
        if cooldownActive(e, tnow) and not zeroRescuePending then return end

        -- 8) HEAVY WORK
        seen = seen + 1
        stat.scanned = stat.scanned + 1

        -- Consume the durable edge only when heavy processing actually runs.
        S.candidatePending = nil
        S.candidateHpPrev = nil
        S.pendingEdgeHpPrev = nil
        S.pendingEdgeHp = nil
        S.zeroRescuePending = nil

        if zeroRescuePending then
            MS.LogCore(string.format(
                "[Rescue] dispatch id=%s name=%s hpPrev=%s hp=%s isDead=%s",
                tostring(e.id), name, tostring(hpPrev), tostring(hp), tostring(isDead)))
        end

        local isBoss = MS.IsBoss and MS.IsBoss(e) or false

        -- KO blocks (your existing bodies inside these helpers)
        DeathLikeKO(e, name, S, hpPrev, hp, cfg, tnow, isBoss, stat)
        EdgeKO(e, name, S, hpPrev, hp, cfg, isBoss, stat)

        -- 9) arm cooldown after heavy work
        armCooldown(e, tnow)
    end

    for i = 1, #list do
        if seen >= maxN then break end
        local rec = list[i]
        local e   = rec and rec.e
        if e then processEntity(e) end
    end

    local dbg = MS.config and MS.config.logging
    local wantZeros = dbg and (dbg.scanZeros == true)
    local anyWork = (stat.edges > 0) or (stat.rolled > 0) or (stat.applied > 0)
    if wantZeros or anyWork then
        MS.LogCore(string.format("[KO] scan ▸ scanned=%d filtered=%d edges=%d yours=%d rolled=%d applied=%d",
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
    MS._candidateSession = (MS._candidateSession or 0) + 1
    local ms      = tonumber(MS.config and MS.config.combatPollMs) or 500

    if MS.Diagnostics and MS.Diagnostics.CombatStart then
        RunDiagnostic("combatStart", MS.Diagnostics.CombatStart)
    end

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
    if MS.HitSense and MS.HitSense.LifecycleRequested then
        RunDiagnostic("hitSenseRequested", MS.HitSense.LifecycleRequested,
            "StartCombatPoller globalHS=" .. tostring(type(rawget(_G, "HS"))))
    end
    if MS_Poller and MS_Poller.StartNamed and HS and HS.Tick then
        local hsMs = tonumber(MS.config and MS.config.hitsenseTickMs) or 200
        MS_Poller.StartNamed("hitsense", hsMs, HS.Tick, true)
        if MS.HitSense and MS.HitSense.LifecycleStarted then
            RunDiagnostic("hitSenseStarted", MS.HitSense.LifecycleStarted,
                "StartCombatPoller", hsMs)
        end
    elseif MS.HitSense and MS.HitSense.LifecycleStartUnavailable then
        RunDiagnostic("hitSenseStartUnavailable", MS.HitSense.LifecycleStartUnavailable,
            "existing startup condition was false")
    end
end

local function StopCombatPoller()
    if not combatActive then return end
    combatActive = false
    if MS_Poller and MS_Poller.StopNamed then
        MS_Poller.StopNamed("combat")
        MS_Poller.StopNamed("hitsense")
    end
    local audit = {
        armed = 0,
        retained = 0,
        removed = 0,
        removeFailed = 0,
        watching = 0,
        scheduled = 0,
        pending = 0,
    }
    for _, S in pairs(MercyStrike._per or {}) do
        if S and (S.immortalityProbeApplied or S.immortalityProbeAttempted) then
            audit.armed = audit.armed + 1
            local entity = S.immortalityProbeEntity
            local cfg = MS.config or {}
            local retainAll = cfg.immortalityProbeRetainAllCandidates == true
            local retainKO = S.koApplied and
                cfg.immortalityProbeRetainAfterKO == true
            local retainNatural = S.immortalityNaturalDowned and
                cfg.immortalityProbeRetainNaturalDown == true
            local retain = retainAll or retainKO or retainNatural
            if retain then
                audit.retained = audit.retained + 1
                if S.immortalityTransitionWatching then
                    audit.watching = audit.watching + 1
                end
                if S.immortalityProbeReleaseScheduled then
                    audit.scheduled = audit.scheduled + 1
                end
                if S.immortalityProbeReleasePending then
                    audit.pending = audit.pending + 1
                end
                local age = S.immortalityProbeAppliedAt and
                    math.max(0, nowSec() -
                        S.immortalityProbeAppliedAt) or nil
                MS.LogCore(string.format(
                    "[ImmortalityProbe] retained after combat name=%s id=%s state=%s ageS=%s retainAll=%s koApplied=%s naturalDowned=%s",
                    PrettyName(entity), tostring(entity and entity.id),
                    ImmortalityProbeState(S),
                    age and string.format("%.2f", age) or "unavailable",
                    tostring(retainAll),
                    tostring(S.koApplied == true),
                    tostring(S.immortalityNaturalDowned == true)))
            else
                if RemoveImmortalityProbe(entity, S, MS.config or {},
                        PrettyName(entity), "combatEnd") then
                    audit.removed = audit.removed + 1
                else
                    audit.removeFailed = audit.removeFailed + 1
                end
            end
        end
    end
    MS.LogCore(string.format(
        "[ProbeAudit] combat end generation=%d armed=%d retained=%d removed=%d removeFailed=%d watching=%d releaseScheduled=%d releasePending=%d",
        SessionGeneration(), audit.armed, audit.retained, audit.removed,
        audit.removeFailed, audit.watching, audit.scheduled,
        audit.pending))
    if MS.HitSense and MS.HitSense.LifecycleStopped then
        RunDiagnostic("hitSenseStopped", MS.HitSense.LifecycleStopped,
            "StopCombatPoller")
    end
    if MS.Diagnostics and MS.Diagnostics.CombatEnd then
        RunDiagnostic("combatEnd", MS.Diagnostics.CombatEnd)
    end
    MS.LogCore("combat ended → poller[combat] stopped")
end

-- ------------------------
-- World detector (slow) → starts/stops combat poller
-- ------------------------
local function WorldTick()
    MonitorRetainedImmortalityProbes()
    local inCombat = MS.IsInCombat()
    if MS.config and MS.config.diagnostics and
            MS.config.diagnostics.worldTicks == true then
        MS.LogCore("world tick (inCombat=" .. tostring(inCombat) .. ")")
    end

    if inCombat then
        if not combatActive then
            StartCombatPoller()
        end
        return
    end

    -- not in combat
    if combatActive and (not inCombat) and (not MercyStrike._combatEndTimer) then
        MS.LogCore("combat maybe ended → debouncing 3s")
        local sessionGeneration = SessionGeneration()
        MercyStrike._combatEndTimer = Script.SetTimer(3000, function()
            if not SessionIsCurrent(sessionGeneration) then return end
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
    MS.LogCore("[Lifecycle] world detector start generation=" ..
        tostring(SessionGeneration()) .. " intervalMs=" .. tostring(worldMs))
    MS_Poller.StartNamed("world", worldMs, WorldTick, true)
end

function MS.Stop()
    MercyStrike._sessionGeneration = SessionGeneration() + 1
    MercyStrike.CleanupImmortalityProbes("MS.Stop")
    StopTransitionPoller("MS.Stop")
    StopMercyGuardPoller("MS.Stop")
    for _, S in pairs(MercyStrike._per or {}) do
        if S and S.mercyGuardActive then
            StopMercyGuard(S, "MS.Stop", nil, nil)
        end
    end
    if MS_Poller and MS_Poller.StopAll then
        MS_Poller.StopAll()
    elseif MS_Poller and MS_Poller.StopNamed then
        MS_Poller.StopNamed("hitsense")
        MS_Poller.StopNamed("combat")
        MS_Poller.StopNamed("transition")
        MS_Poller.StopNamed("world")
    end
    if MS.HitSense and MS.HitSense.LifecycleStopped then
        RunDiagnostic("hitSenseStopped", MS.HitSense.LifecycleStopped, "MS.Stop")
    end
    if MS.Diagnostics and MS.Diagnostics.CombatEnd then
        RunDiagnostic("combatEnd", MS.Diagnostics.CombatEnd)
    end
    -- also clear any pending end-debounce
    if MercyStrike._combatEndTimer then
        Script.KillTimer(MercyStrike._combatEndTimer)
        MercyStrike._combatEndTimer = nil
    end
end

local function CountEntries(values)
    local count = 0
    for _key, _value in pairs(values or {}) do
        count = count + 1
    end
    return count
end

function MS.ResetSession(source)
    source = tostring(source or "unknown")
    local previousGeneration = SessionGeneration()
    local clearedEntities = CountEntries(MercyStrike._per)

    -- Invalidate callbacks before touching timer ids or entity state.
    MercyStrike._sessionGeneration = previousGeneration + 1
    local generation = SessionGeneration()

    if MercyStrike._combatEndTimer then
        pcall(Script.KillTimer, MercyStrike._combatEndTimer)
        MercyStrike._combatEndTimer = nil
    end
    StopTransitionPoller("sessionReset")
    StopMercyGuardPoller("sessionReset")
    if MS_Poller and MS_Poller.StopAll then
        MS_Poller.StopAll()
    elseif MS_Poller and MS_Poller.StopNamed then
        MS_Poller.StopNamed("hitsense")
        MS_Poller.StopNamed("combat")
        MS_Poller.StopNamed("transition")
        MS_Poller.StopNamed("world")
    end

    -- Safe for duplicate events; the custom probe buff is non-persistent.
    if MercyStrike.CleanupImmortalityProbes then
        MercyStrike.CleanupImmortalityProbes(
            "sessionResetGeneration" .. tostring(generation))
    end

    combatActive = false
    rescanUntil = {}
    lastDiagnosticError = nil
    MercyStrike._per = {}
    MercyStrike._transitionTimerId = nil
    MercyStrike._mercyGuardTimerId = nil

    if MS.Diagnostics and MS.Diagnostics.ResetSession then
        RunDiagnostic("resetSession", MS.Diagnostics.ResetSession)
    end
    if MS.HitSense then
        MS.HitSense._running = false
        MS.HitSense._lifecycleRequested = false
        MS.HitSense._lifecycleStarted = false
        MS.HitSense._lifecycleTickObserved = false
    end

    MS.LogCore(string.format(
        "[Lifecycle] session reset generation=%d previous=%d source=%s clearedEntities=%d",
        generation, previousGeneration, source, clearedEntities))
    MS.Start()
    return generation
end

function MS.BindLifecycleEvents(maxTries, delayMs)
    if MS._lifecycleBound then
        MS.LogCore("[Lifecycle] listener already bound")
        return true
    end
    maxTries = tonumber(maxTries) or 50
    delayMs = tonumber(delayMs) or 100
    MS._lifecycleBindGeneration =
        (tonumber(MS._lifecycleBindGeneration) or 0) + 1
    local bindGeneration = MS._lifecycleBindGeneration
    local tries = 0

    local function attempt()
        if bindGeneration ~= MS._lifecycleBindGeneration or
                MS._lifecycleBound then
            return
        end
        tries = tries + 1
        local available = UIAction and
            type(UIAction.RegisterEventSystemListener) == "function"
        if available then
            local ok, result = pcall(
                UIAction.RegisterEventSystemListener,
                MS, "System", "OnGameplayStarted", "OnGameplayStarted")
            if ok then
                MS._lifecycleBound = true
                MS.LogCore(string.format(
                    "[Lifecycle] listener bound event=OnGameplayStarted attempt=%d result=%s",
                    tries, tostring(result)))
                return
            end
            MS.LogCore("[Lifecycle] listener bind error attempt=" ..
                tostring(tries) .. " error=" .. tostring(result))
        end
        if tries < maxTries and Script and
                type(Script.SetTimer) == "function" then
            Script.SetTimer(delayMs, attempt)
        else
            MS.LogCore(string.format(
                "[Lifecycle] listener unavailable attempts=%d apiAvailable=%s",
                tries, tostring(available)))
        end
    end

    attempt()
    return MS._lifecycleBound == true
end

function MS.Bootstrap()
    if MS._booted then return end
    MS._booted = true
    if MS.ReloadConfig then MS.ReloadConfig() end
    MS.LogCore("boot ok v" .. tostring(MS.version))
    math.randomseed(os.time() % 2147483647)
    MS.ResetSession("Bootstrap")
end

function MS:OnGameplayStarted()
    MS.LogCore("OnGameplayStarted → (re)start world detector")
    MS.ResetSession("OnGameplayStarted")
end

-- Kick off after functions exist
if MS and MS.Bootstrap then MS.Bootstrap() end
