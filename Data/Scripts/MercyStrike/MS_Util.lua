-- Scripts/MercyStrike/MS_Util.lua  (Lua 5.1)

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

function MS.IsHostileToPlayer(e)
    local p = MS.GetPlayer(); if not (e and p) then return false end
    for _, fn in ipairs({ "IsHostileTo", "IsHostile", "IsEnemyTo", "IsEnemy", "IsAggressiveTo" }) do
        local f = e[fn]; if type(f) == "function" then
            local ok, res = pcall(f, e, p); if ok and res then return true end
        end
    end
    local ef, pf
    if e.GetFaction then
        local ok, v = pcall(e.GetFaction, e); if ok then ef = v end
    end
    if p.GetFaction then
        local ok, v = pcall(p.GetFaction, p); if ok then pf = v end
    end
    if ef and pf and ef ~= pf then return true end
    if e.WasRecentlyDamagedByPlayer and type(e.WasRecentlyDamagedByPlayer) == "function" then
        local ok, res = pcall(e.WasRecentlyDamagedByPlayer, e, 3.0); if ok and res then return true end
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
            local inside = System.GetEntitiesInSphere or (dist2(pos, e:GetWorldPos()) <= r2)
            if inside then out[#out + 1] = { e = e, d2 = dist2(pos, e:GetWorldPos()) } end
        end
    end
    table.sort(out, function(a, b) return (a.d2 or 0) < (b.d2 or 0) end)
    if maxList and #out > maxList then
        local trimmed = {}; for i = 1, maxList do trimmed[i] = out[i] end; return trimmed
    end
    return out
end

function MS.GetNormalizedHp(e)
    local soul = e and e.soul
    if soul and type(soul.GetHealth) == "function" then
        local okH, hp = pcall(soul.GetHealth, soul)
        local okM, m = pcall(soul.GetHealthMax, soul)
        if okH and okM and m and m > 0 then return math.max(0, math.min(1, hp / m)) end
    end
    if e and e.GetHealth then
        local okH, hp = pcall(e.GetHealth, e)
        if okH then
            if hp > 0 and hp <= 1.0 then return hp end
            if e.GetMaxHealth then
                local okM, m = pcall(e.GetMaxHealth, e); if okM and m and m > 0 then
                    return math.max(0, math.min(1, hp /
                        m))
                end
            end
        end
    end
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
