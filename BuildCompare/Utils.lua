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
            sum.absorbs = actor.totalAbsorbs or actor.absorbs or actor.absorb or 0

            sum.damageBreakdown = {
                physical = actor.damageTakenPhysical or actor.physicalDamageTaken or 0,
                magic = actor.damageTakenMagic or actor.spellDamageTaken or 0,
            }
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

function BuildCompare_FormatDefensives(run)
    local cds = run.defensiveCDsUsed or {}
    if #cds == 0 then return "none" end
    return #cds .. " used"
    -- Could expand to list names if wanted: table.concat names
end

function BuildCompare_FormatDamageBreakdown(run)
    local db = run.damageBreakdown or {}
    if (db.physical or 0) + (db.magic or 0) == 0 then return "" end
    return string.format("Phys: %d / Magic: %d", db.physical or 0, db.magic or 0)
end

-- Format a single stat line for comparison: "Mastery      | 24500 vs 19800 | +23.7%"
function BuildCompare_FormatStatDelta(label, valA, valB)
    local a = valA or 0
    local b = valB or 0
    local diff = BuildCompare_FormatPercentDiff(a, b)
    return string.format("%-12s | %8s vs %8s | %s", label, tostring(a), tostring(b), diff)
end

-- Optional header for stat section
function BuildCompare_GetStatDeltaHeader()
    return "Stat         |      A vs      B | % Diff"
end

-- Snapshot current active talents using the modern C_Traits API (Midnight+ / 12.0+).
-- Returns a table with loadoutName and a sorted list of selected talent names.
-- This lets us compare "same gear, different talents" runs.
function BuildCompare_SnapshotTalents()
    local result = {
        loadoutName = "Unknown Loadout",
        selected = {},
    }

    if not C_Traits or not C_Traits.GetActiveConfigID then
        return result
    end

    local configID = C_Traits.GetActiveConfigID()
    if not configID then
        return result
    end

    -- Get the loadout name if the player has named it
    local configInfo = C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(configID)
    if configInfo and configInfo.name then
        result.loadoutName = configInfo.name
    end

    -- Get the talent tree and selected nodes
    local treeInfo = C_Traits.GetTreeInfo and C_Traits.GetTreeInfo(configID)
    if not treeInfo or not treeInfo.nodes then
        return result
    end

    for _, nodeID in ipairs(treeInfo.nodes) do
        local nodeInfo = C_Traits.GetNodeInfo and C_Traits.GetNodeInfo(configID, nodeID)
        if nodeInfo and nodeInfo.activeEntry and nodeInfo.activeEntry.entryID then
            local entryInfo = C_Traits.GetEntryInfo and C_Traits.GetEntryInfo(configID, nodeInfo.activeEntry.entryID)
            if entryInfo and entryInfo.definitionID then
                local defInfo = C_Traits.GetDefinitionInfo and C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                if defInfo and defInfo.spellID then
                    local spellName = GetSpellInfo(defInfo.spellID)
                    if spellName then
                        table.insert(result.selected, spellName)
                    else
                        table.insert(result.selected, "SpellID:" .. defInfo.spellID)
                    end
                end
            end
        end
    end

    table.sort(result.selected)
    return result
end

