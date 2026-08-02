-- Scripts/MercyStrike/MS_Config.lua  (Lua 5.1)
local DEFAULT = {
    -- Polling (ms)
    pollWorldMs            = 1000, -- cheap outer poller (detect combat promptly)
    combatPollMs           = 200,  -- fast inner poller (in combat)

    -- Name-based filters (additional safety)
    corpseNamePatterns     = { "corpse", "deadbody", "dead_body", "so_deadbody", "mrtvola" },
    dogNamePatterns        = { "tvez_vorech" }, -- extend if you meet other named dogs
    animalNamePatterns     = { "spawnedanimal_", "hare", "rabbit", "boar", "deer", "wolf", "horse" },
    animalArchetypePatterns = { "hare", "rabbit", "dog", "boar", "deer", "wolf", "horse", "cow", "pig", "sheep", "goat", "chicken" },

    -- Scan
    scanRadiusM            = 10.0,
    maxList                = 48,
    includeAnimals         = false,

    -- A close, observed HP drop establishes a combat candidate.
    candidateDropMin       = 0.10, -- normalized HP lost in one poll
    candidateMaxDistanceM  = 4.0,  -- melee-range ownership heuristic

    -- Natural-down protection and bounded release.
    immortalityProbeEnabled = true,
    immortalityProbeBuffId  = "d4e80237-d7b6-498d-8e28-fdf2e31f3166",
    immortalityProbeCleanupOnCorpse = false,
    immortalityProbeTransitionPollMs = 100,
    immortalityProbeTransitionWatchTimeoutS = 20,
    immortalityProbeTransitionAbsoluteTimeoutS = 90,
    immortalityProbeSafeRecoveryHp = 0.90,
    immortalityProbeTimeoutFallbackHp = 0.15,
    immortalityProbeSafeRecoveryStableS = 5,
    immortalityProbeStateFailureLimit = 10,
    immortalityProbeTimeoutFallbackDelayMs = 750,
    immortalityProbeReleaseRetryMs = 500,
    immortalityProbeReleaseRetryLimit = 3,
    immortalityProbeCleanupWoundedConsciousOnTimeout = true,
    immortalityProbeEngineDownSettleMs = 1500,
    immortalityProbeReleaseStableS = 5,
    immortalityProbeReleaseMinHp = 0.25,
    immortalityProbeReleaseAbsoluteTimeoutS = 3,
    immortalityProbeReleaseAfterNaturalDown = true,

    -- Keep a released, nearby unconscious NPC alive without blocking finishers.
    mercyGuardEnabled = true,
    mercyGuardPollMs = 100,
    mercyGuardFloorHp = 0.10,
    mercyGuardTriggerHp = 0.08,
    mercyGuardClampCooldownMs = 1000,
    mercyGuardRadiusM = 10,
    mercyGuardOutsideGraceS = 10,
    mercyGuardStateFailureLimit = 10,
    mercyGuardHeartbeatS = 10,

    -- Engine health-reset signature used to recognize a natural down.
    naturalDownResetFromMax = 0.50,
    naturalDownResetToMin   = 0.90,
    naturalDownResetRiseMin = 0.50,

    -- Authoritative per-encounter selection probability (scales with Warfare)
    applyBaseChance        = 1.00,  -- deterministic while validating the core pipeline
    applyBonusAtCap        = 0.15,  -- +15% at Warfare cap
    skillCap               = 30,    -- Warfare level cap used for scaling
    skillIdWarfare         = "fencing",
    scaleWithWarfare       = false,
    heavyWeaponBonus       = 0.15,  -- additive chance for Class 3/5 weapons
    applyChanceMax         = 1.00,

    -- boss protection
    boss                   = {
        blockMercyStrike = true,
        namePatterns = { "boss" },
    },

    unconsciousBuffId      = "c75aa0db-65ca-44d7-9001-e4b6d38c6875",
    unconsciousClampNorm   = 0.06,

    -- Core state transitions remain logged. Probes are opt-in.
    diagnostics            = {
        acquisition = false,
        archetypes = false,
        worldTicks = false,
    },
    logging                = { core = true },
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
