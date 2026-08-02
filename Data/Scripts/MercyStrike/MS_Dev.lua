-- Explicit Mercy Strike development helpers (Lua 5.1).
-- These commands never run automatically.

MercyStrike = MercyStrike or {}
MercyStrike.Dev = MercyStrike.Dev or {}

local MS = MercyStrike
local Dev = MS.Dev

local TEST_WEAPONS = {
    mace = {
        id = "007907cf-aeb9-4dfa-ad3f-e0262893e423",
        name = "maceClubSpiked",
    },
    axe = {
        id = "1fc42528-2bef-4dde-bf8a-04febeef41c8",
        name = "axeWork01",
    },
}

local function log(message)
    System.LogAlways("[MercyStrike][Dev] " .. tostring(message))
end

local function inventoryCount(inventory, itemId)
    local method = inventory and inventory.GetCountOfClass
    if type(method) ~= "function" then return nil end
    local ok, value = pcall(method, inventory, itemId)
    if not ok or type(value) ~= "number" then return nil end
    return value
end

local function giveWeapon(family)
    local spec = TEST_WEAPONS[family]
    if not spec then
        log("unknown test weapon family=" .. tostring(family))
        return false
    end

    local player = MS.GetPlayer and MS.GetPlayer() or nil
    local inventory = player and player.inventory
    if not inventory then
        log("player inventory unavailable")
        return false
    end
    if type(inventory.CreateItem) ~= "function" then
        log("inventory.CreateItem unavailable")
        return false
    end

    local before = inventoryCount(inventory, spec.id)
    local ok, result = pcall(
        inventory.CreateItem, inventory, spec.id, 1.0, 1)
    local after = inventoryCount(inventory, spec.id)
    local verified = before ~= nil and after ~= nil and after > before
    local success = ok and (verified or
        (before == nil and after == nil and result ~= false))

    log(string.format(
        "give family=%s name=%s id=%s success=%s verified=%s before=%s after=%s engine=%s",
        family, spec.name, spec.id, tostring(success), tostring(verified),
        tostring(before), tostring(after), tostring(result)))
    return success
end

function Dev.ShowChance()
    if not (MS.WeaponClassifier and
            type(MS.WeaponClassifier.GetEquippedWeaponContext) ==
                "function" and
            type(MS.GetEffectiveApplyChance) == "function") then
        log("weapon classifier or chance API unavailable")
        return false
    end

    local context = MS.WeaponClassifier.GetEquippedWeaponContext()
    local chance, warfare, details = MS.GetEffectiveApplyChance(context)
    details = type(details) == "table" and details or {}
    log(string.format(
        "chance=%.1f%% base=%.1f%% warfareBonus=%.1f%% heavyBonus=%.1f%% warfare=%s weaponId=%s weaponName=%s family=%s source=%s detection=%s",
        (tonumber(chance) or 0) * 100,
        (tonumber(details.baseChance) or 0) * 100,
        (tonumber(details.warfareBonus) or 0) * 100,
        (tonumber(details.heavyWeaponBonus) or 0) * 100,
        tostring(warfare), tostring(context.itemId),
        tostring(context.databaseName), tostring(context.family),
        tostring(context.classificationSource),
        tostring(context.detectionReason)))
    return true
end

-- #ms_dev_give_mace()
function ms_dev_give_mace()
    local ok, result = pcall(giveWeapon, "mace")
    if not ok then
        log("give mace failed: " .. tostring(result))
        return false
    end
    return result
end

-- #ms_dev_give_axe()
function ms_dev_give_axe()
    local ok, result = pcall(giveWeapon, "axe")
    if not ok then
        log("give axe failed: " .. tostring(result))
        return false
    end
    return result
end

-- #ms_dev_show_chance()
function ms_dev_show_chance()
    local ok, result = pcall(Dev.ShowChance)
    if not ok then
        log("show chance failed: " .. tostring(result))
        return false
    end
    return result
end
