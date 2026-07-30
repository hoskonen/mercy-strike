-- Optional persistent settings backed by KCDUtils LuaDB (Lua 5.1).

MercyStrike = MercyStrike or {}
MercyStrike.Settings = MercyStrike.Settings or {}

local MS = MercyStrike
local Settings = MS.Settings
local DB_NAMESPACE = "mercystrike"
local SETTINGS_KEY = "settings:v1"

local function log(message)
    System.LogAlways("[MercyStrike][Settings] " .. tostring(message))
end

local function normalizeBoolean(value)
    if type(value) == "boolean" then return value end
    if type(value) == "number" then
        if value == 1 then return true end
        if value == 0 then return false end
    end
    if type(value) == "string" then
        local lower = string.lower(value)
        if lower == "true" or lower == "1" then return true end
        if lower == "false" or lower == "0" then return false end
    end
    return nil
end

local function normalizePercent(value)
    local number = tonumber(value)
    if number == nil or number < 0 or number > 100 then return nil end
    return math.floor(number + 0.5)
end

local function chanceToPercent(value)
    local chance = tonumber(value)
    if chance == nil then return nil end
    return normalizePercent(chance * 100)
end

local function ensureDB()
    if Settings._db then return Settings._db end
    if not (KCDUtils and KCDUtils.DB and KCDUtils.DB.Factory) then
        if not Settings._dbUnavailableLogged then
            Settings._dbUnavailableLogged = true
            log("KCDUtils LuaDB unavailable; using MS_Config.lua")
        end
        return nil
    end

    local ok, db = pcall(KCDUtils.DB.Factory, DB_NAMESPACE)
    if ok and db then
        Settings._db = db
        Settings._dbUnavailableLogged = nil
        return db
    end

    log("failed to open LuaDB namespace")
    return nil
end

local function readRecord(db)
    if type(db.GetG) ~= "function" then
        return nil, "global read unavailable"
    end
    local ok, value = pcall(db.GetG, db, SETTINGS_KEY)
    if not ok then return nil, "read failed" end
    if value == nil then return nil, "missing" end
    if type(value) ~= "table" then return nil, "record is not a table" end

    -- Validate each field independently. Missing or invalid values retain
    -- their MS_Config.lua defaults.
    return {
        version = tonumber(value.version) or 1,
        baseChancePercent = normalizePercent(value.baseChancePercent),
        scaleWithWarfare = normalizeBoolean(value.scaleWithWarfare),
        warfareBonusPercent = normalizePercent(value.warfareBonusPercent),
    }, nil
end

local function buildRecord(config)
    return {
        version = 1,
        baseChancePercent =
            chanceToPercent(config.applyBaseChance) or 100,
        scaleWithWarfare = config.scaleWithWarfare and 1 or 0,
        warfareBonusPercent =
            chanceToPercent(config.applyBonusAtCap) or 0,
    }
end

local function recordMatchesConfig(record, config)
    return record ~= nil
        and record.baseChancePercent ==
            chanceToPercent(config.applyBaseChance)
        and record.scaleWithWarfare == config.scaleWithWarfare
        and record.warfareBonusPercent ==
            chanceToPercent(config.applyBonusAtCap)
end

local function applyRecord(config, record)
    if record.baseChancePercent ~= nil then
        config.applyBaseChance = record.baseChancePercent / 100
    end
    if record.scaleWithWarfare ~= nil then
        config.scaleWithWarfare = record.scaleWithWarfare
    end
    if record.warfareBonusPercent ~= nil then
        config.applyBonusAtCap = record.warfareBonusPercent / 100
    end
end

local function markSessionChanged()
    Settings._dirty = true
    Settings._source = "session"
end

function Settings.Initialize(config)
    if type(config) ~= "table" then return false, "config unavailable" end

    local db = ensureDB()
    if not db then
        Settings._source = Settings._dirty and "session" or "defaults"
        return false, "db unavailable"
    end

    -- MCM changes made before LuaDB becomes available take precedence over
    -- an older persisted record.
    if Settings._dirty then return Settings.SaveAll(config) end

    local record, reason = readRecord(db)
    if not record then
        Settings._loaded = true
        Settings._source = "defaults"
        if reason == "missing" then
            log("no saved value; using MS_Config.lua")
        else
            log("ignored invalid saved settings: " .. tostring(reason))
        end
        return false, reason
    end

    applyRecord(config, record)
    Settings._loaded = true
    Settings._dirty = false
    Settings._source = "luadb"
    log(string.format(
        "loaded baseChance=%d%% warfareScaling=%s warfareBonus=%d%%",
        chanceToPercent(config.applyBaseChance) or 0,
        tostring(config.scaleWithWarfare),
        chanceToPercent(config.applyBonusAtCap) or 0))
    return true, nil
end

function Settings.GetSource()
    return Settings._source or "defaults"
end

function Settings.SaveAll(config)
    if type(config) ~= "table" then return false, "config unavailable" end

    local db = ensureDB()
    if not db then
        markSessionChanged()
        return false, "db unavailable"
    end
    if type(db.SetG) ~= "function" then
        markSessionChanged()
        log("global save API unavailable")
        return false, "global write unavailable"
    end

    local writeOk = pcall(db.SetG, db, SETTINGS_KEY, buildRecord(config))
    if not writeOk then
        markSessionChanged()
        log("save failed")
        return false, "write failed"
    end

    local saved, reason = readRecord(db)
    local verified = recordMatchesConfig(saved, config)
    if verified then
        Settings._loaded = true
        Settings._dirty = false
        Settings._source = "luadb"
    else
        markSessionChanged()
    end
    log("saved all verified=" .. tostring(verified))
    return verified, verified and nil or reason or "verification failed"
end

function Settings.SetBaseChance(percent, source, persist)
    if type(MS.config) ~= "table" then return false, "config unavailable" end
    percent = normalizePercent(percent)
    if percent == nil then return false, "invalid base chance" end

    MS.config.applyBaseChance = percent / 100
    markSessionChanged()
    log(string.format("baseChance=%d%% source=%s", percent,
        tostring(source or "settings")))
    if persist then return Settings.SaveAll(MS.config) end
    return true, nil
end

function Settings.SetWarfareScaling(enabled, source, persist)
    if type(MS.config) ~= "table" then return false, "config unavailable" end
    MS.config.scaleWithWarfare = enabled == true
    markSessionChanged()
    log(string.format("warfareScaling=%s source=%s",
        tostring(MS.config.scaleWithWarfare),
        tostring(source or "settings")))
    if persist then return Settings.SaveAll(MS.config) end
    return true, nil
end

function Settings.SetWarfareBonus(percent, source, persist)
    if type(MS.config) ~= "table" then return false, "config unavailable" end
    percent = normalizePercent(percent)
    if percent == nil then return false, "invalid Warfare bonus" end

    MS.config.applyBonusAtCap = percent / 100
    markSessionChanged()
    log(string.format("warfareBonus=%d%% source=%s", percent,
        tostring(source or "settings")))
    if persist then return Settings.SaveAll(MS.config) end
    return true, nil
end
