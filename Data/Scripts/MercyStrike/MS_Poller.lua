-- MS_Poller.lua (Lua 5.1)
MS_Poller = MS_Poller or {}
local P = MS_Poller
P._ids = P._ids or {}

local function Log(s) System.LogAlways("[MercyStrike] " .. tostring(s)) end

-- simple per-channel error dedupe
local _lastErr = {}

function P.StartNamed(name, intervalMs, fn, runImmediately)
    P.StopNamed(name)

    local function wrapped()
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            if _lastErr[name] ~= err then
                _lastErr[name] = err
                Log("poller[" .. name .. "] runtime error:\n" .. tostring(err))
            end
        end
        P._ids[name] = Script.SetTimer(intervalMs, wrapped)
    end

    if runImmediately then
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            if _lastErr[name] ~= err then
                _lastErr[name] = err
                Log("poller[" .. name .. "] immediate error:\n" .. tostring(err))
            end
        end
    end

    P._ids[name] = Script.SetTimer(intervalMs, wrapped)
    Log("poller[" .. name .. "] started (" .. tostring(intervalMs) .. " ms)")
end

function P.StopNamed(name)
    local id = P._ids[name]
    if id then
        Script.KillTimer(id)
        P._ids[name] = nil
        System.LogAlways("[MercyStrike] poller[" .. name .. "] stopped")
    end
end

function P.Start(intervalMs, fn, runImmediately) P.StartNamed("__default", intervalMs, fn, runImmediately) end

function P.Stop() P.StopNamed("__default") end

return P
