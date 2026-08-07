-- Scripts/MercyStrike/MS_Util.lua  (Lua 5.1, clean)

local MS = MercyStrike
MercyStrike._per = MercyStrike._per or {} -- per-entity state

function MS.GetPlayer()
    return System.GetEntityByName("Henry") or System.GetEntityByName("dude")
end

function MS.IsCorpse(e)
    if not e then return false end
    if e.IsCorpse and type(e.IsCorpse) == "function" then
        local ok, res = pcall(e.IsCorpse, e); if ok then return not not res end
    end
    local nm = "<entity>"; if e.GetName then pcall(function() nm = e:GetName() end) end
    local s = string.lower(tostring(nm))
    return (s:find("deadbody", 1, true) or s:find("dead_body", 1, true) or s:find("so_deadbody", 1, true)) and true or
        false
end

function MS.IsAnimalByName(e)
    local nm = "<entity>"; if e and e.GetName then pcall(function() nm = e:GetName() end) end
    local s = string.lower(tostring(nm or ""))
    return (s:find("spawnedanimal_", 1, true) or s:find("dog", 1, true) or s:find("boar", 1, true) or s:find("deer", 1, true) or s:find("hare", 1, true) or s:find("rabbit", 1, true) or s:find("wolf", 1, true)) and
        true or false
end

-- Strong 0..1 health (soul/actor/max fallbacks). Single definition.
function MS.GetNormalizedHp(e)
    if not e then return 1.0 end
    local s = e.soul
    if s and s.GetHealth then
        local okH, H = pcall(s.GetHealth, s)
        local okM, M = pcall(s.GetHealthMax, s)
        if okH and okM and M and M > 0 then return math.max(0, math.min(1, H / M)) end
        if okH and H and H >= 0 and H <= 1 then return H end
        if e.actor and e.actor.GetMaxHealth then
            local okMm, Mm = pcall(e.actor.GetMaxHealth, e.actor)
            if okH and okMm and Mm and Mm > 0 then return math.max(0, math.min(1, H / Mm)) end
        end
    end
    local a = e.actor
    if a and a.GetHealth then
        local okH, H = pcall(a.GetHealth, a)
        if okH and H then
            if H >= 0 and H <= 1 then return H end
            if a.GetMaxHealth then
                local okM, M = pcall(a.GetMaxHealth, a); if okM and M and M > 0 then
                    return math.max(0,
                        math.min(1, H / M))
                end
            end
        end
    end
    if e.health01 then return math.max(0, math.min(1, e.health01)) end
    return 1.0
end

function MS.IsInCombat()
    local p = MS.GetPlayer(); if not p then return false end
    local s = p.soul
    if s and type(s.IsInCombatDanger) == "function" then
        local ok, v = pcall(s.IsInCombatDanger, s)
        return ok and (v == 1 or v == true) or false
    end
    return false
end

function MS.PrettyName(e)
    if not e then return "<nil>" end
    local nm = "<entity>"
    if e.GetName then
        local ok, n = pcall(e.GetName, e)
        if ok and n then nm = n end
    end
    return tostring(nm or "<entity>")
end

-- Add this new scan that only returns entities with a soul (actors/NPCs)
function MS.ScanSoulsInSphere(radiusM, maxList)
    local p = MS.GetPlayer(); if not (p and p.GetWorldPos) then return {} end
    local pos = p:GetWorldPos()
    local iter = (System.GetEntitiesInSphere and System.GetEntitiesInSphere(pos, radiusM or 8.0)) or System.GetEntities()
    if not iter then return {} end
    local r2 = (radiusM or 8.0) ^ 2
    local out = {}
    for i = 1, #iter do
        local e = iter[i]
        if e and e ~= p and e.soul then
            local okPos, w = pcall(function() return e:GetWorldPos() end)
            if okPos and w then
                local dx, dy, dz = pos.x - w.x, pos.y - w.y, pos.z - w.z
                if System.GetEntitiesInSphere or (dx * dx + dy * dy + dz * dz <= r2) then
                    out[#out + 1] = { e = e } -- keep the record minimal
                end
            end
        end
    end
    if maxList and #out > maxList then
        local trimmed = {}; for i = 1, maxList do trimmed[i] = out[i] end; return trimmed
    end
    return out
end

local MS = MercyStrike

-- Best-effort: try multiple APIs to read Warfare, clamp to [0..cap]
function MS.GetWarfareLevel()
    local p = MS.GetPlayer and MS.GetPlayer()
    local s = p and p.soul
    local id = (MS.config and MS.config.skillIdWarfare) or "fencing"
    if s and s.GetSkillLevel then
        local ok, v = pcall(s.GetSkillLevel, s, id) -- official API
        if ok and type(v) == "number" then return math.max(0, v) end
    end
    return 0
end

-- Compute the authoritative Mercy Strike chance and its additive components.
-- weaponContext is snapshotted by the caller at the candidate decision.
function MS.GetEffectiveApplyChance(weaponContext)
    local cfg  = MS.config or {}
    local base = math.max(0, tonumber(cfg.applyBaseChance) or 0.05)
    local warfare = 0
    local warfareBonus = 0
    if cfg.scaleWithWarfare then
        local bonusAtCap = math.max(
            0, tonumber(cfg.applyBonusAtCap) or 0.15)
        local cap = tonumber(cfg.skillCap) or 30
        warfare = MS.GetWarfareLevel()
        local progression = (cap > 0) and
            math.min(1, math.max(0, warfare / cap)) or 0
        warfareBonus = progression * bonusAtCap
    end

    local heavyBonus = 0
    if type(weaponContext) == "table" and
            weaponContext.isHeavy == true then
        heavyBonus = math.max(
            0, tonumber(cfg.heavyWeaponBonus) or 0)
    end

    local rawChance = base + warfareBonus + heavyBonus
    local maxChance = tonumber(cfg.applyChanceMax) or 1.00
    local chance = math.max(0, math.min(rawChance, maxChance))
    return chance, warfare, {
        baseChance = base,
        warfareBonus = warfareBonus,
        heavyWeaponBonus = heavyBonus,
        rawChance = rawChance,
        maxChance = maxChance,
    }
end

local function logManual(message)
    if MercyStrike and MercyStrike.LogManual then
        MercyStrike.LogManual(message)
    else
        System.LogAlways("[MercyStrike][Manual] " .. tostring(message))
    end
end

-- #ms_help() -> list every Mercy Strike console helper.
function ms_help()
    local lines = {
        "Mercy Strike console commands:",
        "#ms_help() - Show this command list",
        "#ms_deps() - Show optional dependency and settings status",
        "#ms_show_cfg() - Show effective settings and logging flags",
        "#ms_reload_cfg() - Reload Lua defaults, then persisted settings",
        "#ms_debug_on() - Enable verbose and acquisition diagnostics",
        "#ms_debug_off() - Restore compact logging",
        "#ms_set_static(chance) - Use a fixed session chance from 0.0 to 1.0",
        "#ms_set_scaled() - Enable Warfare scaling for this session",
        "#ms_probe_weapon() - Print a detailed equipped-weapon snapshot",
        "#ms_dev_ko_stress_on() - Enable session-only KO stress testing",
        "#ms_dev_ko_stress_off() - Restore pre-test runtime settings",
        "#ms_dev_show_chance() - Show weapon and current chance breakdown",
        "#ms_dev_give_mace() - Add a test spiked bludgeon",
        "#ms_dev_give_axe() - Add a test work axe",
    }
    for i = 1, #lines do
        logManual(lines[i])
    end
end

-- #ms_deps() -> report integration capability without changing state.
function ms_deps()
    local settings = {
        kcdUtilsAvailable = false,
        luaDbApiAvailable = false,
        factoryAvailable = false,
        databaseOpen = false,
        settingsSource = "unavailable",
    }
    local menu = {
        globalAvailable = false,
        assetsAvailable = false,
        apiAvailable = false,
        buildListenerRegistered = false,
        valueListenerRegistered = false,
        registered = false,
    }

    local settingsMethod = MercyStrike and MercyStrike.Settings and
        MercyStrike.Settings.GetIntegrationStatus
    if type(settingsMethod) == "function" then
        local ok, result = pcall(settingsMethod)
        if ok and type(result) == "table" then
            settings = result
        else
            logManual("dependency status: settings probe failed=" ..
                tostring(result))
        end
    end

    local menuMethod = MercyStrike and MercyStrike.ModMenu and
        MercyStrike.ModMenu.GetIntegrationStatus
    if type(menuMethod) == "function" then
        local ok, result = pcall(menuMethod)
        if ok and type(result) == "table" then
            menu = result
        else
            logManual("dependency status: Mod Menu probe failed=" ..
                tostring(result))
        end
    end

    local mode = "standalone"
    if menu.apiAvailable and settings.factoryAvailable then
        mode = "fullStack"
    elseif menu.apiAvailable then
        mode = "modMenuOnly"
    elseif settings.factoryAvailable then
        mode = "luaDbOnly"
    end

    logManual("dependency status: mode=" .. mode)
    logManual(string.format(
        "ModMenu global=%s assets=%s api=%s registered=%s buildListener=%s valueListener=%s",
        tostring(menu.globalAvailable), tostring(menu.assetsAvailable),
        tostring(menu.apiAvailable), tostring(menu.registered),
        tostring(menu.buildListenerRegistered),
        tostring(menu.valueListenerRegistered)))
    logManual(string.format(
        "KCDUtils global=%s luaDbApi=%s factory=%s databaseOpen=%s settingsSource=%s",
        tostring(settings.kcdUtilsAvailable),
        tostring(settings.luaDbApiAvailable),
        tostring(settings.factoryAvailable),
        tostring(settings.databaseOpen),
        tostring(settings.settingsSource)))
end

-- #ms_reload_cfg()  → reloads DEFAULT
function ms_reload_cfg()
    if MercyStrike and MercyStrike.ReloadConfig then MercyStrike.ReloadConfig() end
    if MercyStrike and MercyStrike.Settings and
            MercyStrike.Settings.Initialize then
        MercyStrike.Settings.Initialize(MercyStrike.config)
    end
    ms_show_cfg()
end

-- #ms_show_cfg()    → prints the effective flags
function ms_show_cfg()
    local c = MercyStrike and MercyStrike.config or {}
    System.LogAlways(string.format(
        "[MercyStrike] cfg: scale=%s base=%.2f warfareBonus=%.2f heavyBonus=%.2f max=%.2f candidateDrop=%.2f candidateDistance=%.1f combatPollMs=%s transitionTimeoutS=%s koStress=%s loggingCore=%s loggingVerbose=%s loggingIntegrations=%s",
        tostring(c.scaleWithWarfare),
        tonumber(c.applyBaseChance or 0),
        tonumber(c.applyBonusAtCap or 0),
        tonumber(c.heavyWeaponBonus or 0),
        tonumber(c.applyChanceMax or 0),
        tonumber(c.candidateDropMin or 0),
        tonumber(c.candidateMaxDistanceM or 0),
        tostring(c.combatPollMs),
        tostring(c.immortalityProbeTransitionAbsoluteTimeoutS),
        tostring(MercyStrike and MercyStrike.Dev and
            MercyStrike.Dev._koStressSnapshot ~= nil),
        tostring(c.logging and c.logging.core),
        tostring(c.logging and c.logging.verbose),
        tostring(c.logging and c.logging.integrations)
    ))
end

-- #ms_debug_on() / #ms_debug_off() -> verbose development diagnostics
function ms_debug_on()
    local c = MercyStrike and MercyStrike.config or {}
    c.logging = c.logging or {}
    c.diagnostics = c.diagnostics or {}
    c.logging.verbose = true
    c.diagnostics.acquisition = true
    c.diagnostics.archetypes = true
    System.LogAlways("[MercyStrike] verbose diagnostics ON")
end

function ms_debug_off()
    local c = MercyStrike and MercyStrike.config or {}
    c.logging = c.logging or {}
    c.diagnostics = c.diagnostics or {}
    c.logging.verbose = false
    c.diagnostics.acquisition = false
    c.diagnostics.archetypes = false
    System.LogAlways("[MercyStrike] verbose diagnostics OFF")
end

function ms_set_static(p)
    local c            = MercyStrike and MercyStrike.config or {}
    c.scaleWithWarfare = false
    c.applyBaseChance  = math.max(0, math.min(1, tonumber(p) or c.applyBaseChance))
    System.LogAlways(string.format("[MercyStrike] static mode: base=%.2f", c.applyBaseChance))
end

function ms_set_scaled()
    local c = MercyStrike and MercyStrike.config or {}
    c.scaleWithWarfare = true
    System.LogAlways("[MercyStrike] scaled mode (warfare)")
end

function MercyStrike.NowTime()
    return (System and System.GetCurrTime and System.GetCurrTime()) or os.clock()
end

-- Raise entity HP to at least maxHp * floorNorm and verify the write.
-- Returns success, method/details, hpBefore, hpAfter.
function MS.ClampHealthMin(e, floorNorm)
    if not (e and e.soul) then
        return false, "entityOrSoulUnavailable", nil, nil
    end
    local s = e.soul
    local okActor, actor = pcall(function() return e.actor end)
    if not okActor then actor = nil end

    local function callNumber(object, methodName, argument)
        local okLookup, method = pcall(function()
            return object and object[methodName]
        end)
        if not okLookup or type(method) ~= "function" then return nil end
        local okCall, value
        if argument ~= nil then
            okCall, value = pcall(method, object, argument)
        else
            okCall, value = pcall(method, object)
        end
        if not okCall then return nil end
        return tonumber(value)
    end

    local function readSnapshot()
        local snapshot = {}
        snapshot.cur = callNumber(s, "GetHealth")
        if snapshot.cur ~= nil then
            snapshot.curSource = "soul.GetHealth"
        else
            snapshot.cur = callNumber(s, "GetState", "health")
            if snapshot.cur ~= nil then
                snapshot.curSource = "soul.GetState"
            else
                snapshot.cur = callNumber(actor, "GetHealth")
                if snapshot.cur ~= nil then
                    snapshot.curSource = "actor.GetHealth"
                end
            end
        end

        snapshot.max = callNumber(s, "GetHealthMax")
        if snapshot.max ~= nil and snapshot.max > 0 then
            snapshot.maxSource = "soul.GetHealthMax"
        else
            snapshot.max = callNumber(actor, "GetMaxHealth")
            if snapshot.max ~= nil and snapshot.max > 0 then
                snapshot.maxSource = "actor.GetMaxHealth"
            else
                snapshot.max = callNumber(actor, "GetHealthMax")
                if snapshot.max ~= nil and snapshot.max > 0 then
                    snapshot.maxSource = "actor.GetHealthMax"
                else
                    snapshot.max = nil
                end
            end
        end

        local okNorm, norm = pcall(MS.GetNormalizedHp, e)
        norm = tonumber(norm)
        if okNorm and norm ~= nil and norm >= 0 and norm <= 1 then
            snapshot.norm = norm
            snapshot.normSource = "MS.GetNormalizedHp"
        end

        if snapshot.cur == nil and snapshot.max and snapshot.norm then
            snapshot.cur = snapshot.norm * snapshot.max
            snapshot.curSource = "inferredFromNormalized"
        end
        if not snapshot.max and snapshot.cur ~= nil and snapshot.norm and
                snapshot.norm > 0.000001 then
            snapshot.max = snapshot.cur / snapshot.norm
            snapshot.maxSource = "inferredFromNormalized"
        end
        return snapshot
    end

    local function describe(snapshot)
        return "cur=" .. tostring(snapshot.curSource or "unavailable") ..
            ",max=" .. tostring(snapshot.maxSource or "unavailable") ..
            ",norm=" .. tostring(snapshot.normSource or "unavailable")
    end

    local before = readSnapshot()
    local maxHp = before.max
    local curHp = before.cur
    if not (tonumber(maxHp) and tonumber(curHp)) then
        return false, "healthReadUnavailable(" .. describe(before) .. ")",
            curHp, curHp
    end
    maxHp = tonumber(maxHp)
    curHp = tonumber(curHp)
    if maxHp <= 0 then
        return false, "invalidMaxHealth(" .. describe(before) .. ")",
            curHp, curHp
    end

    local n = floorNorm
    if n == nil then
        n = 0.03
    end
    if n < 0 then n = 0 elseif n > 1 then n = 1 end

    local floorAbs = n * maxHp
    if curHp >= floorAbs then
        return true, "notNeeded", curHp, curHp
    end

    local tolerance = math.max(0.001, maxHp * 0.0001)
    local normTolerance = 0.0001
    local attempts = {}

    local function trySetter(label, object, methodName, stateSetter)
        local okLookup, method = pcall(function()
            return object and object[methodName]
        end)
        if not okLookup or type(method) ~= "function" then
            attempts[#attempts + 1] = label .. ":unavailable"
            return false, nil
        end

        local okCall, result
        if stateSetter then
            okCall, result = pcall(method, object, "health", floorAbs)
        else
            okCall, result = pcall(method, object, floorAbs)
        end
        if not okCall then
            attempts[#attempts + 1] =
                label .. ":error(" .. tostring(result) .. ")"
            return false, nil
        end

        local after = readSnapshot()
        local absVerified = after.cur ~= nil and
            after.cur >= (floorAbs - tolerance)
        local normVerified = after.norm ~= nil and
            after.norm >= (n - normTolerance)
        if absVerified or normVerified then
            return true, after, label .. "[" .. describe(after) .. "]"
        end
        attempts[#attempts + 1] =
            label .. ":noEffect(cur=" .. tostring(after.cur) ..
            ",norm=" .. tostring(after.norm) .. "," .. describe(after) .. ")"
        return false, after, nil
    end

    -- KCDUtils uses soul:SetState("health", value) for player health.
    -- Probe it first for NPCs, then actor.SetHealth, then the old soul method.
    local success, after, detail = trySetter(
        "soul.SetState", s, "SetState", true)
    if success then
        return true, detail, curHp, after.cur
    end

    success, after, detail = trySetter(
        "actor.SetHealth", actor, "SetHealth", false)
    if success then
        return true, detail, curHp, after.cur
    end

    success, after, detail = trySetter(
        "soul.SetHealth", s, "SetHealth", false)
    if success then
        return true, detail, curHp, after.cur
    end

    local final = readSnapshot()
    return false, table.concat(attempts, ";") ..
        "[before:" .. describe(before) .. ";after:" .. describe(final) .. "]",
        curHp, final.cur
end

-- Boss detection: name patterns (substring, case-insensitive) and optional level gate
function MS.IsBoss(e)
    local cfg = MS.config and MS.config.boss or {}
    if not e then return false end

    -- name pattern check
    local name = (e.GetName and e:GetName()) or ""
    local pats = cfg.namePatterns or {}
    name = tostring(name):lower()
    for i = 1, #pats do
        local pat = tostring(pats[i] or ""):lower()
        if pat ~= "" and name:find(pat, 1, true) then
            return true
        end
    end

    -- optional level check
    local minLevel = tonumber(cfg.minLevel)
    if minLevel then
        local s = e.soul
        if s and s.GetLevel then
            local okL, lvl = pcall(s.GetLevel, s)
            if okL and tonumber(lvl or 0) >= minLevel then
                return true
            end
        end
    end

    return false
end

function MercyStrike.NameMatches(name, patterns)
    if type(name) ~= "string" or type(patterns) ~= "table" then return false end
    local s = string.lower(name)
    for _, pat in ipairs(patterns) do
        if type(pat) == "string" and s:find(pat, 1, true) then
            return true
        end
    end
    return false
end

function MercyStrike.IsDog(e)
    -- class-based
    local cls = e and (e.class or (e.GetClass and pcall(e.GetClass, e) and e:GetClass())) or nil
    if type(cls) == "string" then
        local c = string.lower(cls)
        if c == "dog" or c == "animal" then return true end
    end
    -- soul reports animal?
    local s = e and e.soul
    if s and s.IsAnimal then
        local ok, v = pcall(s.IsAnimal, s)
        if ok and (v == true or v == 1) then
            -- Treat engine-animals as "animals"; dogs are a subset; class check above catches dogs
            -- Some dog archetypes may still report generic "animal" class; keep them filtered
            return true
        end
    end
    -- common dog flags
    if e and e.animal == true then return true end

    return false
end
