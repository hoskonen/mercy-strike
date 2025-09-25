-- Scripts/MercyStrike/MS_Unconscious.lua  (Lua 5.1)

MS_Unconscious = MS_Unconscious or {}

function MS_Unconscious.Apply(e, buffId)
    if not (e and buffId) then return false end
    local soul = e.soul
    if not (soul and soul.AddBuff) then return false end

    local ok, res = pcall(soul.AddBuff, soul, buffId) -- engine: AddBuff(string buff_id)
    local applied = ok and (res ~= nil)

    if applied then
        -- mark: do not re-apply to this target again
        MercyStrike._per = MercyStrike._per or {}
        MercyStrike._per[e.id] = MercyStrike._per[e.id] or {}
        MercyStrike._per[e.id].koApplied = true

        -- keep KO'd targets safely above 0 (optional but recommended)
        if MS and MS.ClampHealthPostKO then
            MS.ClampHealthPostKO(e)
        end
    end

    return applied
end

return MS_Unconscious
