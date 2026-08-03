-- Scripts/MercyStrike/MS_Log.lua  (Lua 5.1)

local MS = MercyStrike

local function enabled(channel, fallback)
    local logging = MS.config and MS.config.logging
    if type(logging) ~= "table" then return fallback == true end
    local value = logging[channel]
    if value == nil then return fallback == true end
    return value == true
end

local function emit(prefix, message)
    System.LogAlways(prefix .. tostring(message))
end

function MS.LogError(message)
    emit("[MercyStrike][ERROR] ", message)
end

function MS.LogVerbose(message)
    if enabled("verbose", false) then
        emit("[MercyStrike][Verbose] ", message)
    end
end

function MS.LogIntegration(message)
    if enabled("integrations", true) then
        emit("[MercyStrike][Integration] ", message)
    end
end

function MS.LogDiagnostic(message)
    if enabled("verbose", false) then
        emit("[MercyStrike][Diagnostic] ", message)
    end
end

-- Explicitly requested console diagnostics should always answer the user.
function MS.LogManual(message)
    emit("[MercyStrike][Manual] ", message)
end

local ERROR_PREFIXES = {
    "ERR:",
    "[MercyGuard] poller error",
    "[MercyGuard] poller start error",
    "[ImmortalityProbe] release unavailable",
    "[ImmortalityProbe] transition poller error",
    "[ImmortalityProbe] transition poller start error",
    "[ProbeAudit] release failed",
    "[ProbeAudit] release timer failed",
    "[ProbeAudit] natural fall watch failed",
    "[ProbeAudit] orphan recovery failed",
    "[Settings] initialize error",
    "[MCM] registration error",
    "[Lifecycle] listener bind error",
    "[Lifecycle] listener unavailable",
}

local DIAGNOSTIC_PREFIXES = {
    "[FilterProbe]",
    "[Acquisition]",
    "[WeaponProbe]",
    "world tick",
}

local INTEGRATION_PREFIXES = {
    "[Integrations]",
    "[Settings] defaults retained",
}

local VERBOSE_PREFIXES = {
    "[Candidate]",
    "[HealthClamp]",
    "[ImmortalityProbe] add",
    "[ImmortalityProbe] remove",
    "[ImmortalityProbe] stable release",
    "[ImmortalityProbe] release scheduled",
    "[ImmortalityProbe] release skipped",
    "[ImmortalityProbe] release stabilization started",
    "[ImmortalityProbe] release stabilization complete",
    "[ImmortalityProbe] release stabilization waiting",
    "[ImmortalityProbe] transition poller",
    "[ImmortalityProbe] natural fall watch started",
    "[ImmortalityProbe] retained after combat",
    "[ImmortalityProbe] protection retained",
    "[MercyGuard] heartbeat",
    "[MercyGuard] poller",
    "[ProbeAudit] terminal",
    "[ProbeAudit] release retry",
    "[ProbeAudit] combat end",
    "combat maybe ended",
    "combat persisted",
    "[Lifecycle] listener already bound",
    "[Lifecycle] listener bound",
}

local function startsWithAny(message, prefixes)
    for i = 1, #prefixes do
        local prefix = prefixes[i]
        if string.sub(message, 1, #prefix) == prefix then return true end
    end
    return false
end

local function startsWith(message, prefix)
    return string.sub(message, 1, #prefix) == prefix
end

local function hasFailedResult(message)
    if startsWith(message, "[ImmortalityProbe] add") or
            startsWith(message, "[ImmortalityProbe] remove") then
        return string.find(message, "ok=false", 1, true) ~= nil
    end
    if startsWith(message, "[HealthClamp]") then
        return string.find(message, "success=false", 1, true) ~= nil
    end
    if startsWith(message, "[ImmortalityProbe] stable release") then
        return string.find(message, "removed=false", 1, true) ~= nil
    end
    if startsWith(message, "[MercyGuard] clamp") then
        return string.find(message, "ok=false", 1, true) ~= nil
    end
    if startsWith(message, "[ProbeAudit] terminal") then
        return string.find(message, "removeCallOk=false", 1, true) ~= nil
    end
    if startsWith(message, "[ImmortalityProbe] cleanup complete") then
        local failed = string.match(message, "failed=(%d+)")
        return tonumber(failed or 0) > 0
    end
    return false
end

-- Compatibility router for established call sites. Stable message prefixes
-- keep this refactor independent from gameplay and state-machine behavior.
function MS.LogCore(message)
    local text = tostring(message)
    if startsWithAny(text, ERROR_PREFIXES) or hasFailedResult(text) then
        MS.LogError(text)
    elseif startsWithAny(text, DIAGNOSTIC_PREFIXES) then
        MS.LogDiagnostic(text)
    elseif startsWithAny(text, INTEGRATION_PREFIXES) then
        MS.LogIntegration(text)
    elseif startsWithAny(text, VERBOSE_PREFIXES) then
        MS.LogVerbose(text)
    elseif enabled("core", true) then
        emit("[MercyStrike] ", text)
    end
end
