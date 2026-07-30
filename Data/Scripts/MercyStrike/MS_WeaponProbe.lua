-- Decision-time weapon feasibility diagnostics (Lua 5.1).

MercyStrike = MercyStrike or {}
MercyStrike.WeaponProbe = MercyStrike.WeaponProbe or {}

local MS = MercyStrike
local Probe = MS.WeaponProbe

local MAX_FIELDS = 48
local MAX_DEPTH = 2
local MAX_SUMMARY_LENGTH = 1200

local function clean(value, maxLength)
    local text = tostring(value)
    text = string.gsub(text, "[\r\n\t]+", " ")
    maxLength = tonumber(maxLength) or 120
    if #text > maxLength then
        text = string.sub(text, 1, maxLength) .. "..."
    end
    return text
end

local function safeField(object, key)
    local ok, value = pcall(function()
        return object and object[key]
    end)
    if not ok then return nil, false end
    return value, true
end

local function orderedEntries(value)
    if type(value) ~= "table" then return {} end
    local entries = {}
    local ok = pcall(function()
        for key, nested in pairs(value) do
            entries[#entries + 1] = {
                key = key,
                value = nested,
            }
        end
    end)
    if not ok then return {} end
    table.sort(entries, function(a, b)
        return tostring(a.key) < tostring(b.key)
    end)
    return entries
end

local function addScalar(out, seenPaths, path, value)
    if #out >= MAX_FIELDS or seenPaths[path] then return end
    local kind = type(value)
    if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
        return
    end
    seenPaths[path] = true
    out[#out + 1] = clean(path, 80) .. "=" .. clean(value, 120)
end

local function collectScalars(value, prefix, depth, out, seenTables,
        seenPaths)
    if #out >= MAX_FIELDS or depth > MAX_DEPTH or type(value) ~= "table" then
        return
    end
    if seenTables[value] then return end
    seenTables[value] = true

    local entries = orderedEntries(value)
    for i = 1, #entries do
        if #out >= MAX_FIELDS then return end
        local key = clean(entries[i].key, 60)
        local path = prefix == "" and key or (prefix .. "." .. key)
        local nested = entries[i].value
        if type(nested) == "table" and depth < MAX_DEPTH then
            collectScalars(nested, path, depth + 1, out, seenTables,
                seenPaths)
        else
            addScalar(out, seenPaths, path, nested)
        end
    end
end

local function itemSummary(item)
    if item == nil then return "<nil>" end
    local fields = {}
    local seenPaths = {}

    -- These likely fields are checked directly in case the script table uses
    -- a metatable and does not expose them through pairs().
    local known = {
        "class", "classId", "class_id", "Class",
        "subclass", "subClass", "sub_class", "SubClass",
        "type", "Type", "kind", "category",
        "weaponClass", "weapon_class", "name", "id",
        "health", "amount",
    }
    for i = 1, #known do
        local value, readable = safeField(item, known[i])
        if readable then addScalar(fields, seenPaths, known[i], value) end
    end

    collectScalars(item, "", 0, fields, {}, seenPaths)
    if #fields == 0 then return "<noScalarFields>" end
    local summary = table.concat(fields, "|")
    if #summary > MAX_SUMMARY_LENGTH then
        summary = string.sub(summary, 1, MAX_SUMMARY_LENGTH) .. "..."
    end
    return summary
end

local function firstField(item, keys)
    for i = 1, #keys do
        local value, readable = safeField(item, keys[i])
        if readable and value ~= nil then return value, keys[i] end
    end
    return nil, nil
end

local function itemManagerCall(methodName, argument)
    local manager = rawget(_G, "ItemManager")
    local method, readable = safeField(manager, methodName)
    if not readable or type(method) ~= "function" then
        return false, false, nil
    end
    local ok, result = pcall(method, argument)
    return true, ok, ok and result or nil
end

local function readItemName(methodName, classId)
    if classId == nil then return false, false, nil end
    local available, ok, result = itemManagerCall(methodName, classId)
    if available and ok and result ~= nil and result ~= "" then
        return available, ok, result
    end
    if type(classId) ~= "string" then
        local availableText, okText, resultText =
            itemManagerCall(methodName, tostring(classId))
        if availableText and okText and resultText ~= nil and
                resultText ~= "" then
            return availableText, okText, resultText
        end
    end
    return available, ok, result
end

local function inspectHand(player, handName, constantName)
    local slot = rawget(_G, constantName)
    local human = nil
    if player then
        local value, readable = safeField(player, "human")
        if readable then human = value end
    end
    local getItemInHand, methodReadable =
        safeField(human, "GetItemInHand")
    local handAvailable = methodReadable and
        type(getItemInHand) == "function" and slot ~= nil
    local handOk, handle = false, nil
    if handAvailable then
        handOk, handle = pcall(getItemInHand, human, slot)
    end

    local getItemAvailable, getItemOk, item = false, false, nil
    if handOk and handle ~= nil then
        getItemAvailable, getItemOk, item =
            itemManagerCall("GetItem", handle)
    end

    local classId, classField = firstField(item, {
        "classId", "class", "class_id", "Class", "type", "kind",
    })
    local dbAvailable, dbOk, dbName =
        readItemName("GetItemName", classId)
    local uiAvailable, uiOk, uiName =
        readItemName("GetItemUIName", classId)
    local isHeavy, family, classificationSource = false, nil, "unavailable"
    if MS.WeaponClassifier and
            type(MS.WeaponClassifier.Classify) == "function" then
        local classifyOk, heavyResult, familyResult, sourceResult =
            pcall(MS.WeaponClassifier.Classify, classId)
        if classifyOk then
            isHeavy = heavyResult == true
            family = familyResult
            classificationSource = sourceResult
        else
            classificationSource = "error"
        end
    end

    MS.LogCore(string.format(
        "[WeaponProbe] hand=%s constant=%s slot=%s handAvailable=%s handOk=%s handle=%s getItemAvailable=%s getItemOk=%s itemType=%s classField=%s classId=%s dbNameAvailable=%s dbNameOk=%s dbName=%s uiNameAvailable=%s uiNameOk=%s uiName=%s heavy=%s family=%s classificationSource=%s fields=%s",
        handName, constantName, clean(slot), tostring(handAvailable),
        tostring(handOk), clean(handle), tostring(getItemAvailable),
        tostring(getItemOk), type(item), tostring(classField),
        clean(classId), tostring(dbAvailable), tostring(dbOk),
        clean(dbName), tostring(uiAvailable), tostring(uiOk),
        clean(uiName), tostring(isHeavy), clean(family),
        tostring(classificationSource), itemSummary(item)))
end

function Probe.LogDecisionSnapshot(target, targetName)
    local player = nil
    if MS.GetPlayer then
        local okPlayer, value = pcall(MS.GetPlayer)
        if okPlayer then player = value end
    end
    local human = nil
    if player then
        local value, readable = safeField(player, "human")
        if readable then human = value end
    end
    local targetId = nil
    if target then
        local value, readable = safeField(target, "id")
        if readable then targetId = value end
    end
    MS.LogCore(string.format(
        "[WeaponProbe] decision target=%s targetId=%s player=%s human=%s itemManager=%s",
        tostring(targetName or "<entity>"),
        tostring(targetId),
        tostring(player ~= nil),
        tostring(human ~= nil),
        tostring(rawget(_G, "ItemManager") ~= nil)))
    inspectHand(player, "right", "HS_RIGHT")
    inspectHand(player, "left", "HS_LEFT")
end

-- #ms_probe_weapon() -> one-shot equipment snapshot without requiring combat.
function ms_probe_weapon()
    local ok, err = pcall(Probe.LogDecisionSnapshot, nil, "manual")
    if not ok and MS.LogCore then
        MS.LogCore("[WeaponProbe] manual error: " .. tostring(err))
    end
end
