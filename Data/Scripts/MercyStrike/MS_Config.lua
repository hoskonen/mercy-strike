-- Scripts/MercyStrike/MS_Config.lua  (Lua 5.1)
local DEFAULT = {
    -- Polling (ms)
    pollWorldMs            = 3500, -- slow outer poller (detect combat)
    combatPollMs           = 200,  -- fast inner poller (in combat)
    enabled                = true,

    -- Name-based filters (additional safety)
    corpseNamePatterns     = { "corpse" },      -- lowercase substrings that mean "always skip"
    dogNamePatterns        = { "tvez_vorech" }, -- extend if you meet other named dogs

    -- Scan
    scanRadiusM            = 10.0,
    maxList                = 48,
    useAIHostile           = false,

    -- scan budget
    maxPerTick             = 8,   -- scan at most N NPCs per combat tick
    rescanCooldownS        = 0.5, -- don't re-check the same NPC again for this many seconds

    -- Filters
    onlyHostile            = true,
    onlyWithSoul           = true,
    includeAnimals         = false,

    -- KO health safety
    doHealthClamp          = true, -- bump HP up a bit after KO if engine supports it
    minHpAfterKO           = 0.10, -- normalized floor (10% of max HP)
    minHpAbsolute          = 5,    -- absolute fallback floor (HP points)

    -- KO probability (scales with Warfare)
    hpThreshold            = 0.15,  -- default: 0.15
    applyBaseChance        = 0.99,  -- 5% at Warfare 0
    applyBonusAtCap        = 0.15,  -- +15% at Warfare cap → total 20% at cap
    skillCap               = 30,    -- Warfare level cap used for scaling
    skillIdWarfare         = "fencing",
    scaleWithWarfare       = false, -- default: true / set false to freeze chance to applyBaseChance

    -- Death-like KO (intercept lethal hits and KO instead)
    deathLikeKO            = true,  -- master toggle
    deathLikeDelayMs       = 120,   -- tiny visual delay to "sell" the kill
    deathLikeLethalThr     = 0.05,  -- <= 4% HP is lethal territory
    deathLikeRequireStamp  = false, -- require a recent player stamp (HitSense) to trigger
    ownershipWindowS       = 2.0,   -- "recent" window for stamps

    -- Death-like tuning
    deathLikeModeAND       = true, -- require lethalNow AND bigDrop to arm death-like
    deathLikeMinDelta      = 0.35, -- raise the "big dip" to make one-hit sleeps rarer

    -- KO maintenance strategy
    koMaintainOnlyLast     = true, -- maintain only the most recent KO every tick
    koMaintainSweepNTicks  = 10,   -- also sweep all KO'd every N combat ticks (0/false to disable)
    koMaintainNearPlayerM  = 12.0, -- always maintain KO'd if within this many meters of player

    -- KO maintenance floor
    koClampOnApplyNorm     = 0.06, -- higher buffer on the KO frame
    koFloorNorm            = 0.03, -- sustained floor during maintenance

    -- Big-dip extra roll (applies only when bigDrop=TRUE and lethalNow=FALSE)
    bigDipExtraRollEnabled = true,
    bigDipBaseChance       = 0.02, -- ~2% base
    bigDipBonusAtCap       = 0.31, -- +33% at Strength cap -> up to ~66%
    strengthCap            = 20,   -- cap for scaling
    strengthStatId         = "strength",

    -- HitSense tuning (ownership stamps)
    hitsenseTickMs         = 200,  -- poll rate for HitSense (ms)
    hitsenseDropMin        = 0.10, -- ≥10% hp drop counts as a hit
    hitsenseMaxDistance    = 9.0,  -- meters from player to target for a valid stamp

    -- hard cap (safety; optional)
    applyChanceMax         = 1.00, -- don’t exceed 50% total (tweak if you like)

    -- Edge linger: keep KO eligibility alive briefly after crossing threshold
    edgeLingerS            = 1.0,  -- seconds to keep trying after first cross
    -- Rescue-at-zero: allow KO even if HP already hit 0 (clamp first)
    deathRescueAllow       = true, -- requires deathLikeKO=true

    -- boss protection
    boss                   = {
        blockDeathLike   = true,       -- no death-like on bosses
        edgeChanceFactor = 0.25,       -- 25% of normal edge chance on bosses
        namePatterns     = { "boss" }, -- add your uniques
        --minLevel         = 15,         -- treat >= level 15 as boss-ish (tweak)
    },

    -- Buff to apply
    buffId                 = "c75aa0db-65ca-44d7-9001-e4b6d38c6875",
    buffDuration           = -1,

    logging                = { core = true, probe = true, apply = true, skip = false, hitsense = true, filter = true },
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
