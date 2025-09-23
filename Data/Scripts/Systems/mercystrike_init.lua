-- Scripts/Systems/MercyStrike/MercyStrike_Init.lua

System.LogAlways("[MercyStrike] systems init: loading Scripts/MercyStrike/MS_Main.lua")

-- Log any error thrown while loading
local ok, err = pcall(function()
    Script.ReloadScript("Scripts/MercyStrike/MS_Main.lua")
end)
System.LogAlways("[MercyStrike] Reload MS_Main.lua ok=" .. tostring(ok) .. " err=" .. tostring(err))

local MS = rawget(_G, "MercyStrike")
System.LogAlways("[MercyStrike] systems init: MS=" .. tostring(MS) ..
    " Bootstrap=" .. tostring(MS and MS.Bootstrap))

if MS and type(MS.Bootstrap) == "function" then
    MS.Bootstrap()
else
    System.LogAlways("[MercyStrike] ERROR: Bootstrap missing")
end

if UIAction and UIAction.RegisterEventSystemListener then
    UIAction.RegisterEventSystemListener(MS, "System", "OnGameplayStarted", "OnGameplayStarted")
    System.LogAlways("[MercyStrike] systems init: registered OnGameplayStarted listener")
end
