-- Optional Mod Configuration Menu integration (Lua 5.1).

MercyStrike = MercyStrike or {}
MercyStrike.ModMenu = MercyStrike.ModMenu or {}

local MS = MercyStrike
local MM = MS.ModMenu
local MOD_ID = "mercystrike"
local MOD_NAME = "Mercy Strike"

local function log(message)
    System.LogAlways("[MercyStrike][MCM] " .. tostring(message))
end

local function toggleValue(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return number ~= 0
end

local function percentValue(value)
    local number = tonumber(value)
    if number == nil or number < 0 or number > 100 then return nil end
    return math.floor(number + 0.5)
end

local function configPercent(value)
    local chance = tonumber(value) or 0
    local percent = math.floor(chance * 100 + 0.5)
    if percent < 0 then return 0 end
    if percent > 100 then return 100 end
    return percent
end

local function uiAssetsAvailable()
    if not (System and type(System.IsFileExist) == "function") then
        return false
    end
    local ok, exists = pcall(
        System.IsFileExist,
        "Libs/UI/UIElements/MCM.xml"
    )
    return ok and (exists == true or exists == 1)
end

local function apiAvailable()
    return uiAssetsAvailable()
        and MCM
        and type(MCM.AddMod) == "function"
        and type(MCM.AddCategory) == "function"
        and type(MCM.AddToggle) == "function"
        and type(MCM.AddSlider) == "function"
        and type(MCM.RegisterBuildSettingsListener) == "function"
        and type(MCM.RegisterValueChangeListener) == "function"
end

function MM.BuildSettings()
    local cfg = MS.config or {}
    MCM.AddMod(MOD_ID, MOD_NAME)

    MCM.AddCategory(
        MOD_ID,
        "Mercy Strike Chance",
        "Control how often an eligible combat outcome becomes an unconscious knockout."
    )
    MCM.AddSlider(
        MOD_ID,
        "base_chance",
        "Base Mercy Strike Chance",
        "Chance that an eligible nearby NPC is selected for Mercy Strike. The NPC must first survive long enough for a qualifying close-range damage transition to be detected.",
        0, 100, 1, configPercent(cfg.applyBaseChance), "%"
    )

    MCM.AddCategory(
        MOD_ID,
        "Weapon Influence",
        "Let heavy melee weapons make unconscious knockouts more likely."
    )
    MCM.AddSlider(
        MOD_ID,
        "heavy_weapon_bonus",
        "Heavy Weapon Bonus",
        "Additional percentage points when the right-hand weapon is recognized as an axe or mace. Unknown and unsupported modded weapons remain neutral.",
        0, 100, 1, configPercent(cfg.heavyWeaponBonus), "%"
    )

    MCM.AddCategory(
        MOD_ID,
        "Character Progression",
        "Optionally reward Henry's Warfare skill with a higher Mercy Strike chance."
    )
    MCM.AddToggle(
        MOD_ID,
        "warfare_scaling",
        "Scale With Warfare",
        "Add a Warfare-based bonus to the base chance. The bonus grows smoothly with Henry's Warfare skill and reaches its full value at Warfare 30.",
        cfg.scaleWithWarfare and 1 or 0
    )
    MCM.AddSlider(
        MOD_ID,
        "warfare_bonus",
        "Warfare Bonus at Mastery",
        "Additional percentage points granted at Warfare 30. For example, a 5% base chance plus a 15% mastery bonus gives a 20% chance at Warfare 30.",
        0, 100, 1, configPercent(cfg.applyBonusAtCap), "%"
    )
end

function MM.OnValueChanged(settingId, value)
    if not (MS.Settings and MS.Settings.SaveAll) then
        log("settings module unavailable; change ignored")
        return
    end

    if settingId == "base_chance" then
        local percent = percentValue(value)
        if percent == nil then return end
        MS.Settings.SetBaseChance(percent, "mcm", true)
    elseif settingId == "warfare_scaling" then
        local enabled = toggleValue(value)
        if enabled == nil then return end
        MS.Settings.SetWarfareScaling(enabled, "mcm", true)
    elseif settingId == "warfare_bonus" then
        local percent = percentValue(value)
        if percent == nil then return end
        MS.Settings.SetWarfareBonus(percent, "mcm", true)
    elseif settingId == "heavy_weapon_bonus" then
        local percent = percentValue(value)
        if percent == nil then return end
        MS.Settings.SetHeavyWeaponBonus(percent, "mcm", true)
    else
        return
    end

    log(string.format("%s=%s", tostring(settingId), tostring(value)))
end

-- Stable closures prevent duplicate or stale callbacks across script reloads.
MM._buildListener = MM._buildListener or function()
    local ok, err = pcall(MM.BuildSettings)
    if not ok then log("build failed: " .. tostring(err)) end
end

MM._valueListener = MM._valueListener or function(settingId, value)
    local ok, err = pcall(MM.OnValueChanged, settingId, value)
    if not ok then log("value change failed: " .. tostring(err)) end
end

MM._buildRegistered = MM._buildRegistered or MM._registered or false
MM._valueRegistered = MM._valueRegistered or MM._registered or false

function MM.Register()
    if not apiAvailable() then
        if not MM._unavailableLogged then
            MM._unavailableLogged = true
            log("MCM unavailable; menu integration disabled")
        end
        return false
    end

    if not MM._buildRegistered then
        local ok, result = pcall(
            MCM.RegisterBuildSettingsListener,
            MM._buildListener
        )
        if not ok or result == false then
            log("build-listener registration failed: " .. tostring(result))
            return false
        end
        MM._buildRegistered = true
    end

    if not MM._valueRegistered then
        local ok, result = pcall(
            MCM.RegisterValueChangeListener,
            MOD_ID,
            MM._valueListener
        )
        if not ok or result == false then
            log("value-listener registration failed: " .. tostring(result))
            return false
        end
        MM._valueRegistered = true
    end

    MM._registered = MM._buildRegistered and MM._valueRegistered
    MM._unavailableLogged = nil
    if MM._registered and not MM._registrationLogged then
        MM._registrationLogged = true
        log("listeners registered")
    end
    return MM._registered
end
