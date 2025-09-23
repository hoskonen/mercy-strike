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
    local soul = p.soul
    if soul and type(soul.IsInCombatDanger) == "function" then
        local ok, v = pcall(soul.IsInCombatDanger, soul)
        if ok and (v == 1 or v == true) then return true end
    end
    return false
end

function MS.PrettyName(e)
    if not e then return "<nil>" end
    local nm = (e.GetName and e:GetName()) or e.class or "entity"
    return tostring(nm)
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
