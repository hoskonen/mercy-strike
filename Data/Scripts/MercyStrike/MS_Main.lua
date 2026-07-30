-- Scripts/MercyStrike/MS_Main.lua  (Lua 5.1)
-- World detector (1s) + combat candidate poller (200ms)

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
MercyStrike._combatEndTimer = MercyStrike._combatEndTimer or nil
MercyStrike._sessionGeneration = MercyStrike._sessionGeneration or 0

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

local function ArchetypeSummaryAndMatch(value, patterns)
    local values = {}
    local seen = {}
    local matched = false
    local scanned = 0
    local maxValues = 16
    local maxScalars = 64

    local function inspect(v, depth, allowMatch)
        if scanned >= maxScalars or depth > 3 then return end
        local kind = type(v)
        if kind == "string" or kind == "number" or kind == "boolean" then
            local text = tostring(v)
            scanned = scanned + 1
            if #values < maxValues then
                values[#values + 1] = text
            end
            if allowMatch and MS.NameMatches then
                local okMatch, hit = pcall(MS.NameMatches, text, patterns)
                if okMatch and hit then matched = true end
            end
            return
        end
        if kind ~= "table" or seen[v] then return end
        seen[v] = true
        for key, nested in pairs(v) do
            if scanned >= maxScalars then return end
            inspect(key, depth + 1, false)
            inspect(nested, depth + 1, true)
        end
    end

    local ok = pcall(inspect, value, 0, true)
    if not ok then return false, "<unreadable>" end
    local summary = table.concat(values, "|")
    if summary == "" then summary = "<empty>" end
    if #summary > 220 then summary = string.sub(summary, 1, 220) end
    return matched, summary
end

local function ReadAnimalArchetype(e, cfg)
    local soul = e and e.soul
    local available = soul and type(soul.GetArchetype) == "function" or false
    if not available then return false, false, false, "<unavailable>" end

    local ok, archetype = pcall(soul.GetArchetype, soul)
    if not ok then return true, false, false, "<callError>" end
    local patterns = (cfg and cfg.animalArchetypePatterns) or {}
    local animal, summary = ArchetypeSummaryAndMatch(archetype, patterns)
    return true, true, animal, summary
end

local function IsAnimal(e, cfg, name)
    if cfg and cfg.includeAnimals then return false end
    if not (e and e.id) then return false end

    MercyStrike._per = MercyStrike._per or {}
    MercyStrike._per[e.id] = MercyStrike._per[e.id] or {}
    local S = MercyStrike._per[e.id]
    local generation = SessionGeneration()
    if S.animalFilterGeneration == generation then
        return S.animalFilterResult == true
    end

    local archetypeAvailable, archetypeOk, archetypeAnimal, archetypeSummary =
        ReadAnimalArchetype(e, cfg)
    local directNameAnimal = false
    if MS.NameMatches then
        local patterns = (cfg and cfg.animalNamePatterns) or {}
        local okName, hit = pcall(MS.NameMatches,
            tostring(name or PrettyName(e)), patterns)
        directNameAnimal = okName and hit or false
    end
    local fallbackNameAnimal = false
    if MS.IsAnimalByName then
        local okLegacy, hit = pcall(MS.IsAnimalByName, e)
        fallbackNameAnimal = okLegacy and hit == true or false
    end

    local animal = archetypeAnimal or directNameAnimal or fallbackNameAnimal
    local source = archetypeAnimal and "archetype" or
        (directNameAnimal and "configuredName" or
        (fallbackNameAnimal and "fallbackName" or "none"))
    S.animalFilterGeneration = generation
    S.animalFilterResult = animal
    S.animalFilterSource = source

    if cfg and cfg.diagnostics and cfg.diagnostics.archetypes == true then
        MS.LogCore(string.format(
            "[FilterProbe] archetype generation=%d id=%s name=%s available=%s ok=%s animal=%s source=%s values=%s",
            generation, tostring(e.id), tostring(name or PrettyName(e)),
            tostring(archetypeAvailable), tostring(archetypeOk),
            tostring(animal), source, tostring(archetypeSummary)))
    end
    return animal
end

-- ------------------------
-- Per-entity state
-- ------------------------

local function EnsurePer(e)
    MercyStrike._per = MercyStrike._per or {}
    MercyStrike._per[e.id] = MercyStrike._per[e.id] or {}
    return MercyStrike._per[e.id]
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

local WatchNaturalFall
local EnsureTransitionPoller
local StartMercyGuard
local StopMercyGuardPoller

local function SetMercyState(entity, S, name, newState, reason)
    if not S then return end
    newState = tostring(newState or "unknown")
    local previous = tostring(S.mercyState or "none")
    if previous == newState and S.mercyStateReason == reason then return end
    S.mercyState = newState
    S.mercyStateReason = tostring(reason or "unspecified")
    S.mercyStateChangedAt = nowSec()
    MS.LogCore(string.format(
        "[MercyState] generation=%d candidateSession=%s id=%s name=%s from=%s to=%s reason=%s",
        SessionGeneration(), tostring(S.mercyDecisionSession),
        tostring(entity and entity.id), tostring(name or "<entity>"),
        previous, newState, tostring(reason or "unspecified")))
end

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
    if cfg.boss and cfg.boss.blockMercyStrike and MS.IsBoss then
        local okBoss, isBoss = pcall(MS.IsBoss, entity)
        if okBoss and isBoss then return false end
    end
    if S.immortalityProbeApplied or S.immortalityProbeAttempted then
        return S.immortalityProbeApplied == true
    end

    -- A recovered entity can become eligible again in a later encounter.
    -- Never reuse the result of an earlier unconscious application.
    S.unconsciousApplied = nil

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
        SetMercyState(entity, S, name, "armed", "immortalityApplied")
    end
    MS.LogCore(string.format(
        "[ImmortalityProbe] add generation=%d name=%s id=%s buff=%s available=true ok=%s result=%s",
        SessionGeneration(), name, tostring(entity.id), guid, tostring(ok),
        tostring(result)))
    if S.immortalityProbeApplied and
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
    if not tostring(reason or ""):find("StableRelease", 1, true) then
        SetMercyState(entity, S, name, "terminal", reason)
    end
    MS.LogCore(string.format(
        "[ImmortalityProbe] remove name=%s id=%s buff=%s reason=%s available=%s ok=%s result=%s",
        tostring(name or "<entity>"), tostring(entity and entity.id), guid,
        tostring(reason), tostring(available), tostring(callOk),
        tostring(result)))
    MS.LogCore(string.format(
        "[ProbeAudit] terminal generation=%d armedGeneration=%s name=%s id=%s state=%s mercyState=%s reason=%s ageS=%s removeAvailable=%s removeCallOk=%s",
        SessionGeneration(), tostring(S.immortalityProbeAppliedGeneration),
        tostring(name or "<entity>"), tostring(entity and entity.id),
        state, tostring(S.mercyState), tostring(reason),
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
    SetMercyState(entity, S, name, "terminal",
        "guard:" .. tostring(reason))
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
    SetMercyState(entity, S, name, "guarded", "mercyGuardStarted")
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
    end
    MS.LogCore(string.format(
        "[HealthClamp] release name=%s id=%s floor=%s callOk=%s success=%s method=%s hpAbsBefore=%s hpAbsAfter=%s",
        tostring(name), tostring(entity.id), tostring(releaseMinHp),
        tostring(clampCallOk), tostring(clampSuccess), tostring(clampMethod),
        tostring(clampBeforeAbs), tostring(clampAfterAbs)))

    local okClamped, hpClamped, deadClamped = ReadHpNormalized(entity)
    local removed = RemoveImmortalityProbe(entity, S, cfg, name,
        trigger .. "StableRelease")
    if removed then
        SetMercyState(entity, S, name, "released",
            trigger .. "StableRelease")
    else
        SetMercyState(entity, S, name, "terminal",
            trigger .. "RemovalFailed")
    end
    local okAfter, hpAfter, deadAfter = ReadHpNormalized(entity)
    local corpseAfter = IsCorpseByApiOrName(entity, name, cfg)
    local finisherAfter = ReadFinisherState(entity)
    MS.LogCore(string.format(
        "[ImmortalityProbe] stable release name=%s id=%s trigger=%s reason=%s removed=%s unconsciousPreexisting=%s unconsciousAdded=%s hpBefore=%s hpClamped=%s releaseMinHp=%s deadBefore=%s deadClamped=%s corpseBefore=%s hpAfter=%s deadAfter=%s corpseAfter=%s targetIsUnconscious=%s stateReadBeforeOk=%s stateReadClampedOk=%s stateReadAfterOk=%s",
        tostring(name), tostring(entity.id), trigger, tostring(reason),
        tostring(removed), tostring(S.unconsciousApplied == true and
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
    local delay = 0
    if trigger == "engineDown" then
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
    if S.immortalityProbeReleaseScheduled then return end
    if not (Script and type(Script.SetTimer) == "function") then
        MS.LogCore("[ImmortalityProbe] release unavailable name=" ..
            tostring(name) .. " reason=Script.SetTimer")
        return
    end

    if delay < 0 then delay = 0 end
    S.immortalityProbeReleaseScheduled = true
    SetMercyState(entity, S, name, "releaseScheduled", trigger)
    local sessionGeneration = SessionGeneration()
    MS.LogCore(string.format(
        "[ImmortalityProbe] release scheduled generation=%d name=%s id=%s trigger=%s delayMs=%d unconsciousApplied=%s",
        sessionGeneration,
        tostring(name), tostring(entity.id), trigger, delay,
        tostring(S.unconsciousApplied == true)))

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
        local unconsciousReady = S.unconsciousApplied == true
        local unconsciousAdded = false
        if not unconsciousReady and MS_Unconscious and MS_Unconscious.Apply then
            local okApply, result = pcall(MS_Unconscious.Apply, entity,
                cfg.unconsciousBuffId or "unconscious_permanent")
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
        SetMercyState(entity, S, name, "releasing", trigger)
        MS.LogCore(string.format(
            "[ImmortalityProbe] release stabilization started name=%s id=%s trigger=%s unconsciousPreexisting=%s unconsciousAdded=%s hp=%s dead=%s corpse=%s stableTargetS=%s absoluteTimeoutS=%s releaseMinHp=%s stateReadOk=%s",
            tostring(name), tostring(entity.id), trigger,
            tostring(S.unconsciousApplied == true and not unconsciousAdded),
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
                    SetMercyState(entity, S, name, "downed",
                        "engineDownObserved")
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
        if S and S.immortalityProbeApplied then
            local entity = S.immortalityProbeEntity
            local name = PrettyName(entity)
            local okHP, hp, isDead = ReadHpNormalized(entity)
            local corpse = IsCorpseByApiOrName(entity, name, MS.config or {})
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
            if S.immortalityProbeApplied and corpse and MS.config and
                    MS.config.immortalityProbeCleanupOnCorpse == true then
                RemoveImmortalityProbe(entity, S, MS.config or {}, name,
                    "retainedMonitorCorpse")
            end
        end
    end
end

local function ResetMercyDecisionForSession(S, session)
    if not S or S.mercyDecisionSession == session then return end
    local active = S.immortalityProbeApplied or
        S.immortalityProbeReleaseScheduled or
        S.immortalityProbeReleasePending or
        S.mercyGuardActive
    if active then return end
    S.mercyDecisionSession = nil
    S.mercyDecisionSelected = nil
    S.mercyDecisionChance = nil
    S.mercyDecisionRoll = nil
    S.mercyDecisionWarfare = nil
    S.mercyDecisionReason = nil
    S.mercyState = nil
    S.mercyStateReason = nil
    S.mercyStateChangedAt = nil
end

local function DecideMercyCandidate(entity, S, cfg, name, drop, distance)
    local session = MS._candidateSession or 0
    ResetMercyDecisionForSession(S, session)
    if S.mercyDecisionSession == session then
        return S.mercyDecisionSelected == true, false
    end
    if S.immortalityProbeApplied or
            S.immortalityProbeReleaseScheduled or
            S.immortalityProbeReleasePending or
            S.mercyGuardActive then
        return S.mercyDecisionSelected == true, false
    end

    local chance, warfare = 0, 0
    if MS.GetEffectiveApplyChance then
        local okChance, value, level =
            pcall(MS.GetEffectiveApplyChance)
        if okChance then
            chance = tonumber(value) or 0
            warfare = tonumber(level) or 0
        end
    end
    if chance < 0 then chance = 0 elseif chance > 1 then chance = 1 end

    local blockedReason = nil
    if cfg.boss and cfg.boss.blockMercyStrike and MS.IsBoss then
        local okBoss, isBoss = pcall(MS.IsBoss, entity)
        if okBoss and isBoss then blockedReason = "bossBlocked" end
    end

    local roll = math.random()
    local selected = blockedReason == nil and roll < chance
    local reason = blockedReason or
        (selected and "probabilitySelected" or "probabilityRejected")
    S.mercyDecisionSession = session
    S.mercyDecisionSelected = selected
    S.mercyDecisionChance = chance
    S.mercyDecisionRoll = roll
    S.mercyDecisionWarfare = warfare
    S.mercyDecisionReason = reason
    SetMercyState(entity, S, name,
        selected and "selected" or "rejected", reason)
    MS.LogCore(string.format(
        "[MercyDecision] generation=%d candidateSession=%d id=%s name=%s selected=%s chance=%.4f roll=%.4f warfare=%s drop=%.4f distanceM=%.2f reason=%s",
        SessionGeneration(), session, tostring(entity and entity.id),
        tostring(name), tostring(selected), chance, roll,
        tostring(warfare), tonumber(drop) or 0,
        tonumber(distance) or -1, reason))
    return selected, true
end

local function ObserveCombatCandidates(list, cfg)
    if type(list) ~= "table" then return end
    local okPlayer, player = false, nil
    if MS.GetPlayer then okPlayer, player = pcall(MS.GetPlayer) end
    if not okPlayer then player = nil end
    if not player then return end
    local session = MS._candidateSession or 0
    local minDrop = tonumber(cfg.candidateDropMin) or 0.10
    local maxDistance = tonumber(cfg.candidateMaxDistanceM) or 4.0

    for i = 1, #list do
        local entity = list[i] and list[i].e
        if entity and entity.id then
            local name = PrettyName(entity)
            local corpseBefore = IsCorpseByApiOrName(entity, name, cfg)
            local excluded = IsDogByApiOrName(entity, name, cfg) or
                IsAnimal(entity, cfg, name)
            if not excluded then
                local S = EnsurePer(entity)
                if S.candidateSession ~= session then
                    S.candidateSession = session
                    ResetMercyDecisionForSession(S, session)
                    S.discoveryHpPrev = nil
                    S.acquisitionFirstLogged = nil
                end

                -- A live entity may become a corpse before the next 200 ms poll.
                -- Continue reading only if this session already observed it alive;
                -- this keeps static corpses from entering candidate logic.
                local mayBeNewlyDead = S.discoveryHpPrev ~= nil
                local okHP, hp = false, nil
                if (not corpseBefore) or mayBeNewlyDead then
                    okHP, hp = ReadHpNormalized(entity)
                end
                if okHP and hp ~= nil then
                    local hpPrev = S.discoveryHpPrev
                    S.discoveryHpPrev = hp
                    local acquisitionDiagnostics = cfg.diagnostics and
                        cfg.diagnostics.acquisition == true
                    if acquisitionDiagnostics and
                            not S.acquisitionFirstLogged then
                        local distance = DistanceMeters(player, entity)
                        MS.LogCore(string.format(
                            "[Acquisition] first generation=%d candidateSession=%d id=%s name=%s hp=%.4f distM=%s corpseBefore=%s",
                            SessionGeneration(), session,
                            tostring(entity.id), name, hp,
                            distance and string.format("%.2f", distance) or
                                "unavailable",
                            tostring(corpseBefore)))
                        S.acquisitionFirstLogged = true
                    end
                    if hpPrev ~= nil and hp < hpPrev then
                        local drop = hpPrev - hp
                        if acquisitionDiagnostics and drop < minDrop and
                                S.mercyDecisionSession ~= session then
                            local distance = DistanceMeters(player, entity)
                            MS.LogCore(string.format(
                                "[Acquisition] preselection drop generation=%d candidateSession=%d id=%s name=%s hpPrev=%.4f hp=%.4f drop=%.4f distM=%s qualifies=false minDrop=%.4f",
                                SessionGeneration(), session,
                                tostring(entity.id), name, hpPrev, hp, drop,
                                distance and string.format("%.2f", distance) or
                                    "unavailable",
                                minDrop))
                        end
                        if drop >= minDrop then
                            local distance = DistanceMeters(player, entity)
                            if distance and distance <= maxDistance and
                                    hp > 0 and not corpseBefore and
                                    S.mercyDecisionSession ~= session then
                                MS.LogCore(string.format(
                                    "[Candidate] observed id=%s name=%s hpPrev=%.4f hp=%.4f drop=%.4f distM=%.2f",
                                    tostring(entity.id), name, hpPrev, hp,
                                    drop, distance))

                                local selected, isNew =
                                    DecideMercyCandidate(entity, S, cfg,
                                        name, drop, distance)
                                if selected and isNew then
                                    local armed = ApplyImmortalityProbe(
                                        entity, S, cfg, name)
                                    if not armed then
                                        SetMercyState(entity, S, name,
                                            "terminal",
                                            "immortalityApplyFailed")
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

-- ------------------------
-- Combat candidate polling
-- ------------------------

local function CombatTick()
    if not combatActive then return end

    local cfg = MS.config or {}
    local listOk, list = pcall(MS.ScanSoulsInSphere,
        cfg.scanRadiusM or 10.0, cfg.maxList or 48)
    if listOk and type(list) == "table" then
        ObserveCombatCandidates(list, cfg)
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
    local ms = tonumber(MS.config and MS.config.combatPollMs) or 200
    local chance, warfare = MS.GetEffectiveApplyChance()
    MS.LogCore(string.format(
        "combat detected → starting combat poller @%d ms (chance=%.1f%% warfare=%d scaling=%s)",
        ms, (tonumber(chance) or 0) * 100,
        tonumber(warfare) or 0,
        tostring(MS.config and MS.config.scaleWithWarfare == true)))

    MS_Poller.StartNamed("combat", ms, CombatTick, true)
end

local function StopCombatPoller()
    if not combatActive then return end
    combatActive = false
    if MS_Poller and MS_Poller.StopNamed then
        MS_Poller.StopNamed("combat")
    end
    local audit = {
        selected = 0,
        rejected = 0,
        armed = 0,
        retained = 0,
        watching = 0,
        scheduled = 0,
        pending = 0,
    }
    for _, S in pairs(MercyStrike._per or {}) do
        if S and S.mercyDecisionSession == (MS._candidateSession or 0) then
            if S.mercyDecisionSelected then
                audit.selected = audit.selected + 1
            else
                audit.rejected = audit.rejected + 1
            end
        end
        if S and S.immortalityProbeApplied then
            audit.armed = audit.armed + 1
            audit.retained = audit.retained + 1
            local entity = S.immortalityProbeEntity
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
                math.max(0, nowSec() - S.immortalityProbeAppliedAt) or nil
            MS.LogCore(string.format(
                "[ImmortalityProbe] retained after combat name=%s id=%s state=%s ageS=%s naturalDowned=%s",
                PrettyName(entity), tostring(entity and entity.id),
                ImmortalityProbeState(S),
                age and string.format("%.2f", age) or "unavailable",
                tostring(S.immortalityNaturalDowned == true)))
        end
    end
    MS.LogCore(string.format(
        "[ProbeAudit] combat end generation=%d candidateSession=%d selected=%d rejected=%d armed=%d retained=%d watching=%d releaseScheduled=%d releasePending=%d",
        SessionGeneration(), MS._candidateSession or 0, audit.selected,
        audit.rejected, audit.armed, audit.retained, audit.watching,
        audit.scheduled, audit.pending))
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
        MS_Poller.StopNamed("combat")
        MS_Poller.StopNamed("transition")
        MS_Poller.StopNamed("world")
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
    MercyStrike._per = {}
    MercyStrike._transitionTimerId = nil
    MercyStrike._mercyGuardTimerId = nil

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
