-- Scripts/MercyStrike/MS_HitSense.lua
local MS       = MercyStrike

local cfg      = MS and MS.config or {}
local TICK_MS  = tonumber(cfg.hitsenseTickMs) or 200
local DROP_MIN = tonumber(cfg.hitsenseDropMin) or 0.10
local RADIUS_M = (MercyStrike and MercyStrike.config and MercyStrike.config.hitsenseMaxDistance) or 6.0


MS.HitSense = MS.HitSense or {}
local HS    = MS.HitSense

local function now()
    return (MS.NowTime and MS.NowTime()) or os.clock()
end

function HS.Stop()
    -- Stop the named poller unconditionally; keep our own running flag tidy
    if MS_Poller and MS_Poller.StopNamed then
        MS_Poller.StopNamed("hitsense")
    end
    HS._running = false
end

-- helper: squared distance ≤ R^2
local function withinR2(a, b, r)
    if not (a and b and a.GetWorldPos and b.GetWorldPos) then return false end
    local p, q = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
    pcall(a.GetWorldPos, a, p); pcall(b.GetWorldPos, b, q)
    local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
    return (dx * dx + dy * dy + dz * dz) <= (r * r)
end

local function logStamp(e, player, reason, extra)
    local cfg = MS and MS.config or {}
    if not (cfg.logging and cfg.logging.hitsense) then return end
    local name = (e and e.GetName and e:GetName()) or tostring(e and e.id)
    local p    = player
    local dist = -1
    if e and p and e.GetWorldPos and p.GetWorldPos then
        local pe, pp = { 0, 0, 0 }, { 0, 0, 0 }
        pcall(function() e:GetWorldPos(pe) end)
        pcall(function() p:GetWorldPos(pp) end)
        local dx, dy, dz = (pe[1] - pp[1]), (pe[2] - pp[2]), (pe[3] - pp[3])
        dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    local tag = reason or "stamp"
    local msg = string.format("[Stamp] %s name=%s id=%s dist=%.1f%s",
        tag, tostring(name), tostring(e and e.id), dist,
        extra and (" " .. extra) or "")
    MS.LogProbe(msg)
end


-- Record function used everywhere else
function MS.RecordHit(targetId, attackerId)
    local k = targetId
    if type(targetId) == "table" then k = targetId.id end
    if not k then return end
    MS._per = MS._per or {}
    local S = MS._per[k]; if not S then
        S = {}; MS._per[k] = S
    end
    S.lastHitBy = attackerId
    S.lastHitAt = now()
end

-- (re)arm poller
function HS.Start()
    -- no-op if already running
    if HS._running then return end
    -- Use NAMED start + direct function reference (no closures)
    if MS_Poller and MS_Poller.StartNamed then
        MS_Poller.StartNamed("hitsense", TICK_MS, HS.Tick) -- don't pass runImmediately; default is fine
        HS._running = true
        if MS.config and MS.config.logging and MS.config.logging.core then
            MS.LogCore("HitSense started @" .. tostring(TICK_MS) .. " ms")
        end
    end
end

function HS.Tick()
    local stampedThisTick = 0
    if not MS or not MS.GetPlayer then return end
    local player = MS.GetPlayer(); if not player then return end

    -- Souls-in-sphere scan (same as CombatTick)
    local scanR = (MS.config and MS.config.scanRadiusM) or 10.0
    local listOk, near = pcall(MS.ScanSoulsInSphere, scanR, 48)
    if not listOk or type(near) ~= "table" or #near == 0 then return end

    for i = 1, #near do
        local rec = near[i]; local e = rec and rec.e; local id = e and e.id
        if id then
            MS._per = MS._per or {}
            local S = MS._per[id] or {}; MS._per[id] = S
            local okH, hp = pcall(MS.GetNormalizedHp, e)
            if okH and hp then
                local prev = S._hsPrevHp; S._hsPrevHp = hp
                if prev and prev > 0 then
                    local drop = prev - hp
                    if drop >= DROP_MIN and withinR2(player, e, RADIUS_M) then
                        logStamp(e, player, "HitSense", string.format(" drop=%.2f", drop))
                        stampedThisTick = stampedThisTick + 1
                        MS.RecordHit(id, player.id)
                    end
                end
            end
        end
    end

    if MS.config and MS.config.logging and MS.config.logging.hitsense then
        MS.LogProbe(string.format("[HitSense] tick stamped=%d", stampedThisTick))
    end
end
