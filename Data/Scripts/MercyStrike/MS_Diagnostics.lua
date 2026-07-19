-- Scripts/MercyStrike/MS_Diagnostics.lua (Lua 5.1)
-- Observation only: target discovery, health readability, and hostility signals.

local MS = MercyStrike

MS.Diagnostics = MS.Diagnostics or {}
local D = MS.Diagnostics

D._entities = D._entities or {}
D._active = D._active or false
D._lastSummary = D._lastSummary or nil

local function Log(message)
    if MS and MS.LogCore then
        MS.LogCore("[Diag] " .. tostring(message))
    elseif System and System.LogAlways then
        System.LogAlways("[MercyStrike/Diag] " .. tostring(message))
    end
end

local function Bool(value)
    return value == true or value == 1
end

local function Value(value)
    if value == nil then return "nil" end
    return tostring(value)
end

local function Result(available, ok, value, unavailableReason)
    if not available then return unavailableReason or "unavailable" end
    if not ok then return "error" end
    return tostring(Bool(value))
end

local function RawResult(available, ok, value, unavailableReason)
    if not available then return unavailableReason or "unavailable" end
    if not ok then return unavailableReason or "error" end
    return Value(value)
end

local function HasAIMethod(methodName)
    local ok, fn = pcall(function()
        return AI and AI[methodName]
    end)
    return ok and type(fn) == "function"
end

local function CallAI(methodName, ...)
    local okLookup, fn = pcall(function()
        return AI and AI[methodName]
    end)
    if not okLookup or type(fn) ~= "function" then
        return false, false, nil, "apiUnavailable"
    end
    local ok, value = pcall(fn, ...)
    if not ok then return true, false, nil, "callError" end
    return true, true, value, nil
end

local function CallAIForEntity(methodName, entity)
    if not (entity and entity.id) then
        local available = HasAIMethod(methodName)
        return available, false, nil, "missingEntityId"
    end
    return CallAI(methodName, entity.id)
end

local function CallAIForPair(methodName, first, second)
    if not (first and first.id and second and second.id) then
        local available = HasAIMethod(methodName)
        return available, false, nil, "missingEntityId"
    end
    return CallAI(methodName, first.id, second.id)
end

local function EntityId(value)
    if value == nil then return nil end
    local ok, id = pcall(function() return value.id end)
    if ok and id ~= nil then return id end
    return nil
end

local function SameEntity(value, entity)
    if not (value and entity) then return false end
    if value == entity then return true end
    if entity.id ~= nil and value == entity.id then return true end
    local valueId = EntityId(value)
    return valueId ~= nil and entity.id ~= nil and valueId == entity.id
end

local function FactionResult(available, ok, value)
    if not available then return "unavailable" end
    if not ok then return "error" end
    return Value(value)
end

local function Component(v, name, index)
    if not v then return nil end
    local value = v[name]
    if value == nil then value = v[index] end
    return tonumber(value)
end

local function Distance(player, entity)
    if not (player and entity and type(player.GetWorldPos) == "function" and
            type(entity.GetWorldPos) == "function") then
        return nil
    end
    local okP, p = pcall(player.GetWorldPos, player)
    local okE, e = pcall(entity.GetWorldPos, entity)
    if not (okP and okE and p and e) then return nil end
    local px, py, pz = Component(p, "x", 1), Component(p, "y", 2), Component(p, "z", 3)
    local ex, ey, ez = Component(e, "x", 1), Component(e, "y", 2), Component(e, "z", 3)
    if not (px and py and pz and ex and ey and ez) then return nil end
    local dx, dy, dz = px - ex, py - ey, pz - ez
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function ReadNormalizedHp(entity)
    local soul = entity and entity.soul
    if soul and type(soul.GetHealth) == "function" then
        local okH, health = pcall(soul.GetHealth, soul)
        local okM, maximum = false, nil
        if type(soul.GetHealthMax) == "function" then
            okM, maximum = pcall(soul.GetHealthMax, soul)
        end
        health, maximum = tonumber(health), tonumber(maximum)
        if okH and health then
            if okM and maximum and maximum > 0 then
                return math.max(0, math.min(1, health / maximum))
            end
            if health >= 0 and health <= 1 then return health end
        end
    end

    local actor = entity and entity.actor
    if actor and type(actor.GetHealth) == "function" then
        local okH, health = pcall(actor.GetHealth, actor)
        health = tonumber(health)
        if okH and health then
            if health >= 0 and health <= 1 then return health end
            if type(actor.GetMaxHealth) == "function" then
                local okM, maximum = pcall(actor.GetMaxHealth, actor)
                maximum = tonumber(maximum)
                if okM and maximum and maximum > 0 then
                    return math.max(0, math.min(1, health / maximum))
                end
            end
        end
    end

    local health01 = entity and tonumber(entity.health01)
    if health01 then return math.max(0, math.min(1, health01)) end
    return nil
end

local function ReadFaction(entity)
    local available = entity and type(entity.GetFaction) == "function"
    if not available then return false, false, nil end
    local ok, value = pcall(entity.GetFaction, entity)
    return true, ok, ok and value or nil
end

local function IsHumanCandidate(entity)
    if not (entity and entity.soul) then return false end
    if MS.IsDog then
        local ok, value = pcall(MS.IsDog, entity)
        if ok and value == true then return false end
    end
    if MS.IsAnimalByName then
        local ok, value = pcall(MS.IsAnimalByName, entity)
        if ok and value == true then return false end
    end
    return true
end

local function Inspect(entity, player, cfg)
    local record = {}
    record.id = entity and entity.id or nil
    record.name = "<entity>"
    if MS.PrettyName then
        local ok, value = pcall(MS.PrettyName, entity)
        if ok and value then record.name = tostring(value) end
    end
    record.distance = Distance(player, entity)
    record.hp = ReadNormalizedHp(entity)

    local efAvailable, efOk, entityFaction = ReadFaction(entity)
    local pfAvailable, pfOk, playerFaction = ReadFaction(player)
    record.entityFactionAvailable = efAvailable
    record.entityFactionOk = efOk
    record.entityFaction = entityFaction
    record.playerFactionAvailable = pfAvailable
    record.playerFactionOk = pfOk
    record.playerFaction = playerFaction
    if efOk and pfOk and entityFaction ~= nil and playerFaction ~= nil then
        record.factionComparison = (entityFaction == playerFaction) and "equal" or "different"
    else
        record.factionComparison = "unavailable"
    end

    record.aiHostileAvailable = false
    record.aiHostileOk = false
    record.aiHostile = nil
    record.aiHostileReason = "probeUnavailable"
    if MS.GetAIHostility then
        record.aiHostileAvailable, record.aiHostileOk, record.aiHostile,
            record.aiHostileReason = MS.GetAIHostility(entity, player)
    end

    record.aiEntityFactionAvailable = false
    record.aiEntityFactionOk = false
    record.aiEntityFaction = nil
    record.aiPlayerFactionAvailable = false
    record.aiPlayerFactionOk = false
    record.aiPlayerFaction = nil
    if MS.GetAIFaction then
        record.aiEntityFactionAvailable, record.aiEntityFactionOk,
            record.aiEntityFaction = MS.GetAIFaction(entity)
        record.aiPlayerFactionAvailable, record.aiPlayerFactionOk,
            record.aiPlayerFaction = MS.GetAIFaction(player)
    end
    if record.aiEntityFactionOk and record.aiPlayerFactionOk and
            record.aiEntityFaction ~= nil and record.aiPlayerFaction ~= nil then
        record.aiFactionComparison = (record.aiEntityFaction == record.aiPlayerFaction) and
            "equal" or "different"
    else
        record.aiFactionComparison = "unavailable"
    end

    record.aiHostileReverseAvailable = false
    record.aiHostileReverseOk = false
    record.aiHostileReverse = nil
    record.aiHostileReverseReason = "probeUnavailable"
    if MS.GetAIHostility then
        record.aiHostileReverseAvailable, record.aiHostileReverseOk,
            record.aiHostileReverse, record.aiHostileReverseReason =
            MS.GetAIHostility(player, entity)
    end

    record.aiPersonalHostileAvailable, record.aiPersonalHostileOk,
        record.aiPersonalHostile, record.aiPersonalHostileReason =
        CallAIForPair("IsPersonallyHostile", entity, player)

    record.attentionEntityAvailable, record.attentionEntityOk,
        record.attentionEntity, record.attentionEntityReason =
        CallAIForEntity("GetAttentionTargetEntity", entity)
    record.attentionEntityId = EntityId(record.attentionEntity)
    record.attentionEntityMatchesPlayer = record.attentionEntityOk and
        SameEntity(record.attentionEntity, player) or false

    record.attentionNameAvailable, record.attentionNameOk,
        record.attentionName, record.attentionNameReason =
        CallAIForEntity("GetAttentionTargetOf", entity)
    local playerName = nil
    if MS.PrettyName then
        local ok, value = pcall(MS.PrettyName, player)
        if ok and value then playerName = tostring(value) end
    end
    record.attentionNameMatchesPlayer = record.attentionNameOk and
        playerName ~= nil and record.attentionName ~= nil and
        string.lower(tostring(record.attentionName)) == string.lower(playerName) or false

    record.attentionTypeAvailable, record.attentionTypeOk,
        record.attentionType, record.attentionTypeReason =
        CallAIForEntity("GetAttentionTargetType", entity)
    record.attentionThreatAvailable, record.attentionThreatOk,
        record.attentionThreat, record.attentionThreatReason =
        CallAIForEntity("GetAttentionTargetThreat", entity)

    local candidateState = MS._per and record.id and MS._per[record.id] or nil
    record.candidateActive = false
    if MS.IsRecentCombatCandidate then
        local ok, value = pcall(MS.IsRecentCombatCandidate, entity)
        record.candidateActive = ok and value == true or false
    end
    record.candidateDrop = candidateState and candidateState.candidateDrop or nil
    record.candidateDistance = candidateState and candidateState.candidateDistance or nil
    record.candidateRemaining = nil
    if record.candidateActive and candidateState and candidateState.candidateUntil then
        local tnow = (MS.NowTime and MS.NowTime()) or os.clock()
        record.candidateRemaining = math.max(0, candidateState.candidateUntil - tnow)
    end

    local wuid = nil
    if MS.GetEntityWuid then
        local ok, value = pcall(MS.GetEntityWuid, entity)
        if ok then wuid = value end
    end
    record.publicEnemyAvailable = RPG and type(RPG.IsPublicEnemy) == "function" or false
    record.publicEnemyOk = false
    record.publicEnemy = nil
    record.publicEnemyUnavailableReason = nil
    if record.publicEnemyAvailable then
        if wuid ~= nil then
            record.publicEnemyOk, record.publicEnemy = pcall(RPG.IsPublicEnemy, wuid)
        else
            record.publicEnemyUnavailableReason = "noWuid"
        end
    end

    record.recentDamageAvailable = entity and type(entity.WasRecentlyDamagedByPlayer) == "function" or false
    record.recentDamageOk = false
    record.recentDamage = nil
    if record.recentDamageAvailable then
        record.recentDamageOk, record.recentDamage = pcall(entity.WasRecentlyDamagedByPlayer, entity, 4.0)
    end

    local soul = entity and entity.soul
    record.combatDangerAvailable = soul and type(soul.IsInCombatDanger) == "function" or false
    record.combatDangerOk = false
    record.combatDanger = nil
    if record.combatDangerAvailable then
        record.combatDangerOk, record.combatDanger = pcall(soul.IsInCombatDanger, soul)
    end

    if not (cfg and cfg.onlyHostile) then
        record.finalHostile = true
        record.hostilityReason = "onlyHostileDisabled"
    else
        local ok, value = pcall(MS.IsHostileToPlayer, entity)
        record.finalHostile = ok and not not value or false
        if not ok then
            record.hostilityReason = "classifierError"
        elseif record.finalHostile then
            if cfg.useAIHostile and record.aiHostileOk and Bool(record.aiHostile) then
                record.hostilityReason = "aiHostile"
            elseif record.factionComparison == "different" then
                record.hostilityReason = "factionDifferent"
            elseif record.publicEnemyOk and Bool(record.publicEnemy) then
                record.hostilityReason = "publicEnemy"
            elseif record.recentDamageOk and Bool(record.recentDamage) then
                record.hostilityReason = "recentlyDamagedByPlayer"
            elseif record.combatDangerOk and Bool(record.combatDanger) then
                record.hostilityReason = "combatDanger"
            elseif record.candidateActive then
                record.hostilityReason = "recentCloseHpDrop"
            else
                record.hostilityReason = "classifierTrue"
            end
        else
            record.hostilityReason = "noneMatched"
        end
    end
    return record
end

local function FormatRecord(eventName, record)
    local hp = record.hp and string.format("%.4f", record.hp) or "unavailable"
    local distance = record.distance and string.format("%.2f", record.distance) or "unavailable"
    local publicEnemyResult = record.publicEnemyUnavailableReason or
        Result(record.publicEnemyAvailable, record.publicEnemyOk, record.publicEnemy)
    local aiHostileResult = record.aiHostileReason ~= nil and
        (record.aiHostileOk and Result(true, true, record.aiHostile) or record.aiHostileReason) or
        Result(record.aiHostileAvailable, record.aiHostileOk, record.aiHostile)
    local reverseResult = RawResult(record.aiHostileReverseAvailable,
        record.aiHostileReverseOk, record.aiHostileReverse,
        record.aiHostileReverseReason)
    local personalResult = RawResult(record.aiPersonalHostileAvailable,
        record.aiPersonalHostileOk, record.aiPersonalHostile,
        record.aiPersonalHostileReason)
    local attentionEntityResult = RawResult(record.attentionEntityAvailable,
        record.attentionEntityOk, record.attentionEntityId or record.attentionEntity,
        record.attentionEntityReason)
    local attentionNameResult = RawResult(record.attentionNameAvailable,
        record.attentionNameOk, record.attentionName, record.attentionNameReason)
    local attentionTypeResult = RawResult(record.attentionTypeAvailable,
        record.attentionTypeOk, record.attentionType, record.attentionTypeReason)
    local attentionThreatResult = RawResult(record.attentionThreatAvailable,
        record.attentionThreatOk, record.attentionThreat, record.attentionThreatReason)
    local candidateDrop = record.candidateDrop and string.format("%.4f", record.candidateDrop) or "nil"
    local candidateDistance = record.candidateDistance and
        string.format("%.2f", record.candidateDistance) or "nil"
    local candidateRemaining = record.candidateRemaining and
        string.format("%.2f", record.candidateRemaining) or "nil"
    return string.format(
        "entity event=%s id=%s name=%s distM=%s hp=%s entityFactionAvail=%s entityFaction=%s playerFactionAvail=%s playerFaction=%s factionComparison=%s aiHostileAvail=%s aiHostileResult=%s aiEntityFactionAvail=%s aiEntityFaction=%s aiPlayerFactionAvail=%s aiPlayerFaction=%s aiFactionComparison=%s aiHostileReverseAvail=%s aiHostileReverseResult=%s aiPersonalHostileAvail=%s aiPersonalHostileResult=%s attentionEntityAvail=%s attentionEntityResult=%s attentionEntityMatchesPlayer=%s attentionNameAvail=%s attentionNameResult=%s attentionNameMatchesPlayer=%s attentionTypeAvail=%s attentionTypeResult=%s attentionThreatAvail=%s attentionThreatResult=%s candidateActive=%s candidateDrop=%s candidateDistM=%s candidateRemainingS=%s publicEnemyAvail=%s publicEnemyResult=%s recentDamageAvail=%s recentDamageResult=%s combatDangerAvail=%s combatDangerResult=%s finalHostile=%s reason=%s",
        tostring(eventName), Value(record.id), tostring(record.name), distance, hp,
        tostring(record.entityFactionAvailable), FactionResult(record.entityFactionAvailable, record.entityFactionOk, record.entityFaction),
        tostring(record.playerFactionAvailable), FactionResult(record.playerFactionAvailable, record.playerFactionOk, record.playerFaction),
        tostring(record.factionComparison), tostring(record.aiHostileAvailable), aiHostileResult,
        tostring(record.aiEntityFactionAvailable), FactionResult(record.aiEntityFactionAvailable, record.aiEntityFactionOk, record.aiEntityFaction),
        tostring(record.aiPlayerFactionAvailable), FactionResult(record.aiPlayerFactionAvailable, record.aiPlayerFactionOk, record.aiPlayerFaction),
        tostring(record.aiFactionComparison),
        tostring(record.aiHostileReverseAvailable), reverseResult,
        tostring(record.aiPersonalHostileAvailable), personalResult,
        tostring(record.attentionEntityAvailable), attentionEntityResult,
        tostring(record.attentionEntityMatchesPlayer),
        tostring(record.attentionNameAvailable), attentionNameResult,
        tostring(record.attentionNameMatchesPlayer),
        tostring(record.attentionTypeAvailable), attentionTypeResult,
        tostring(record.attentionThreatAvailable), attentionThreatResult,
        tostring(record.candidateActive), candidateDrop, candidateDistance,
        candidateRemaining,
        tostring(record.publicEnemyAvailable), publicEnemyResult,
        tostring(record.recentDamageAvailable), Result(record.recentDamageAvailable, record.recentDamageOk, record.recentDamage),
        tostring(record.combatDangerAvailable), Result(record.combatDangerAvailable, record.combatDangerOk, record.combatDanger),
        tostring(record.finalHostile), tostring(record.hostilityReason))
end

local function HpSignature(hp)
    if hp == nil then return "unavailable" end
    return string.format("%.4f", hp)
end

local function CombatSignalSignature(record)
    return table.concat({
        tostring(record.aiHostileReverseAvailable),
        tostring(record.aiHostileReverseOk),
        Value(record.aiHostileReverse),
        tostring(record.aiPersonalHostileAvailable),
        tostring(record.aiPersonalHostileOk),
        Value(record.aiPersonalHostile),
        tostring(record.attentionEntityAvailable),
        tostring(record.attentionEntityOk),
        Value(record.attentionEntityId or record.attentionEntity),
        tostring(record.attentionEntityMatchesPlayer),
        tostring(record.attentionNameAvailable),
        tostring(record.attentionNameOk),
        Value(record.attentionName),
        tostring(record.attentionNameMatchesPlayer),
        tostring(record.attentionTypeAvailable),
        tostring(record.attentionTypeOk),
        Value(record.attentionType),
        tostring(record.attentionThreatAvailable),
        tostring(record.attentionThreatOk),
        Value(record.attentionThreat),
        tostring(record.candidateActive),
    }, "|")
end

function D.CombatStart()
    D._entities = {}
    D._lastSummary = nil
    D._active = true
    Log("combat start")
end

function D.Scan(list, cfg)
    if not D._active then return end
    list = type(list) == "table" and list or {}
    local player = MS.GetPlayer and MS.GetPlayer() or nil
    local seenNow = {}
    local summary = { souls = #list, humans = 0, hostile = 0, notHostile = 0, healthUnavailable = 0 }

    for i = 1, #list do
        local entity = list[i] and list[i].e
        if IsHumanCandidate(entity) then
            summary.humans = summary.humans + 1
            local record = Inspect(entity, player, cfg)
            record.combatSignalSignature = CombatSignalSignature(record)
            if record.finalHostile then summary.hostile = summary.hostile + 1
            else summary.notHostile = summary.notHostile + 1 end
            if record.hp == nil then summary.healthUnavailable = summary.healthUnavailable + 1 end

            local key = record.id ~= nil and tostring(record.id) or tostring(entity)
            seenNow[key] = true
            local previous = D._entities[key]
            if not previous or not previous.present then
                Log(FormatRecord(previous and "reappearance" or "firstAppearance", record))
            else
                local hpChanged = HpSignature(previous.hp) ~= HpSignature(record.hp)
                local hostilityChanged = previous.finalHostile ~= record.finalHostile
                if hpChanged then
                    Log(FormatRecord("hpChange", record) .. " previousHp=" .. HpSignature(previous.hp))
                end
                if hostilityChanged then
                    Log(FormatRecord("hostilityChange", record) ..
                        " previousFinalHostile=" .. tostring(previous.finalHostile) ..
                        " previousReason=" .. tostring(previous.hostilityReason))
                end
                if not hpChanged and not hostilityChanged and
                        previous.combatSignalSignature ~= record.combatSignalSignature then
                    Log(FormatRecord("combatSignalChange", record))
                end
            end
            record.present = true
            record.missingScans = 0
            D._entities[key] = record
        end
    end

    for key, previous in pairs(D._entities) do
        if previous.present and not seenNow[key] then
            previous.missingScans = (previous.missingScans or 0) + 1
            if previous.missingScans >= 2 then
                previous.present = false
                Log(string.format("entity event=disappearance id=%s name=%s lastHp=%s lastFinalHostile=%s reason=notSeenForTwoScans",
                    Value(previous.id), tostring(previous.name), HpSignature(previous.hp), tostring(previous.finalHostile)))
            end
        end
    end

    local signature = string.format("%d/%d/%d/%d/%d", summary.souls, summary.humans,
        summary.hostile, summary.notHostile, summary.healthUnavailable)
    if signature ~= D._lastSummary then
        D._lastSummary = signature
        Log(string.format("scan soulsFound=%d humansConsidered=%d hostileAccepted=%d notHostileRejected=%d healthUnavailable=%d",
            summary.souls, summary.humans, summary.hostile, summary.notHostile, summary.healthUnavailable))
    end
end

function D.CombatEnd()
    if not D._active then return end
    D._active = false
    Log("combat end lastSummary=" .. tostring(D._lastSummary or "none"))
    D._entities = {}
    D._lastSummary = nil
end

return D
