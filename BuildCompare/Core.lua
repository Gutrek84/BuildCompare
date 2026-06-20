-- BuildCompare/Core.lua
-- Main logic: DB, C_DamageMeter polling, run recording, slash commands, instance/build detection.

local AddonName, _ = ...

-- Saved DB (populated by WoW from SavedVariables in .toc)
BuildCompareDB = BuildCompareDB or { runs = {}, settings = {} }
BuildCompareCharDB = BuildCompareCharDB or { runs = {} }  -- per-char if preferred

local DB = BuildCompareDB
local CharDB = BuildCompareCharDB

-- Active run tracking for auto-record and during-run metrics
local activeRun = nil

-- Common tank defensive cooldowns (spellID -> name). Expand as needed for your spec.
local DEFENSIVE_CDS = {
    [22812] = "Barkskin",
    [61336] = "Survival Instincts",
    [200851] = "Rage of the Sleeper",
    [871] = "Shield Wall",
    [12975] = "Last Stand",
    [48792] = "Icebound Fortitude",
    [48707] = "Anti-Magic Shell",
    [1022] = "Blessing of Protection",
    [6940] = "Blessing of Sacrifice",
    -- Add more for your tank spec (e.g. Demon Spikes IDs if relevant, etc.)
}

-- Simple print helper
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[BuildCompare]|r " .. tostring(msg))
end

-- Slash command
SLASH_BUILDCOMPARE1 = "/bc"
SLASH_BUILDCOMPARE2 = "/buildcompare"
SlashCmdList["BUILDCOMPARE"] = function(msg)
    if msg == "record" or msg == "save" then
        BuildCompare_RecordCurrentRun()
    elseif msg == "open" or msg == "" then
        BuildCompare_ShowUI()
    elseif msg == "clear" then
        BuildCompare_ClearDB()
    else
        Print("Commands: /bc | /bc open | /bc record | /bc clear")
    end
end

-- Detect if we are in a trackable instance (M+ focus for now; extend for raids)
local function IsTrackableContent()
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return false end

    local name, instanceType, difficultyID, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, instanceMapID, instanceGroupSize = GetInstanceInfo()

    -- Mythic+ or Mythic raids / normal raids etc. Customize as needed.
    if instanceType == "party" or instanceType == "raid" then
        local keystoneLevel = C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo and select(1, C_ChallengeMode.GetActiveKeystoneInfo()) or 0
        if keystoneLevel > 0 or difficultyID == 16 or difficultyID == 15 or difficultyID == 17 then -- M+, mythic, heroic, etc.
            return true, name, difficultyName, keystoneLevel
        end
    end
    return false
end

-- Snapshot relevant player stats for the "build"
local function SnapshotPlayerStats()
    local stats = {}
    -- Core secondaries for tanks (ratings or % as convenient)
    stats.mastery = GetCombatRating(CR_MASTERY) or 0
    stats.crit = GetCombatRating(CR_CRIT) or 0
    stats.haste = GetCombatRating(CR_HASTE) or 0
    stats.vers = GetCombatRating(CR_VERSATILITY) or 0

    -- % versions (often more useful for comparison)
    stats.masteryPct = GetMastery() or 0
    stats.critPct = GetCritChance() or 0
    stats.hastePct = GetHaste() or 0
    stats.versPct = GetCombatRatingBonus(CR_VERSATILITY) or 0   -- approximate

    stats.spec = (GetSpecialization and GetSpecializationInfo(GetSpecialization())) or "Unknown"
    stats.class = UnitClass("player") or "Unknown"

    return stats
end

-- Start tracking an active run (called on M+ start or boss pull)
local function StartActiveRun(buildLabel)
    if not IsTrackableContent() then return end

    local success, instanceName, diffName, keyLevel = IsTrackableContent()
    activeRun = {
        startTime = time(),
        instance = instanceName or "Unknown",
        difficulty = diffName or "Unknown",
        keyLevel = keyLevel or 0,
        buildLabel = buildLabel or "Auto",
        initialStats = SnapshotPlayerStats(),
        initialTalents = BuildCompare_SnapshotTalents(),
        defensiveCDsUsed = {},
    }
    Print("Active run tracking started for " .. (activeRun.instance or "") .. " (" .. (activeRun.buildLabel or "") .. ")")
end

-- Log a defensive CD usage (called from event handlers)
local function LogDefensiveCD(spellId, spellName)
    if not activeRun then return end
    if not DEFENSIVE_CDS[spellId] then return end  -- only track known defensives

    local name = spellName or DEFENSIVE_CDS[spellId]
    table.insert(activeRun.defensiveCDsUsed, {
        spellId = spellId,
        name = name,
        timestamp = time(),
    })
end

-- End tracking and auto-record if we have data
local function EndActiveRunAndRecord(reason)
    if not activeRun then return end

    Print("Run ended (" .. (reason or "complete") .. "). Auto-recording...")
    -- Force a record using the active run's label and data
    -- RecordCurrentRun will pick up activeRun fields and clear it
    BuildCompare_RecordCurrentRun(activeRun.buildLabel)
end

-- Pull useful summary from a C_DamageMeter combat session for the player (tank focus: DT + healing)
local function GetPlayerMeterSummary(session)
    if not session or not session.actors then return nil end

    local playerName = UnitName("player")
    local summary = { dt = 0, healing = 0, duration = session.duration or 0 }

    for _, actor in ipairs(session.actors or {}) do
        if actor.name == playerName then
            -- The exact field names depend on the C_DamageMeter table layout exposed by Blizzard.
            -- Inspect in-game with /dump C_DamageMeter.GetCombatSessionFromType(...) after a fight.
            -- Common patterns from 12.0+ meters: damageTaken, healingDone, etc.
            summary.dt = (actor.damageTaken or actor.totalDamageTaken or 0)
            summary.healing = (actor.healingDone or actor.totalHealing or actor.healing or 0)
            summary.absorbs = (actor.totalAbsorbs or actor.absorbs or actor.absorb or 0)

            -- Specific damage types / schools if the session exposes breakdowns (may be limited)
            -- Example possible fields (inspect live): damageTakenPhysical, damageTakenMagic, etc.
            summary.damageBreakdown = {
                physical = actor.damageTakenPhysical or actor.physicalDamageTaken or 0,
                magic = actor.damageTakenMagic or actor.spellDamageTaken or 0,
                -- Add more schools if present in your C_DamageMeter data (e.g. fire, shadow)
            }
            break
        end
    end

    if summary.duration and summary.duration > 0 then
        summary.dtps = summary.dt / summary.duration
        summary.hps = summary.healing / summary.duration
    end

    return summary
end

-- Record a completed run / segment
function BuildCompare_RecordCurrentRun(optionalLabel)
    local isTrackable, instanceName, diffName, keyLevel = IsTrackableContent()
    if not isTrackable then
        Print("Not currently in a supported instance (M+ / raid). Move into content or use manual label.")
        -- Allow manual anyway for testing
    end

    -- Get a recent combat session from the built-in meter
    -- Poll the official API (replaces old CLEU)
    if not C_DamageMeter or not C_DamageMeter.IsDamageMeterAvailable or not C_DamageMeter.IsDamageMeterAvailable() then
        Print("C_DamageMeter not available in this client/session. Enable the built-in damage meter in UI options.")
        return
    end

    -- Example: get the "current" or last damage taken / overall session.
    -- You may need to experiment with GetAvailableCombatSessions() and GetCombatSessionFromType("Overall") or "DamageTaken".
    local session = nil
    if C_DamageMeter.GetCombatSessionFromType then
        -- Common types observed in community: "Overall", "DamageDone", "DamageTaken", "Healing"
        session = C_DamageMeter.GetCombatSessionFromType("Overall") or C_DamageMeter.GetCombatSessionFromType("DamageTaken")
    end

    local meterSummary = GetPlayerMeterSummary(session)

    local buildLabel = optionalLabel or (activeRun and activeRun.buildLabel) or ("Build " .. date("%H%M"))
    local stats = SnapshotPlayerStats()
    local ts = time()

    -- Merge stats from active run start if available (for "at pull" snapshot)
    if activeRun and activeRun.initialStats then
        stats = activeRun.initialStats  -- prefer the start-of-run snapshot for consistency
    end

    local record = {
        id = ts .. "-" .. (keyLevel or 0),
        ts = ts,
        instance = instanceName or (activeRun and activeRun.instance) or "Unknown",
        difficulty = diffName or (activeRun and activeRun.difficulty) or "Unknown",
        keyLevel = keyLevel or (activeRun and activeRun.keyLevel) or 0,
        buildLabel = buildLabel,
        stats = stats,
        talents = (activeRun and activeRun.initialTalents) or BuildCompare_SnapshotTalents(),
        dt = meterSummary and meterSummary.dt or 0,
        dtps = meterSummary and meterSummary.dtps or 0,
        healing = meterSummary and meterSummary.healing or 0,
        hps = meterSummary and meterSummary.hps or 0,
        duration = meterSummary and meterSummary.duration or 0,
        absorbs = meterSummary and meterSummary.absorbs or 0,
        damageBreakdown = (meterSummary and meterSummary.damageBreakdown) or {},
        defensiveCDsUsed = (activeRun and activeRun.defensiveCDsUsed) or {},
        meterSessionId = session and session.id or nil,
    }

    -- Clear active run after recording
    activeRun = nil

    table.insert(DB.runs, record)
    -- Also keep a lightweight per-char copy if desired
    table.insert(CharDB.runs or {}, record)

    Print(string.format("Recorded run: %s - %s +%d | DT: %d (%.1f DTPS) | Heal: %d | Abs: %d | CDs: %d | Build: %s",
        record.instance, record.difficulty, record.keyLevel,
        record.dt, record.dtps, record.healing, record.absorbs or 0,
        #(record.defensiveCDsUsed or {}), record.buildLabel))

    -- Auto-refresh UI if open
    if BuildCompareFrame and BuildCompareFrame:IsShown() then
        BuildCompare_RefreshUI()
    end
end

function BuildCompare_ClearDB()
    DB.runs = {}
    CharDB.runs = {}
    Print("All recorded runs cleared.")
    if BuildCompareFrame and BuildCompareFrame:IsShown() then
        BuildCompare_RefreshUI()
    end
end

-- Lightweight poller example (call from a timer or OnUpdate if you want live updates)
local tickerFrame = CreateFrame("Frame")
local lastPoll = 0
tickerFrame:SetScript("OnUpdate", function(self, elapsed)
    lastPoll = lastPoll + elapsed
    if lastPoll > 5 then  -- poll every 5s during combat if desired
        lastPoll = 0
        -- Example: you could auto-detect end of run here and offer to record
        -- if not InCombatLockdown() and previous state was in combat + trackable...
    end
end)

-- Event handler for auto-record and CD tracking
local function OnCombatEvent(self, event, ...)
    if event == "CHALLENGE_MODE_START" then
        -- M+ started
        StartActiveRun()  -- auto label, or pass a label if desired
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        EndActiveRunAndRecord("M+ complete")
    elseif event == "ENCOUNTER_START" then
        -- Boss pull (for raids / some dungeons)
        local encounterID, encounterName = ...
        if IsTrackableContent() then
            StartActiveRun(encounterName or "Boss")
        end
    elseif event == "ENCOUNTER_END" then
        local encounterID, encounterName, difficultyID, groupSize, success = ...
        if success == 1 and activeRun then
            EndActiveRunAndRecord("boss kill")
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit == "player" then
            LogDefensiveCD(spellID)
        end
    elseif event == "UNIT_AURA" then
        -- Optional: catch aura applied for defensives (some CDs are instant aura)
        local unit = ...
        if unit == "player" then
            -- For simplicity, many CDs are caught by cast succeeded; aura can catch more
            -- To keep light, we rely primarily on cast. Can expand later.
        end
    end
end

-- Init
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHALLENGE_MODE_START")
f:RegisterEvent("CHALLENGE_MODE_COMPLETED")
f:RegisterEvent("ENCOUNTER_START")
f:RegisterEvent("ENCOUNTER_END")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == AddonName then
        Print("BuildCompare loaded. Use /bc to open. Auto-records on M+ complete / boss kill.")
    elseif event == "PLAYER_LOGIN" then
        -- Ensure tables
        DB.runs = DB.runs or {}
        CharDB.runs = CharDB.runs or {}
    else
        OnCombatEvent(self, event, arg1, ...)
    end
end)

-- Expose for UI and testing
_G.BuildCompare_RecordCurrentRun = BuildCompare_RecordCurrentRun
_G.BuildCompare_ShowUI = function() BuildCompare_ShowUI() end  -- defined in UI.lua
_G.BuildCompare_ClearDB = BuildCompare_ClearDB
_G.BuildCompare_StartActiveRun = StartActiveRun  -- for manual testing
_G.BuildCompare_EndActiveRunAndRecord = EndActiveRunAndRecord
