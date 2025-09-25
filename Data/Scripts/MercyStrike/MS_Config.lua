-- Scripts/MercyStrike/MS_Config.lua  (Lua 5.1)
local DEFAULT = {
    -- Polling (ms)
    pollWorldMs           = 3500, -- slow outer poller (detect combat)
    combatPollMs          = 200,  -- fast inner poller (in combat)
    enabled               = true,

    -- Scan
    scanRadiusM           = 10.0,
    maxList               = 48,
    useAIHostile          = false,

    -- scan budget
    maxPerTick            = 8,   -- scan at most N NPCs per combat tick
    rescanCooldownS       = 0.5, -- don't re-check the same NPC again for this many seconds

    -- Filters
    onlyHostile           = true,
    onlyWithSoul          = true,
    includeAnimals        = false,

    -- KO health safety
    doHealthClamp         = true, -- bump HP up a bit after KO if engine supports it
    minHpAfterKO          = 0.10, -- normalized floor (10% of max HP)
    minHpAbsolute         = 5,    -- absolute fallback floor (HP points)

    -- KO probability (scales with Warfare)
    hpThreshold           = 0.15,  -- default: 0.15
    applyBaseChance       = 0.99,  -- 5% at Warfare 0
    applyBonusAtCap       = 0.15,  -- +15% at Warfare cap → total 20% at cap
    skillCap              = 30,    -- Warfare level cap used for scaling
    skillIdWarfare        = "fencing",
    scaleWithWarfare      = false, -- default: true / set false to freeze chance to applyBaseChance

    -- Death-like KO (intercept lethal hits and KO instead)
    deathLikeKO           = true,  -- master toggle
    deathLikeDelayMs      = 120,   -- tiny visual delay to "sell" the kill
    deathLikeLethalThr    = 0.05,  -- <= 4% HP is lethal territory
    deathLikeMinDelta     = 0.30,  -- or a big HP drop this tick (prev-now >= 0.18)
    deathLikeRequireStamp = false, -- require a recent player stamp (HitSense) to trigger
    ownershipWindowS      = 2.0,   -- "recent" window for stamps

    -- hard cap (safety; optional)
    applyChanceMax        = 1.00, -- don’t exceed 50% total (tweak if you like)

    -- Buff to apply
    buffId                = "c75aa0db-65ca-44d7-9001-e4b6d38c6875",
    buffDuration          = -1,

    logging               = { core = true, probe = true, apply = true, skip = true },
}

-- shallow copy (Lua 5.1)
local function copyTbl(src)
    local dst = {}
    for k, v in pairs(src or {}) do
        if type(v) == "table" then
            local t = {}
            for kk, vv in pairs(v) do t[kk] = vv end
            dst[k] = t
        else
            dst[k] = v
        end
    end
    return dst
end

function MercyStrike.ReloadConfig()
    MercyStrike.config = copyTbl(DEFAULT)
    System.LogAlways("[MercyStrike] config loaded (single file)")
end
