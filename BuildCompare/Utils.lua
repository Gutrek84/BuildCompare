-- Wrapper to handle removal of global GetSpellInfo in WoW TWW (11.0+) / Midnight (12.0+)
local AddonName, _ = ...

function BuildCompare_SafeCall(func, defaultVal, ...)
    if type(func) ~= "function" then
        return defaultVal
    end
    local results = {pcall(func, ...)}
    local success = table.remove(results, 1)
    if success then
        return unpack(results)
    else
        local err = results[1] or "Unknown error"
        if not _G.BuildCompare_SessionErrors then
            _G.BuildCompare_SessionErrors = {}
        end
        table.insert(_G.BuildCompare_SessionErrors, err)
        if #_G.BuildCompare_SessionErrors > 50 then
            table.remove(_G.BuildCompare_SessionErrors, 1)
        end
        return defaultVal
    end
end

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

local unboxFrame = CreateFrame("Frame", nil, UIParent)
local unboxFS = unboxFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")

function BuildCompare_UnboxSecret(val)
    if not val then return 0 end
    if not IsSecret(val) then return tonumber(val) or 0 end
    
    unboxFS:SetFormattedText("%.6f", val)
    local text = unboxFS:GetText()
    if text then
        return tonumber(text) or 0
    end
    return 0
end


-- Format large numbers into clean abbreviations (e.g. 1.5k, 15k, 150k, 1.0m, 15m, 150m)
-- <1000 as integer; for k/m: 1 decimal only if the scaled value is <10, whole number without decimal when >=10 (exact user spec)
function BuildCompare_FormatNumber(val)
    if not val then return "0" end
    if IsSecret(val) then
        return _G.AbbreviateNumbers and _G.AbbreviateNumbers(val) or val
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
local function FormatUnsignedWhiteDiff(a, b)
    a = BuildCompare_UnboxSecret(a)
    b = BuildCompare_UnboxSecret(b)
    if a == 0 then return "0.0%" end
    local diff = ((b - a) / a) * 100
    return string.format("%.1f%%", math.abs(diff))
end

function BuildCompare_FormatPercentDiffLowerBetter(a, b)
    return FormatUnsignedWhiteDiff(a, b)
end

-- Format percentage difference (higher value is better, e.g. healing/dps)
function BuildCompare_FormatPercentDiffHigherBetter(a, b)
    return FormatUnsignedWhiteDiff(a, b)
end

-- Format percentage difference (neutral, e.g. stats)
function BuildCompare_FormatPercentDiffNeutral(a, b)
    return FormatUnsignedWhiteDiff(a, b)
end

-- Convenience: short label for a run record
function BuildCompare_GetRunLabel(run)
    if not run then return "?" end
    if run.runType == "custom" or run.instance == "Custom" or run.difficulty == "Custom" then
        return run.buildLabel or "Custom Run"
    end
    local key = ""
    if run.isDelve then
        key = run.keyLevel > 0 and (" Delve+" .. run.keyLevel) or " Delve"
    elseif run.keyLevel > 0 then
        key = "+" .. run.keyLevel
    end
    return string.format("%s %s %s (%s)", run.instance, run.difficulty, key, run.buildLabel)
end

function BuildCompare_GetColumnHeaderLabel(run)
    if not run then return "?" end
    local runType = run.runType or ""
    local difficulty = run.difficulty or ""
    local instance = run.instance or ""
    
    if instance == "Custom" or difficulty == "Custom" or runType == "custom" or runType == "Custom" then
        return run.buildLabel or "Custom"
    elseif runType == "raid" or runType == "Raid" or (run.boss ~= nil or run.bossName ~= nil) then
        return run.boss or run.bossName or "Raid"
    elseif runType == "mythic" or runType == "Mythic" or (run.keyLevel and run.keyLevel > 0) then
        local dungeon = run.dungeon or run.instance or "Dungeon"
        local abbrev = dungeon
        if dungeon == "Magisters' Terrace" then
            abbrev = "Terrace"
        elseif dungeon == "Maisara Caverns" then
            abbrev = "Caverns"
        elseif dungeon == "Nexus-Point Xenas" then
            abbrev = "Xenas"
        elseif dungeon == "Windrunner Spire" then
            abbrev = "Spire"
        elseif dungeon == "Algeth'ar Academy" then
            abbrev = "Academy"
        elseif dungeon == "Pit of Saron" then
            abbrev = "Pit"
        elseif dungeon == "Seat of the Triumvirate" then
            abbrev = "Seat"
        elseif dungeon == "Skyreach" then
            abbrev = "Skyreach"
        end
        local keyLevel = run.keyLevel or 0
        if keyLevel > 0 then
            return abbrev .. " +" .. keyLevel
        else
            return abbrev
        end
    end
    return run.buildLabel or "?"
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
        configID = BuildCompare_SafeCall(C_Traits.GetConfigIDBySystemID, nil, 1) -- rough
    end

    if not configID then
        result.loadoutName = "No Loadout"
        return result
    end

    local configInfo = C_Traits and C_Traits.GetConfigInfo and BuildCompare_SafeCall(C_Traits.GetConfigInfo, nil, configID)
    if configInfo then
        result.loadoutName = configInfo.name or "Default Loadout"
    end

    -- Collect selected talents by walking committed ranks (preferred over entryIDs)
    local selected = {}
    local seen = {}
    if C_Traits and C_Traits.GetTreeNodes and C_Traits.GetNodeInfo and C_Traits.GetEntryInfo and C_Traits.GetDefinitionInfo then
        local treeIDs = (configInfo and configInfo.treeIDs) or {}
        for _, treeID in ipairs(treeIDs) do
            local nodes = BuildCompare_SafeCall(C_Traits.GetTreeNodes, nil, treeID) or {}
            for _, nodeID in ipairs(nodes) do
                local nodeInfo = BuildCompare_SafeCall(C_Traits.GetNodeInfo, nil, configID, nodeID)
                if nodeInfo then
                    local committed = nodeInfo.entryIDsWithCommittedRanks or nodeInfo.entryIDs or {}
                    for _, entryID in ipairs(committed) do
                        local entryInfo = BuildCompare_SafeCall(C_Traits.GetEntryInfo, nil, configID, entryID)
                        if entryInfo and entryInfo.definitionID then
                            local defInfo = BuildCompare_SafeCall(C_Traits.GetDefinitionInfo, nil, entryInfo.definitionID)
                            if defInfo and defInfo.spellID then
                                local spellName = GetSpellInfo and GetSpellInfo(defInfo.spellID) or tostring(defInfo.spellID)
                                if spellName and not seen[spellName] then
                                    seen[spellName] = true
                                    table.insert(selected, string.format("%s:%d", spellName, defInfo.spellID))
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
    for _, n in ipairs(aSel) do 
        local name = strsplit(":", n)
        aSet[name] = true 
    end
    for _, n in ipairs(bSel) do 
        local name = strsplit(":", n)
        bSet[name] = true 
    end
    local onlyA, onlyB = {}, {}
    for _, n in ipairs(aSel) do 
        local name = strsplit(":", n)
        if not bSet[name] then table.insert(onlyA, n) end 
    end
    for _, n in ipairs(bSel) do 
        local name = strsplit(":", n)
        if not aSet[name] then table.insert(onlyB, n) end 
    end
    return onlyA, onlyB
end

function BuildCompare_FormatTalentsDiff(aTalents, bTalents)
    local onlyA, onlyB = BuildCompare_TalentDiff(aTalents, bTalents)
    local aName = (aTalents and aTalents.loadoutName) or "A"
    local bName = (bTalents and bTalents.loadoutName) or "B"
    local lines = {}
    
    local function stripIDs(t)
        local stripped = {}
        for _, v in ipairs(t) do
            local name = strsplit(":", v)
            table.insert(stripped, name)
        end
        return stripped
    end
    local strippedA = stripIDs(onlyA)
    local strippedB = stripIDs(onlyB)

    if #onlyA > 0 then
        table.insert(lines, string.format(" Talents only in %s: %s", aName, table.concat(strippedA, ", ")))
    else
        table.insert(lines, string.format(" No talents unique to %s", aName))
    end
    if #onlyB > 0 then
        table.insert(lines, string.format(" Talents only in %s: %s", bName, table.concat(strippedB, ", ")))
    else
        table.insert(lines, string.format(" No talents unique to %s", bName))
    end
    if #onlyA == 0 and #onlyB == 0 then
        return " Talents identical between runs."
    end
    return table.concat(lines, "\n")
end


