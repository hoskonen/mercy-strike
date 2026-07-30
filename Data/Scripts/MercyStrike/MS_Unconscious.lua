-- Scripts/MercyStrike/MS_Unconscious.lua  (Lua 5.1)

MS_Unconscious = MS_Unconscious or {}
local MS = MercyStrike

function MS_Unconscious.Apply(e, buffId)
    if not (e and buffId) then return false end
    local soul = e.soul
    if not (soul and soul.AddBuff) then return false end

    local ok, res = pcall(soul.AddBuff, soul, buffId)
    -- KCD2 may return nil even when AddBuff succeeds; pcall is the only
    -- consistently observable result (matching Cura Equi's proven usage).
    local applied = ok

    if MS and MS.LogCore then
        MS.LogCore(string.format("[Unconscious] AddBuff id=%s ok=%s result=%s",
            tostring(buffId), tostring(ok), tostring(res)))
    end

    if applied then
        MercyStrike._per = MercyStrike._per or {}
        MercyStrike._per[e.id] = MercyStrike._per[e.id] or {}
        MercyStrike._per[e.id].unconsciousApplied = true

        -- Immediate buffer for low-health fallback transitions.
        if MS and MS.ClampHealthMin then
            local n = (MS.config and MS.config.unconsciousClampNorm) or 0.06
            MS.ClampHealthMin(e, n)
        end
    end

    return applied
end

return MS_Unconscious
