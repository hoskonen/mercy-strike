-- Scripts/MercyStrike/MS_Poller.lua  (Lua 5.1, multi-channel)
MS_Poller = MS_Poller or {}
local P = MS_Poller

P._ids = P._ids or {} -- name -> timerId

local function Log(msg) System.LogAlways("[MercyStrike] " .. tostring(msg)) end

-- Start a repeating poll under a channel name
function P.StartNamed(name, intervalMs, fn, runImmediately)
    P.StopNamed(name)
    if runImmediately then
        local ok, err = pcall(fn)
        if not ok then Log("poller[" .. name .. "] immediate error: " .. tostring(err)) end
    end
    local function wrapped()
        local ok, err = pcall(fn)
        if not ok then Log("poller[" .. name .. "] runtime error: " .. tostring(err)) end
        P._ids[name] = Script.SetTimer(intervalMs, wrapped)
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

-- Back-compat single-channel helpers
function P.Start(intervalMs, fn, runImmediately) P.StartNamed("__default", intervalMs, fn, runImmediately) end

function P.Stop() P.StopNamed("__default") end

return P
