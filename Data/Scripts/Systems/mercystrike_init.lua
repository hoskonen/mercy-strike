-- Scripts/Systems/MercyStrike/MercyStrike_Init.lua

-- Log any error thrown while loading
local ok, err = pcall(function()
    Script.ReloadScript("Scripts/MercyStrike/MS_Main.lua")
end)

local MS = rawget(_G, "MercyStrike")
if not ok then
    System.LogAlways("[MercyStrike][ERROR] Reload MS_Main.lua failed: " ..
        tostring(err))
elseif MS and MS.LogVerbose then
    MS.LogVerbose("systems init: MS_Main.lua loaded Bootstrap=" ..
        tostring(MS.Bootstrap))
end

if MS and type(MS.Bootstrap) == "function" then
    MS.Bootstrap()
else
    if MS and MS.LogError then
        MS.LogError("Bootstrap missing")
    else
        System.LogAlways("[MercyStrike][ERROR] Bootstrap missing")
    end
end

if MS and type(MS.BindLifecycleEvents) == "function" then
    MS.BindLifecycleEvents(50, 100)
else
    if MS and MS.LogError then
        MS.LogError("lifecycle binder missing")
    else
        System.LogAlways("[MercyStrike][ERROR] lifecycle binder missing")
    end
end
