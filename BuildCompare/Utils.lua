-- Wrapper to handle removal of global GetSpellInfo in WoW TWW (11.0+) / Midnight (12.0+)
local AddonName, _ = ...

local GetSpellInfo = GetSpellInfo or function(spellID)
    if not spellID then return nil end
    local spellInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    return spellInfo and spellInfo.name
end

-- Taint-safe helpers for Patch 12.0+ (Midnight) secret values
local issecretvalue = issecretvalue or function() return false end
local function IsSecret(val)
    return issecretvalue(val)
end

-- Format large numbers into clean abbreviations (e.g. 1.5k, 15k, 150k, 1.0m, 15m, 150m)
-- <1000 as integer; for k/m: 1 decimal only if the scaled value is <10, whole number without decimal when >=10 (exact user spec)
function BuildCompare_FormatNumber(val)
    if not val then return "0" end
    if IsSecret(val) then
        return val  -- Return the secret value directly for C++ rendering
    end
    local num = tonumber(val)
    if not num then return tostring(val) end
    
    if num >= 1000000 then
        local scaled = num / 1000000
        if scaled < 10 then
            return string.format("%.1fm", scaled)
        else
            return string.format("%.0fm", scaled)
        end
    elseif num >= 1000 then
        local scaled = num / 1000
        if scaled < 10 then
            return string.format("%.1fk", scaled)
        else
            return string.format("%.0fk", scaled)
        end
    else
        return string.format("%d", num)
    end
end

-- Format seconds into short timer string e.g. "1m 23s" or "45s" (for mini live recording timer)
-- Must be taint-safe: duration from C_DamageMeter can be a secret number (see getSafeDur in Core + IsSecret usage throughout).
function BuildCompare_FormatDuration(secs)
    if IsSecret(secs) then
        return "live"
    end
    if not secs or secs < 0 then secs = 0 end
    local s = math.floor(tonumber(secs) or 0)
    local m = math.floor(s / 60)
    s = s % 60
    if m > 0 then
        return string.format("%dm %02ds", m, s)
    else
        return string.format("%ds", s)
    end
end


-- Format percentage difference (lower value is better, e.g. damage taken)
function BuildCompare_FormatPercentDiffLowerBetter(a, b)
    if IsSecret(a) or IsSecret(b) then return "N/A" end
    a = tonumber(a) or 0
    b = tonumber(b) or 0
    if a == 0 and b == 0 then return "0.0%" end
    if a == 0 then
        return (b > 0 and "|cFFFF3333+inf%|r" or "0.0%")
    end
    local diff = ((b - a) / a) * 100
    local sign = diff > 0 and "+" or ""
    local color = diff < 0 and "|cFF00FF00" or (diff > 0 and "|cFFFF3333" or "|cFFFFFFFF")
    return string.format("%s%s%.1f%%|r", color, sign, diff)
end

-- Format percentage difference (higher value is better, e.g. healing/dps)
function BuildCompare_FormatPercentDiffHigherBetter(a, b)
    if IsSecret(a) or IsSecret(b) then return "N/A" end
    a = tonumber(a) or 0
    b = tonumber(b) or 0
    if a == 0 and b == 0 then return "0.0%" end
    if a == 0 then
        return (b > 0 and "|cFF00FF00+inf%|r" or "0.0%")
    end
    local diff = ((b - a) / a) * 100
    local sign = diff > 0 and "+" or ""
    local color = diff > 0 and "|cFF00FF00" or (diff < 0 and "|cFFFF3333" or "|cFFFFFFFF")
    return string.format("%s%s%.1f%%|r", color, sign, diff)
end

-- Format percentage difference (neutral, e.g. stats)
function BuildCompare_FormatPercentDiffNeutral(a, b)
    if IsSecret(a) or IsSecret(b) then return "N/A" end
    a = tonumber(a) or 0
    b = tonumber(b) or 0
    if a == 0 and b == 0 then return "0.0%" end
    local diff = ((b - a) / a) * 100
    local sign = diff > 0 and "+" or ""
    return string.format("|cFF80EAFF%s%.1f%%|r", sign, diff)
end

-- Convenience: short label for a run record
function BuildCompare_GetRunLabel(run)
    if not run then return "?" end
    local key = ""
    if run.isDelve then
        key = run.keyLevel > 0 and (" Delve+" .. run.keyLevel) or " Delve"
    elseif run.keyLevel > 0 then
        key = "+" .. run.keyLevel
    end
    return string.format("%s %s %s (%s)", run.instance, run.difficulty, key, run.buildLabel)
end

function BuildCompare_FormatCDs(cds)
    if not cds or #cds == 0 then return "none" end
    return #cds .. " used"
end

function BuildCompare_FormatCDsDetailed(cds)
    if not cds or #cds == 0 then return "None" end
    local counts = {}
    for _, cd in ipairs(cds) do
        counts[cd.name] = (counts[cd.name] or 0) + 1
    end
    local list = {}
    for name, count in pairs(counts) do
        table.insert(list, string.format("%s (%d)", name, count))
    end
    table.sort(list)
    return table.concat(list, ", ")
end

function BuildCompare_FormatDefensives(run)
    return BuildCompare_FormatCDs(run.defensiveCDsUsed)
end

function BuildCompare_FormatDefensivesDetailed(run)
    return BuildCompare_FormatCDsDetailed(run.defensiveCDsUsed)
end



-- Format a single stat line for comparison: "Mastery: 24500 vs 19800 (+23.7%)"
function BuildCompare_FormatStatDelta(label, valA, valB, percentLabel)
    local a = valA or 0
    local b = valB or 0
    local diff = BuildCompare_FormatPercentDiffNeutral(a, b)
    local aDisp = IsSecret(a) and "Pending" or (percentLabel and tostring(a) or BuildCompare_FormatNumber(a))
    local bDisp = IsSecret(b) and "Pending" or (percentLabel and tostring(b) or BuildCompare_FormatNumber(b))
    if IsSecret(a) or IsSecret(b) then
        local formatStr = percentLabel and " - %s: %s%% vs %s%% (%s)" or " - %s: %s vs %s (%s)"
        return string.format(formatStr, label, aDisp, bDisp, diff)
    end
    local formatStr = percentLabel and " - %s: %.1f%% vs %.1f%% (%s)" or " - %s: %s vs %s (%s)"
    return string.format(formatStr, label, aDisp, bDisp, diff)
end

-- Snapshot current active talent loadout name + list of selected talent names (using C_Traits / C_ClassTalents).
-- Per AGENTS.md: talents = { loadoutName = "...", selected = { "Talent Name", ... } }
function BuildCompare_SnapshotTalents()
    local result = { loadoutName = "Unknown", selected = {} }

    local ok, specID = pcall(function()
        return PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
    end)
    if not ok or not specID then
        -- Fallback to old API
        if GetSpecialization then
            local specIndex = GetSpecialization()
            if specIndex then
                local _, specName = GetSpecializationInfo(specIndex)
                result.loadoutName = specName or "Unknown Spec"
            end
        end
        return result
    end

    -- Best effort to get the active/saved config ID (loadout)
    local configID = nil
    if C_ClassTalents then
        local selectionID = nil
        if PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame and PlayerSpellsFrame.TalentsFrame.LoadoutDropDown and
           PlayerSpellsFrame.TalentsFrame.LoadoutDropDown.GetSelectionID then
            selectionID = PlayerSpellsFrame.TalentsFrame.LoadoutDropDown:GetSelectionID()
        end
        local lastSelected = C_ClassTalents.GetLastSelectedSavedConfigID and C_ClassTalents.GetLastSelectedSavedConfigID(specID)
        configID = selectionID or lastSelected or (C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID())
    end

    if not configID and C_Traits and C_Traits.GetConfigIDBySystemID then
        -- Fallback generic (rare for class talents)
        configID = C_Traits.GetConfigIDBySystemID(1) -- rough
    end

    if not configID then
        result.loadoutName = "No Loadout"
        return result
    end

    local configInfo = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(configID)
    if configInfo then
        result.loadoutName = configInfo.name or "Default Loadout"
    end

    -- Collect selected talents by walking committed ranks (preferred over entryIDs)
    local selected = {}
    local seen = {}
    if C_Traits and C_Traits.GetTreeNodes and C_Traits.GetNodeInfo and C_Traits.GetEntryInfo and C_Traits.GetDefinitionInfo then
        local treeIDs = (configInfo and configInfo.treeIDs) or {}
        for _, treeID in ipairs(treeIDs) do
            local nodes = C_Traits.GetTreeNodes(treeID) or {}
            for _, nodeID in ipairs(nodes) do
                local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                if nodeInfo then
                    local committed = nodeInfo.entryIDsWithCommittedRanks or nodeInfo.entryIDs or {}
                    for _, entryID in ipairs(committed) do
                        local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
                        if entryInfo and entryInfo.definitionID then
                            local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                            if defInfo and defInfo.spellID then
                                local spellName = GetSpellInfo and GetSpellInfo(defInfo.spellID) or tostring(defInfo.spellID)
                                if spellName and not seen[spellName] then
                                    seen[spellName] = true
                                    table.insert(selected, spellName)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(selected)
    result.selected = selected
    return result
end

-- Compute talents only in A (not in B) and only in B (not in A). Returns two lists.
function BuildCompare_TalentDiff(aTalents, bTalents)
    local aSel = (aTalents and aTalents.selected) or {}
    local bSel = (bTalents and bTalents.selected) or {}
    local aSet, bSet = {}, {}
    for _, n in ipairs(aSel) do aSet[n] = true end
    for _, n in ipairs(bSel) do bSet[n] = true end
    local onlyA, onlyB = {}, {}
    for _, n in ipairs(aSel) do if not bSet[n] then table.insert(onlyA, n) end end
    for _, n in ipairs(bSel) do if not aSet[n] then table.insert(onlyB, n) end end
    return onlyA, onlyB
end

function BuildCompare_FormatTalentsDiff(aTalents, bTalents)
    local onlyA, onlyB = BuildCompare_TalentDiff(aTalents, bTalents)
    local aName = (aTalents and aTalents.loadoutName) or "A"
    local bName = (bTalents and bTalents.loadoutName) or "B"
    local lines = {}
    if #onlyA > 0 then
        table.insert(lines, string.format(" Talents only in %s: %s", aName, table.concat(onlyA, ", ")))
    else
        table.insert(lines, string.format(" No talents unique to %s", aName))
    end
    if #onlyB > 0 then
        table.insert(lines, string.format(" Talents only in %s: %s", bName, table.concat(onlyB, ", ")))
    else
        table.insert(lines, string.format(" No talents unique to %s", bName))
    end
    if #onlyA == 0 and #onlyB == 0 then
        return " Talents identical between runs."
    end
    return table.concat(lines, "\n")
end


