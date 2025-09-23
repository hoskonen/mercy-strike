-- Lua 5.1, no goto
MS_Poller = MS_Poller or {}
MS_Poller._id = nil

local function Log(msg) System.LogAlways("[MS] " .. tostring(msg)) end

-- Start a repeating poll; if runImmediately==true, call fn once right away
function MS_Poller.Start(intervalMs, fn, runImmediately)
    MS_Poller.Stop()
    if runImmediately then
        local ok, err = pcall(fn)
        if not ok then Log("poller immediate call error: " .. tostring(err)) end
    end
    local function wrapped()
        local ok, err = pcall(fn)
        if not ok then Log("poller runtime error: " .. tostring(err)) end
        MS_Poller._id = Script.SetTimer(intervalMs, wrapped)
    end
    MS_Poller._id = Script.SetTimer(intervalMs, wrapped)
    Log("poller started (" .. tostring(intervalMs) .. " ms)")
end

function MS_Poller.Stop()
    local id = MS_Poller._id
    if id then
        Script.KillTimer(id)
        MS_Poller._id = nil
        System.LogAlways("[MS] poller stopped")
    end
end

return MS_Poller
