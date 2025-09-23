-- Scripts/MercyStrike/MS_Util.lua  (Lua 5.1, clean)

local MS = MercyStrike

function MS.GetPlayer()
    return System.GetEntityByName("Henry") or System.GetEntityByName("dude")
end

function MS.GetEntityWuid(ent)
    if XGenAIModule and type(XGenAIModule.GetMyWUID) == "function" and ent then
        local ok, w = pcall(function() return XGenAIModule.GetMyWUID(ent) end)
        if ok and w then return w end
    end
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
    return (s:find("dog", 1, true) or s:find("boar", 1, true) or s:find("deer", 1, true) or s:find("rabbit", 1, true) or s:find("wolf", 1, true)) and
        true or false
end

-- ✅ Clean hostile check: AI.Hostile first; (optional) law status is commented for now
function MS.IsHostileToPlayer(e)
    local p = MS.GetPlayer and MS.GetPlayer()
    if not (e and p) then return false end

    local ef, pf = nil, nil
    if e.GetFaction then
        local ok, v = pcall(e.GetFaction, e); if ok then ef = v end
    end
    if p.GetFaction then
        local ok, v = pcall(p.GetFaction, p); if ok then pf = v end
    end
    if ef and pf and ef ~= pf then return true end

    local w = MS.GetEntityWuid and MS.GetEntityWuid(e)
    if w and RPG and RPG.IsPublicEnemy then
        local ok, res = pcall(RPG.IsPublicEnemy, w)
        if ok and res then return true end
    end

    if e.WasRecentlyDamagedByPlayer and type(e.WasRecentlyDamagedByPlayer) == "function" then
        local ok, res = pcall(e.WasRecentlyDamagedByPlayer, e, 4.0)
        if ok and res then return true end
    end

    local s = e.soul
    if s and s.IsInCombatDanger and type(s.IsInCombatDanger) == "function" then
        local ok, v = pcall(s.IsInCombatDanger, s)
        if ok and (v == true or v == 1) then return true end
    end

    return false
end

local function dist2(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

function MS.ScanNearbyOnce(radiusM, maxList)
    local p = MS.GetPlayer(); if not (p and p.GetWorldPos) then return {} end
    local pos = p:GetWorldPos()
    local iter = (System.GetEntitiesInSphere and System.GetEntitiesInSphere(pos, radiusM or 8.0)) or System.GetEntities()
    if not iter then return {} end
    local r2 = (radiusM or 8.0) ^ 2
    local out = {}
    for i = 1, #iter do
        local e = iter[i]
        if e and e.GetWorldPos and e ~= p then
            local wpos = e:GetWorldPos()
            local inside = System.GetEntitiesInSphere or (dist2(pos, wpos) <= r2)
            if inside then out[#out + 1] = { e = e, d2 = dist2(pos, wpos) } end
        end
    end
    table.sort(out, function(a, b) return (a.d2 or 0) < (b.d2 or 0) end)
    if maxList and #out > maxList then
        local trimmed = {}; for i = 1, maxList do trimmed[i] = out[i] end; return trimmed
    end
    return out
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

-- Compute effective KO chance with optional Warfare scaling
function MS.GetEffectiveApplyChance()
    local cfg  = MS.config or {}
    local base = tonumber(cfg.applyBaseChance) or 0.05
    if not cfg.scaleWithWarfare then
        if cfg.applyChanceMax then base = math.min(base, cfg.applyChanceMax) end
        return math.max(0, base), 0
    end

    local bonus = tonumber(cfg.applyBonusAtCap) or 0.15
    local cap   = tonumber(cfg.skillCap) or 30
    local lvl   = MS.GetWarfareLevel()
    local t     = (cap > 0) and math.min(1, math.max(0, lvl / cap)) or 0
    local ch    = base + t * bonus
    local maxC  = tonumber(cfg.applyChanceMax) or 0.99
    ch          = math.max(0, math.min(ch, maxC))
    return ch, lvl
end

function MS.ClampHealthPostKO(e)
    local cfg = MercyStrike.config or {}
    if not (cfg.doHealthClamp and e and e.soul) then return end

    local s = e.soul
    -- read current & max
    local okH, H = false, nil
    if s.GetHealth then okH, H = pcall(s.GetHealth, s) end

    local okM, M = false, nil
    if s.GetHealthMax then okM, M = pcall(s.GetHealthMax, s) end

    if not (okH and okM and type(H) == "number" and type(M) == "number" and M > 0) then return end

    local nFloor = (tonumber(cfg.minHpAfterKO) or 0) * M
    local aFloor = tonumber(cfg.minHpAbsolute) or 0
    local minH   = (nFloor > aFloor) and nFloor or aFloor
    if H >= minH then return end

    -- prefer SetHealth; fall back to SetState("health", ...)
    local setOk = false
    if s.SetHealth then
        setOk = pcall(s.SetHealth, s, minH)
    end
    if (not setOk) and s.SetState then
        setOk = pcall(s.SetState, s, "health", minH)
    end

    if setOk and cfg.logging and cfg.logging.probe then
        MercyStrike.LogProbe("hp clamp → " .. string.format("%.1f/%.1f", minH, M))
    end
end

-- #ms_reload_cfg()  → reloads DEFAULT
function ms_reload_cfg()
    if MercyStrike and MercyStrike.ReloadConfig then MercyStrike.ReloadConfig() end
    ms_show_cfg()
end

-- #ms_show_cfg()    → prints the effective flags
function ms_show_cfg()
    local c = MercyStrike and MercyStrike.config or {}
    local l = c.logging or {}
    System.LogAlways(string.format(
        "[MercyStrike] cfg: hpThr=%.2f onlyHostile=%s scale=%s base=%.2f max=%.2f pollCombatMs=%s | logs core=%s probe=%s apply=%s skip=%s",
        tonumber(c.hpThreshold or 0.12),
        tostring(c.onlyHostile),
        tostring(c.scaleWithWarfare),
        tonumber(c.applyBaseChance or 0),
        tonumber(c.applyChanceMax or 0),
        tostring(c.pollCombatMs),
        tostring(l.core), tostring(l.probe), tostring(l.apply), tostring(l.skip)
    ))
end

-- #ms_debug_on() / #ms_debug_off() → quick logging toggles
function ms_debug_on()
    local c         = MercyStrike and MercyStrike.config or {}
    c.logging       = c.logging or {}
    c.logging.probe = true
    c.logging.skip  = true
    c.logging.apply = true
    System.LogAlways("[MercyStrike] debug logs ON (probe/skip/apply)")
end

function ms_debug_off()
    local c         = MercyStrike and MercyStrike.config or {}
    c.logging       = c.logging or {}
    c.logging.probe = false
    c.logging.skip  = false
    System.LogAlways("[MercyStrike] debug logs OFF (core/apply kept)")
end

-- #ms_set_hpthr(0.85) etc. → quick in-session tuning
function ms_set_hpthr(x)
    local c = MercyStrike and MercyStrike.config or {}; c.hpThreshold = tonumber(x) or c.hpThreshold
    System.LogAlways("[MercyStrike] hpThreshold=" .. tostring(c.hpThreshold))
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
