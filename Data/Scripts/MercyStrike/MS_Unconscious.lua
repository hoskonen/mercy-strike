-- Scripts/MercyStrike/MS_Unconscious.lua  (Lua 5.1)

MS_Unconscious = MS_Unconscious or {}

function MS_Unconscious.Apply(e, buffId)
    if not (e and buffId) then return false end
    local soul = e.soul
    if not (soul and soul.AddBuff) then return false end

    local ok, res = pcall(soul.AddBuff, soul, buffId)
    local applied = ok and (res ~= nil)

    if applied then
        MercyStrike._per = MercyStrike._per or {}
        MercyStrike._per[e.id] = MercyStrike._per[e.id] or {}
        MercyStrike._per[e.id].koApplied = true

        -- mark this as the most recent KO
        MercyStrike.lastKOId = e.id

        -- immediate buffer clamp (prefer koClampOnApplyNorm, fallback to koFloorNorm)
        if MS and MS.ClampHealthMin then
            local n = (MS.config and MS.config.koClampOnApplyNorm) or nil
            MS.ClampHealthMin(e, n)
        elseif MS and MS.ClampHealthPostKO then
            MS.ClampHealthPostKO(e)
        end
    end

    return applied
end

return MS_Unconscious
