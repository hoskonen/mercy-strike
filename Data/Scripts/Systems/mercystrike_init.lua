-- Scripts/Systems/MercyStrike/MercyStrike_Init.lua
-- Entry point for Mercy Strike. Loads core logic and arms bootstrap.

System.LogAlways("[MS] systems init: loading Scripts/MercyStrike/MS_Main.lua")

-- Load the main module
Script.ReloadScript("Scripts/MercyStrike/MS_Main.lua")

-- Grab the global table created in MS_Main.lua
local MS = rawget(_G, "MercyStrike")
System.LogAlways("[MS] systems init: MS=" .. tostring(MS) ..
    " Bootstrap=" .. tostring(MS and MS.Bootstrap))

-- Call bootstrap immediately (so we tick even without gameplay events)
if MS and type(MS.Bootstrap) == "function" then
    MS.Bootstrap()
else
    System.LogAlways("[MS] ERROR: Bootstrap missing")
end

-- Also register gameplay event listener (safety re-arm on scene load)
if UIAction and UIAction.RegisterEventSystemListener then
    UIAction.RegisterEventSystemListener(MS, "System", "OnGameplayStarted", "OnGameplayStarted")
    System.LogAlways("[MS] systems init: registered OnGameplayStarted listener")
else
    System.LogAlways("[MS] systems init: UIAction missing, no gameplay re-arm")
end
