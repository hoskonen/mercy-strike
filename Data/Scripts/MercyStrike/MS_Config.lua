-- Scripts/MercyStrike/MS_Config.lua  (Lua 5.1)

local DEFAULT = {
    -- Polling (ms)
    pollWorldMs     = 3500, -- slow outer poller (detect combat)
    pollCombatMs    = 500,  -- fast inner poller (in combat)
    enabled         = true,

    -- Scan
    scanRadiusM     = 10.0,
    maxList         = 48,

    -- scan budget
    maxPerTick      = 8,   -- scan at most N NPCs per combat tick
    rescanCooldownS = 3.0, -- don't re-check the same NPC again for this many seconds

    -- Filters
    onlyHostile     = true,
    onlyWithSoul    = true,
    includeAnimals  = false,

    -- KO rule
    hpThreshold     = 0.12,
    applyChance     = 0.20,

    -- Buff to apply
    buffId          = "c75aa0db-65ca-44d7-9001-e4b6d38c6875",
    buffDuration    = -1,

    logging         = { core = true, probe = true, apply = true, skip = true },
}

local function copyTbl(src)
    local dst = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            local t = {}; for kk, vv in pairs(v) do t[kk] = vv end; dst[k] = t
        else
            dst[k] = v
        end
    end
    return dst
end

function MercyStrike.ReloadConfig()
    MercyStrike.config = copyTbl(DEFAULT)
    System.LogAlways("[MercyStrike] config loaded (no overrides)")
end
