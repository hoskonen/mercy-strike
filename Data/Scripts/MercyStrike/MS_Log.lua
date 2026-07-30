-- Scripts/MercyStrike/MS_Log.lua  (Lua 5.1)

local MS = MercyStrike

function MS.LogCore(s)
    if MS.config and MS.config.logging and MS.config.logging.core then
        System.LogAlways("[MercyStrike] " .. tostring(s))
    end
end
