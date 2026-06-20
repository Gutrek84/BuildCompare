-- BuildCompare/Utils.lua
-- Pure helpers: stats, instance detection, formatting. No frames or saved state.

local AddonName, _ = ...

function BuildCompare_SnapshotPlayerStats()
    local stats = {}
    stats.mastery = GetCombatRating(CR_MASTERY) or 0
    stats.crit = GetCombatRating(CR_CRIT) or 0
    stats.haste = GetCombatRating(CR_HASTE) or 0
    stats.vers = GetCombatRating(CR_VERSATILITY) or 0

    stats.masteryPct = GetMastery() or 0
    stats.critPct = GetCritChance() or 0
    stats.hastePct = GetHaste() or 0
    stats.versPct = GetCombatRatingBonus(CR_VERSATILITY_DAMAGE_DONE) or 0  -- adjust constant if needed

    stats.specID, stats.specName = GetSpecializationInfo(GetSpecialization() or 0)
    stats.class = select(2, UnitClass("player"))

    return stats
end

function BuildCompare_GetCurrentInstanceInfo()
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return nil end

    local name, _, difficultyID, difficultyName = GetInstanceInfo()
    local keystoneLevel = 0
    if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
        keystoneLevel = select(1, C_ChallengeMode.GetActiveKeystoneInfo()) or 0
    end

    return {
        name = name,
        difficultyID = difficultyID,
        difficultyName = difficultyName,
        keyLevel = keystoneLevel,
        instanceType = instanceType,
    }
end

-- Format percentage difference (positive = better for the second value when comparing B vs A)
function BuildCompare_FormatPercentDiff(a, b)
    if not a or not b or a == 0 then return "N/A" end
    local diff = ((b - a) / a) * 100
    local sign = diff > 0 and "+" or ""
    local color = diff < 0 and "|cFF00FF00" or "|cFFFF0000"   -- green better for tank (lower DT), red worse. Customize.
    return string.format("%s%s%.1f%%|r", color, sign, diff)
end

-- Extract a compact summary from a C_DamageMeter session table
-- Call this after you have inspected the real table structure in-game:
-- /dump C_DamageMeter.GetCombatSessionFromType("Overall")
function BuildCompare_GetMeterSessionSummary(session)
    if not session then return nil end

    local playerName = UnitName("player")
    local sum = { dt = 0, healing = 0, duration = session.duration or session.elapsed or 0 }

    -- actors array or similar; field names are examples — verify live
    local actors = session.actors or session.participants or {}
    for _, actor in ipairs(actors) do
        if actor.name == playerName or actor.unitName == playerName then
            sum.dt = actor.damageTaken or actor.totalDamageTaken or actor.dt or 0
            sum.healing = actor.healingDone or actor.totalHealing or actor.heal or 0
            -- sum.absorbs = actor.absorbs or actor.totalAbsorbs or 0
            break
        end
    end

    if sum.duration > 0 then
        sum.dtps = sum.dt / sum.duration
        sum.hps = sum.healing / sum.duration
    end

    return sum
end

-- Convenience: short label for a run record
function BuildCompare_GetRunLabel(run)
    if not run then return "?" end
    local key = run.keyLevel > 0 and ("+" .. run.keyLevel) or ""
    return string.format("%s %s %s (%s)", run.instance, run.difficulty, key, run.buildLabel)
end
