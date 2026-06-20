-- BuildCompare/Core.lua
-- Main logic: DB, C_DamageMeter polling, run recording, slash commands, instance/build detection.

local AddonName, _ = ...

-- Saved DB (populated by WoW from SavedVariables in .toc)
BuildCompareDB = BuildCompareDB or { runs = {}, settings = {} }
BuildCompareCharDB = BuildCompareCharDB or { runs = {} }  -- per-char if preferred

local DB = BuildCompareDB
local CharDB = BuildCompareCharDB

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
            -- Add absorbs if exposed: summary.absorbs = actor.totalAbsorbs or 0
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

    local buildLabel = optionalLabel or ("Build " .. date("%H%M"))
    local stats = SnapshotPlayerStats()
    local ts = time()

    local record = {
        id = ts .. "-" .. (keyLevel or 0),
        ts = ts,
        instance = instanceName or "Unknown",
        difficulty = diffName or "Unknown",
        keyLevel = keyLevel or 0,
        buildLabel = buildLabel,
        stats = stats,
        dt = meterSummary and meterSummary.dt or 0,
        dtps = meterSummary and meterSummary.dtps or 0,
        healing = meterSummary and meterSummary.healing or 0,
        hps = meterSummary and meterSummary.hps or 0,
        duration = meterSummary and meterSummary.duration or 0,
        meterSessionId = session and session.id or nil,
    }

    table.insert(DB.runs, record)
    -- Also keep a lightweight per-char copy if desired
    table.insert(CharDB.runs or {}, record)

    Print(string.format("Recorded run: %s - %s +%d | DT: %d (%.1f DTPS) | Heal: %d | Build: %s",
        record.instance, record.difficulty, record.keyLevel,
        record.dt, record.dtps, record.healing, record.buildLabel))

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

-- Init
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == AddonName then
        Print("BuildCompare loaded. Use /bc to open, /bc record after a run.")
    elseif event == "PLAYER_LOGIN" then
        -- Ensure tables
        DB.runs = DB.runs or {}
        CharDB.runs = CharDB.runs or {}
    end
end)

-- Expose for UI and testing
_G.BuildCompare_RecordCurrentRun = BuildCompare_RecordCurrentRun
_G.BuildCompare_ShowUI = function() BuildCompare_ShowUI() end  -- defined in UI.lua
_G.BuildCompare_ClearDB = BuildCompare_ClearDB
