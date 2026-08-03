-- MS_Poller.lua (Lua 5.1)
MS_Poller = MS_Poller or {}
local P = MS_Poller
P._ids = P._ids or {}
P._generations = P._generations or {}

local function logVerbose(message)
    if MercyStrike and MercyStrike.LogVerbose then
        MercyStrike.LogVerbose(message)
    end
end

local function logError(message)
    if MercyStrike and MercyStrike.LogError then
        MercyStrike.LogError(message)
    else
        System.LogAlways("[MercyStrike][ERROR] " .. tostring(message))
    end
end

-- simple per-channel error dedupe
local _lastErr = {}

function P.StartNamed(name, intervalMs, fn, runImmediately)
    P.StopNamed(name)
    local generation = P._generations[name] or 0

    local function wrapped()
        if generation ~= (P._generations[name] or 0) then return end
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            local step = rawget(_G, "_dbg_ms_step")
            local note = rawget(_G, "_dbg_ms_note")
            local extra = (step and (" [step " .. tostring(step) .. "]")) or ""
            if note and note ~= "" then extra = extra .. " (" .. tostring(note) .. ")" end
            if _lastErr[name] ~= (err .. extra) then
                _lastErr[name] = err .. extra
                logError("poller[" .. name .. "] runtime error:" .. extra .. "\n" .. tostring(err))
            end
        end
        if generation == (P._generations[name] or 0) then
            P._ids[name] = Script.SetTimer(intervalMs, wrapped)
        end
    end

    if runImmediately then
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            if _lastErr[name] ~= err then
                _lastErr[name] = err
                logError("poller[" .. name .. "] immediate error:\n" .. tostring(err))
            end
        end
    end

    P._ids[name] = Script.SetTimer(intervalMs, wrapped)
    logVerbose("poller[" .. name .. "] started (" .. tostring(intervalMs) .. " ms)")
end

function P.StopNamed(name)
    P._generations[name] = (P._generations[name] or 0) + 1
    local id = P._ids[name]
    if id then
        Script.KillTimer(id)
        P._ids[name] = nil
        logVerbose("poller[" .. name .. "] stopped")
    end
end

function P.StopAll()
    local names = {}
    for name, _ in pairs(P._ids) do
        names[#names + 1] = name
    end
    for i = 1, #names do
        P.StopNamed(names[i])
    end
    _lastErr = {}
end

function P.Start(intervalMs, fn, runImmediately) P.StartNamed("__default", intervalMs, fn, runImmediately) end

function P.Stop() P.StopNamed("__default") end

return P
