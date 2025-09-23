-- Scripts/MercyStrike/MS_Config.lua  (Lua 5.1)

local DEFAULT = {
    enabled        = true,

    -- Polling (ms)
    pollCombatMs   = 500,
    pollIdleMs     = 2000,

    -- Scan
    scanRadiusM    = 10.0,
    maxList        = 48,

    -- Target gates
    onlyHostile    = true,
    includeAnimals = false,

    -- Trigger rule
    hpThreshold    = 0.12,
    applyChance    = 0.20,
    oncePerTarget  = true,
    cooldownSec    = 60,

    -- Buff to apply
    buffId         = "unconscious_permanent",
    buffDuration   = -1,

    logging        = { core = true, probe = false, apply = true, skip = false },
}

local function deepMerge(dst, src)
    for k, v in pairs(src or {}) do
        if type(v) == "table" and type(dst[k]) == "table" then deepMerge(dst[k], v) else dst[k] = v end
    end
    return dst
end

function MercyStrike.ReloadConfig()
    local MS = MercyStrike
    MS.config = deepMerge({}, DEFAULT)
    -- Optional external overrides:
    local ok, overrides = pcall(dofile, "Scripts/MercyStrike/MercyStrikeConfig.lua")
    if ok and type(overrides) == "table" then deepMerge(MS.config, overrides) end
    System.LogAlways("[MS] config loaded")
end
