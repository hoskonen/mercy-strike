-- Scripts/MercyStrike/MS_Log.lua  (Lua 5.1)

local MS = MercyStrike

function MS.LogCore(s)
    if MS.config and MS.config.logging and MS.config.logging.core then
        System.LogAlways("[MercyStrike] " .. tostring(s))
    end
end

function MS.LogProbe(s)
    if MS.config and MS.config.logging and MS.config.logging.probe then
        System.LogAlways("[MercyStrike/Probe] " .. tostring(s))
    end
end

function MS.LogApply(s)
    if MS.config and MS.config.logging and MS.config.logging.apply then
        System.LogAlways("[MercyStrike/Apply] " .. tostring(s))
    end
end

function MS.LogSkip(s)
    if MS.config and MS.config.logging and MS.config.logging.skip then
        System.LogAlways("[MercyStrike/Skip] " .. tostring(s))
    end
end
