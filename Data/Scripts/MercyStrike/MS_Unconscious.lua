-- Scripts/MercyStrike/MS_Unconscious.lua  (Lua 5.1)

MS_Unconscious = MS_Unconscious or {}

function MS_Unconscious.Apply(e, buffId)
    if not (e and buffId) then return false end
    local soul = e.soul
    if not (soul and soul.AddBuff) then return false end
    local ok, res = pcall(soul.AddBuff, soul, buffId) -- engine: AddBuff(string buff_id)
    return ok and (res ~= nil) or false
end

return MS_Unconscious
