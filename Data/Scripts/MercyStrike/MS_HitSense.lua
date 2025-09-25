-- Scripts/MercyStrike/MS_HitSense.lua
local MS       = MercyStrike

-- configurable-ish knobs (no new user config needed)
local TICK_MS  = 200  -- 4Hz feels responsive
local DROP_MIN = 0.03 -- consider ≥10% HP drop a hit
local RADIUS_M = 6.0  -- within ~4m of player counts

MS.HitSense    = MS.HitSense or {}
local HS       = MS.HitSense

local function now()
    return (MS.NowTime and MS.NowTime()) or os.clock()
end

function HS.Stop()
    if not HS._timer then return end
    MS_Poller.StopNamed("hitsense")
    HS._timer = nil
end

-- helper: squared distance ≤ R^2
local function withinR2(a, b, r)
    if not (a and b and a.GetWorldPos and b.GetWorldPos) then return false end
    local p, q = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
    pcall(a.GetWorldPos, a, p); pcall(b.GetWorldPos, b, q)
    local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
    return (dx * dx + dy * dy + dz * dz) <= (r * r)
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
    -- Early outs so the very first tick can't explode
    if not MS or not MS.GetPlayer then return end
    local player = MS.GetPlayer(); if not player then return end

    -- Get the same set KO uses; if not available yet, skip this tick
    local near = {}
    if MS.GetNearbyHostiles then
        near = MS.GetNearbyHostiles(player) or {}
    elseif MS.GetNearbyEntities then
        near = MS.GetNearbyEntities(player) or {}
    else
        return
    end

    for i = 1, #near do
        local e = near[i]
        local id = e and e.id
        if id then
            MS._per = MS._per or {}
            local S = MS._per[id] or {}; MS._per[id] = S

            -- HP accessor: use the correct helper name
            local okH, hp = pcall(MS.GetNormalizedHp, e)
            if okH and hp then
                local prev = S._hsPrevHp; S._hsPrevHp = hp
                if prev and prev > 0 then
                    local drop = prev - hp
                    if drop > 0 and withinR2(player, e, RADIUS_M) then
                        if drop >= DROP_MIN then
                            MS.RecordHit(id, player.id)
                            if MS.config.logging and MS.config.logging.probe then
                                MS.LogProbe(("hitSense stamp name=%s drop=%.2f dist<=%.1f")
                                    :format(tostring(e.GetName and e:GetName() or id), drop, RADIUS_M))
                            end
                        end
                    end
                end
            end
        end
    end
end
