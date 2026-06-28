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
local currentCombat = nil
BuildCompare_LastCombatSegment = nil
local playerGUID = nil

-- Common defensive cooldowns (spellID -> name). Expand as needed for your spec.
local DEFENSIVE_CDS = {
    -- Druid
    [22812] = "Barkskin",
    [61336] = "Survival Instincts",
    [200851] = "Rage of the Sleeper",
    -- Warrior
    [871] = "Shield Wall",
    [12975] = "Last Stand",
    -- Death Knight
    [48792] = "Icebound Fortitude",
    [48707] = "Anti-Magic Shell",
    -- Paladin (Midnight 12.0.5 verified)
    [31850] = "Ardent Defender",
    [86659] = "Guardian of Ancient Kings",
    [642] = "Divine Shield",
    [498] = "Divine Protection",
    [31884] = "Avenging Wrath",
    [389539] = "Sentinel",
    [633] = "Lay on Hands",
    [1022] = "Blessing of Protection",
    [6940] = "Blessing of Sacrifice",
    [204018] = "Blessing of Spellwarding",
    [204020] = "Bastion of Light",
    [432459] = "Divine Toll",
}

-- Season 1 data for the new scoped UI (Mythic/Raid dropdowns). Streamlined - only used for filtering display.
local SEASON_1_MYTHICS = {
    "Magisters' Terrace",
    "Maisara Caverns",
    "Nexus-Point Xenas",
    "Windrunner Spire",
    "Algeth'ar Academy",
    "Pit of Saron",
    "Seat of the Triumvirate",
    "Skyreach"
}

local SEASON_1_RAIDS = {
    ["The Voidspire"] = {
        "Imperator Averzian",
        "Vorasius",
        "Fallen-King Salhadaar",
        "Vaelgor & Ezzorak",
        "Lightblinded Vanguard",
        "Crown of the Cosmos"
    },
    ["Dreamrift"] = {
        "Chimaerus"
    },
    ["March on Quel'Danas"] = {
        "Belo'ren",
        "Midnight Falls"
    },
    ["Sporefall"] = {
        "Rotmire"
    }
}

_G.BuildCompareData = {
    SEASON_1_MYTHICS = SEASON_1_MYTHICS,
    SEASON_1_RAIDS = SEASON_1_RAIDS
}

-- (DPS_CDS and HEALING_CDS tables removed for streamlining.
-- The addon tracks performance metrics for any spec. We track defensive cooldown usage via UNIT_SPELLCAST_SUCCEEDED.
-- All aggregate damage/healing numbers come directly from C_DamageMeter.)

-- Simple print helper
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[BuildCompare]|r " .. tostring(msg))
end

-- Taint-safe helpers for Patch 12.0+ (Midnight) secret values
local issecretvalue = issecretvalue or function() return false end
local function IsSecret(val)
    return issecretvalue(val)
end

local function SafeDiv(a, b)
    if IsSecret(a) or IsSecret(b) then
        return 0
    end
    return b > 0 and (a / b) or 0
end

local function GetRate(rate, total, duration)
    if IsSecret(rate) then
        return rate
    end
    if rate and rate ~= 0 then
        return rate
    end
    return SafeDiv(total, duration)
end

-- Slash command
SLASH_BUILDCOMPARE1 = "/bc"
SLASH_BUILDCOMPARE2 = "/buildcompare"

local function DumpTable(tbl, indent)
    if not tbl then return "nil" end
    indent = indent or ""
    local s = "{\n"
    for k, v in pairs(tbl) do
        local valStr = tostring(v)
        if type(v) == "table" then
            valStr = DumpTable(v, indent .. "  ")
        elseif type(v) == "string" then
            valStr = '"' .. v .. '"'
        end
        s = s .. indent .. "  [" .. tostring(k) .. "] = " .. valStr .. ",\n"
    end
    return s .. indent .. "}"
end

local function BuildCompare_DebugMeter()
    Print("--- BuildCompare Debug Info ---")
    if not C_DamageMeter then
        Print("C_DamageMeter is nil")
    else
        if Enum and Enum.DamageMeterType then
            Print("Enum.DamageMeterType Values:")
            for k, v in pairs(Enum.DamageMeterType) do
                Print(string.format("  %s = %s", tostring(k), tostring(v)))
            end
        else
            Print("Enum.DamageMeterType is nil")
        end

        local sessionID = nil
        if C_DamageMeter.GetAvailableCombatSessions then
            local sessions = C_DamageMeter.GetAvailableCombatSessions()
            if sessions then
                Print("Sessions count: " .. #sessions)
                for i, sInfo in ipairs(sessions) do
                    Print(string.format("  [%d] SessionID: %s, Name: %s, Duration: %ss", 
                        i, tostring(sInfo.sessionID), tostring(sInfo.name), tostring(sInfo.durationSeconds)))
                end
                if #sessions > 0 then
                    sessionID = sessions[#sessions].sessionID
                end
            else
                Print("GetAvailableCombatSessions returned nil")
            end
        end

        Print("Selected Session ID: " .. tostring(sessionID))

        -- Native meter demo (use this in-game: /bc debug )
        local nativeSummary = GetNativeMeterData()
        if nativeSummary then
            local function SafeFormatVal(val)
                if not val then return "0" end
                if IsSecret(val) then
                    return "Pending Reload"
                end
                return BuildCompare_FormatNumber(val)
            end
            Print(string.format("Native C_DamageMeter Summary: Duration=%s, Damage=%s, DT=%s, AvDT=%s, Heal=%s, DPS=%s, DTPS=%s, HPS=%s, HasActivity=%s",
                tostring(nativeSummary.duration or 0), SafeFormatVal(nativeSummary.damage), SafeFormatVal(nativeSummary.dt),
                SafeFormatVal(nativeSummary.avoidableDT), SafeFormatVal(nativeSummary.healing), SafeFormatVal(nativeSummary.dps),
                SafeFormatVal(nativeSummary.dtps), SafeFormatVal(nativeSummary.hps), tostring(nativeSummary.hasActivity)))
            -- Also show direct GetCombatSessionFromType example (Overall + DamageTaken)
            if Enum and Enum.DamageMeterSessionType and Enum.DamageMeterType then
                local dtSess = C_DamageMeter.GetCombatSessionFromType(Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.DamageTaken)
                if dtSess then
                    Print("Direct Overall+DT session: totalAmount=" .. SafeFormatVal(dtSess.totalAmount) .. " sources=" .. #(dtSess.combatSources or {}))
                end
            end
        else
            Print("Native C_DamageMeter summary not available (or no activity / not 12.0+). Try in combat or after a pull. Use /dump C_DamageMeter.IsDamageMeterAvailable()")
        end

        if sessionID and C_DamageMeter.GetCombatSessionFromID then
            -- Optional direct ID fetch for one metric
            if Enum and Enum.DamageMeterType then
                local idSess = C_DamageMeter.GetCombatSessionFromID(sessionID, Enum.DamageMeterType.DamageTaken)
                if idSess then
                    Print("SessionFromID DT available, sources: " .. #(idSess.combatSources or {}))
                end
            end
        end
    end
end

SlashCmdList["BUILDCOMPARE"] = function(msg)
    if msg == "record" or msg == "save" then
        BuildCompare_RecordCurrentRun()
    elseif msg == "open" or msg == "" then
        BuildCompare_ShowUI()
    elseif msg == "clear" then
        BuildCompare_ClearDB()
    elseif msg == "debug" then
        BuildCompare_DebugMeter()
    elseif msg == "mini" then
        if _G.BuildCompare_ShowMiniCurrent then _G.BuildCompare_ShowMiniCurrent() end
    else
        Print("Commands: /bc | /bc open | /bc record | /bc clear | /bc debug | /bc mini")
    end
end

-- Detect if we are in a trackable instance (M+ focus for now; extend for raids)
local function IsTrackableContent()
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return false end

    local name, instanceType, difficultyID, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, instanceMapID, instanceGroupSize = GetInstanceInfo()

    -- Streamlined: only auto-track full Mythic+ runs (via keystone) and individual raid bosses (via ENCOUNTER).
    -- Removed all auto for dummies, delves, outdoor, raid trash, etc.
    if instanceType == "party" or instanceType == "raid" or instanceType == "scenario" then
        local keystoneLevel = C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo and select(1, C_ChallengeMode.GetActiveKeystoneInfo()) or 0
        if keystoneLevel > 0 or difficultyID == 16 or difficultyID == 15 or difficultyID == 17 then -- M+, mythic, heroic, etc.
            return true, name, difficultyName, keystoneLevel, false
        end
    end
    return false
end

-- Snapshot relevant player stats for the "build"
local function SnapshotPlayerStats()
    local stats = {}
    
    local ok, value = pcall(GetCombatRating, CR_MASTERY)
    stats.mastery = ok and value or 0
    
    ok, value = pcall(GetCombatRating, CR_CRIT_MELEE)
    stats.crit = ok and value or 0
    
    ok, value = pcall(GetCombatRating, CR_HASTE_MELEE)
    stats.haste = ok and value or 0
    
    ok, value = pcall(GetCombatRating, CR_VERSATILITY_DAMAGE_DONE)
    stats.vers = ok and value or 0

    stats.masteryPct = GetMastery() or 0
    stats.critPct = GetCritChance() or 0
    stats.hastePct = GetHaste() or 0
    
    ok, value = pcall(GetCombatRatingBonus, CR_VERSATILITY_DAMAGE_DONE)
    stats.versPct = ok and value or 0

    stats.class = UnitClass("player") or "Unknown"
    
    stats.spec = "None"
    if GetSpecialization then
        local specIndex = GetSpecialization()
        if specIndex then
            local specID, specName = GetSpecializationInfo(specIndex)
            stats.spec = specName or "None"
        end
    end

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
        talents = BuildCompare_SnapshotTalents(),
        defensiveCDsUsed = {},
        damage = 0,
        dt = 0,
        healing = 0,
        interrupts = 0,
        dispels = 0,
        deaths = 0,
    }
    Print("Active run tracking started for " .. (activeRun.instance or "") .. " (" .. (activeRun.buildLabel or "") .. ")")
end

-- Manual custom run tracking (user requested: button to start/stop for custom runs)
local function StartCustomRun()
    if activeRun then
        Print("Already tracking a run. Stop it first or wait for it to end.")
        return
    end
    StaticPopupDialogs["BUILDCOMPARE_CUSTOM_LABEL"] = {
        text = "Enter label for this custom run:",
        button1 = "Start Tracking",
        button2 = "Cancel",
        hasEditBox = 1,
        OnAccept = function(self)
            local eb = self.EditBox or _G[self:GetName().."EditBox"]
            local label = (eb and eb:GetText()) or "Custom Run"
            if label == "" then label = "Custom Run" end
            activeRun = {
                startTime = time(),
                instance = "Custom",
                difficulty = "Custom",
                keyLevel = 0,
                runType = "custom",
                buildLabel = label,
                initialStats = SnapshotPlayerStats(),
                talents = BuildCompare_SnapshotTalents(),
                defensiveCDsUsed = {},
                damage = 0,
                dt = 0,
                healing = 0,
                interrupts = 0,
                dispels = 0,
                deaths = 0,
            }
            Print("Custom tracking started: " .. label .. ". Use Stop button or /bc record when done.")
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
    }
    StaticPopup_Show("BUILDCOMPARE_CUSTOM_LABEL")
end

local function StopCustomTracking()
    if activeRun and activeRun.runType == "custom" then
        BuildCompare_RecordCurrentRun(activeRun.buildLabel)
    else
        Print("No active custom run to stop.")
    end
end

-- Log a defensive CD usage (called from event handlers)
local function LogDefensiveCD(spellId, spellName)
    if not DEFENSIVE_CDS[spellId] then return end  -- only track known defensives

    local name = spellName or DEFENSIVE_CDS[spellId]
    local cd = {
        spellId = spellId,
        name = name,
        timestamp = time(),
    }
    if activeRun then
        table.insert(activeRun.defensiveCDsUsed, cd)
    end
end

-- (LogDPSCD and LogHealingCD removed as part of streamlining.
-- Only defensive CDs are tracked for defensive usage.)

-- End tracking and auto-record if we have data
local function EndActiveRunAndRecord(reason)
    if not activeRun then return end

    Print("Run ended (" .. (reason or "complete") .. "). Auto-recording...")
    -- Force a record using the active run's label and data
    -- RecordCurrentRun will pick up activeRun fields and clear it
    BuildCompare_RecordCurrentRun(activeRun.buildLabel)
end

-- Pick the best sessionID from GetAvailableCombatSessions for short/solo/dummy runs.
-- We prefer the most recent session whose durationSeconds looks like a single pull (not the multi-hour Overall).
-- This lets us lock *all* metrics (DT, Healing, AvoidableDT, etc.) to the exact same combat session,
-- preventing the per-type fallback (Current for DT but Overall for Abs/Heal) that was causing mixed numbers.
local function GetBestSessionIDForCurrentPull()
    if not C_DamageMeter or not C_DamageMeter.GetAvailableCombatSessions then
        return nil
    end
    local sessions = C_DamageMeter.GetAvailableCombatSessions() or {}
    if #sessions == 0 then return nil end

    -- Walk from the end (most recent first)
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        local d = s.durationSeconds
        if IsSecret(d) then
            -- Duration is protected, but this is still the most recent session — good candidate for a fresh pull
            return s.sessionID
        end
        if d and d >= 2 and d <= 300 then
            -- Plausible length for one dummy/golem pull or short boss
            return s.sessionID
        end
    end

    -- Fallback to the absolute latest session in the list
    return sessions[#sessions].sessionID
end

-- Native C_DamageMeter data fetch (primary/only source for 12.0+ per AGENTS.md).
-- Pure direct from WoW APIs, no external addon dependency.
-- Returns summary (with hasActivity) or nil.
-- preferCurrent: when true (non-M+ / solo dummy / short boss), we try to lock to a specific recent short sessionID
-- (instead of just preferring Current type). This ensures DT, Heal, AvoidableDT etc. all come from the *same* pull.
local function GetNativeMeterData(preferCurrent)
    if not C_DamageMeter or not C_DamageMeter.IsDamageMeterAvailable then
        return nil
    end
    local avail, _reason = C_DamageMeter.IsDamageMeterAvailable()
    if not avail then
        return nil
    end
    if not Enum or not Enum.DamageMeterSessionType or not Enum.DamageMeterType then
        return nil
    end

    -- For short content, try to get one consistent sessionID from the available list.
    -- Then we'll query every metric type from that exact ID.
    local lockedSessionID = preferCurrent and GetBestSessionIDForCurrentPull() or nil

    local function fetchForType(dmType)
        -- If we have a locked sessionID from GetAvailable (best for dummies), use GetCombatSessionFromID on it.
        -- This guarantees all metrics (damage taken, healing, avoidable damage...) come from the identical combat session.
        if lockedSessionID and C_DamageMeter.GetCombatSessionFromID then
            local sess = C_DamageMeter.GetCombatSessionFromID(lockedSessionID, dmType)
            if sess and sess.combatSources and #sess.combatSources > 0 then
                for _, src in ipairs(sess.combatSources) do
                    if src.isLocalPlayer then
                        return {
                            total = src.totalAmount or 0,
                            perSec = src.amountPerSecond or 0,
                            duration = sess.durationSeconds or 0,
                        }
                    end
                end
            end
            -- If the locked ID didn't have a player source for this type, fall through to the type-based order.
        end

        -- Fallback / M+ path: use FromType with smart order
        local sessionOrder = preferCurrent
            and {Enum.DamageMeterSessionType.Current, Enum.DamageMeterSessionType.Overall}
            or  {Enum.DamageMeterSessionType.Overall, Enum.DamageMeterSessionType.Current}

        for _, st in ipairs(sessionOrder) do
            local sess = C_DamageMeter.GetCombatSessionFromType(st, dmType)
            if sess and sess.combatSources and #sess.combatSources > 0 then
                for _, src in ipairs(sess.combatSources) do
                    if src.isLocalPlayer then
                        return {
                            total = src.totalAmount or 0,
                            perSec = src.amountPerSecond or 0,
                            duration = sess.durationSeconds or 0,
                        }
                    end
                end
            end
        end
        return nil
    end

    local dtD = fetchForType(Enum.DamageMeterType.DamageTaken, lockedSessionID)
    local healD = fetchForType(Enum.DamageMeterType.HealingDone, lockedSessionID)
    local hpsD = fetchForType(Enum.DamageMeterType.Hps, lockedSessionID)
    local avoidD = fetchForType(Enum.DamageMeterType.AvoidableDamageTaken, lockedSessionID)
    local dmgD = fetchForType(Enum.DamageMeterType.DamageDone, lockedSessionID)
    local dpsD = fetchForType(Enum.DamageMeterType.Dps, lockedSessionID)
    local intD = fetchForType(Enum.DamageMeterType.Interrupts, lockedSessionID)
    local dispD = fetchForType(Enum.DamageMeterType.Dispels, lockedSessionID)
    local deathsD = fetchForType(Enum.DamageMeterType.Deaths, lockedSessionID)

    -- dur is ONLY used for the SafeDiv *fallback* when the meter did not supply a perSec.
    -- We must keep this local free of secret values and never compare a secret against 0 (taint error).
    -- See the user's error: "attempt to compare local 'dur' (a secret number value, while execution tainted by 'BuildCompare')"
    local function getSafeDur(d)
        if not d or IsSecret(d) then return 0 end
        return d
    end

    local dur = 0
    if dtD then dur = getSafeDur(dtD.duration) end
    if dur == 0 and healD then dur = getSafeDur(healD.duration) end
    if dur == 0 and dmgD then dur = getSafeDur(dmgD.duration) end
    if dur <= 0 then dur = 1 end

    local has = (dtD ~= nil or healD ~= nil or avoidD ~= nil)

    return {
        dt = dtD and dtD.total or 0,
        -- Take the meter's perSec if present (it may be a secret number; the display layer using SetFormattedText
        -- and SafeDisplayVal knows how to render those). Only fall back to arithmetic when necessary.
        dtps = dtD and dtD.perSec or SafeDiv((dtD and dtD.total or 0), dur),
        healing = healD and healD.total or 0,
        hps = (hpsD and hpsD.perSec) or SafeDiv((healD and healD.total or 0), dur),
        avoidableDT = avoidD and avoidD.total or 0,
        avoidableDTPS = avoidD and avoidD.perSec or SafeDiv((avoidD and avoidD.total or 0), dur),
        damage = dmgD and dmgD.total or 0,
        dps = (dpsD and dpsD.perSec) or SafeDiv((dmgD and dmgD.total or 0), dur),
        -- The duration we store in the run record is allowed to be secret (UI handles it).
        duration = (dtD and dtD.duration) or (healD and healD.duration) or dur,
        interrupts = intD and intD.total or 0,
        dispels = dispD and dispD.total or 0,
        deaths = deathsD and deathsD.total or 0,
        hasActivity = has,
    }
end

-- Expose for mini current run overlay
_G.GetNativeMeterData = GetNativeMeterData

-- Retrieve combat metrics summary. Pure native C_DamageMeter only (streamlined, no external addons).
local function GetPlayerMeterSummary(isOverall, runStartTime)
    -- For M+ (keyLevel > 0) we want the Overall full-run numbers (the type-based Overall is usually correct).
    -- For dummy/solo/short content we compute a lockedSessionID (most recent short session from GetAvailableCombatSessions)
    -- and query *every* metric type from that exact same sessionID. This prevents the previous problem where
    -- DT might come from Current but Healing/AvoidableDT fell back to a huge cumulative Overall (now prevented by locked sessionID for short runs).
    local preferCurrent = not isOverall
    local native = GetNativeMeterData(preferCurrent)
    if native then
        return native
    end
    -- No native data available this time (pre-12.0, no session yet, or unsupported content).
    -- We still record the safe parts (talents, stats, CDs, duration from activeRun, etc.).
    return {
        dt = 0, dtps = 0, healing = 0, hps = 0,
        avoidableDT = 0, avoidableDTPS = 0,
        damage = 0, dps = 0, duration = 0,
        interrupts = 0, dispels = 0, deaths = 0,
        hasActivity = false,
    }
end

-- Record a completed run / segment
function BuildCompare_RecordCurrentRun(optionalLabel)
    local isTrackable, instanceName, diffName, keyLevel = IsTrackableContent()
    
    local recordSource = nil
    if activeRun then
        recordSource = activeRun
    elseif BuildCompare_LastCombatSegment then
        recordSource = BuildCompare_LastCombatSegment
    end

    if not recordSource then
        Print("No active run or recent combat segment found. Go enter combat or start a dungeon first!")
        return
    end

    -- Capture key fields locally before clearing to prevent race conditions during delay
    local capturedSource = {
        startTime = recordSource.startTime,
        duration = recordSource.duration,
        instance = recordSource.instance,
        difficulty = recordSource.difficulty,
        keyLevel = recordSource.keyLevel,
        runType = recordSource.runType,
        bossName = recordSource.bossName,
        dungeon = recordSource.dungeon,
        raid = recordSource.raid,
        boss = recordSource.boss,
        buildLabel = recordSource.buildLabel,
        initialStats = recordSource.initialStats,
        talents = recordSource.talents,
        defensiveCDsUsed = recordSource.defensiveCDsUsed,
        damage = recordSource.damage,
        dt = recordSource.dt,
        healing = recordSource.healing,
        interrupts = recordSource.interrupts,
        dispels = recordSource.dispels,
        deaths = recordSource.deaths,
    }

    -- Clear active run and combat segment immediately to allow new runs to start
    activeRun = nil
    BuildCompare_LastCombatSegment = nil

    local function FinalizeRecord()
        local duration = capturedSource.duration or 0
        if duration == 0 and capturedSource.startTime then
            duration = time() - capturedSource.startTime
        end

        local damage = capturedSource.damage or 0
        local dps = 0
        local dt = capturedSource.dt or 0
        local dtps = 0
        local avoidableDT = 0
        local avoidableDTPS = 0
        local healing = capturedSource.healing or 0
        local hps = 0
        local interrupts = capturedSource.interrupts or 0
        local dispels = capturedSource.dispels or 0
        local deaths = capturedSource.deaths or 0
        local defensiveCDsUsed = capturedSource.defensiveCDsUsed or {}
        local hasActivity = false

        -- Fetch the combat summary directly from the built-in C_DamageMeter (pure WoW, no external addons)
        local isOverall = (capturedSource.keyLevel and capturedSource.keyLevel > 0)
        local meterSummary = GetPlayerMeterSummary(isOverall, capturedSource.startTime)
        if meterSummary then
            dt = meterSummary.dt or dt
            dtps = meterSummary.dtps or dtps
            avoidableDT = meterSummary.avoidableDT or avoidableDT
            avoidableDTPS = meterSummary.avoidableDTPS or avoidableDTPS
            healing = meterSummary.healing or healing
            hps = meterSummary.hps or hps
            damage = meterSummary.damage or damage
            dps = meterSummary.dps or dps
            duration = meterSummary.duration or duration
            interrupts = meterSummary.interrupts or interrupts
            dispels = meterSummary.dispels or dispels
            deaths = meterSummary.deaths or deaths
            hasActivity = meterSummary.hasActivity
        end

        -- (Removed solo auto-run logic per narrowed scope; no more per-pack dummy/delve/outdoor records)

        local buildLabel = optionalLabel or capturedSource.buildLabel or ("Build " .. date("%H%M"))
        local stats = SnapshotPlayerStats()
        local ts = time()

        local record = {
            id = ts .. "-" .. (keyLevel or capturedSource.keyLevel or 0),
            ts = ts,
            instance = instanceName or capturedSource.instance or "Unknown",
            difficulty = diffName or capturedSource.difficulty or "Unknown",
            keyLevel = keyLevel or capturedSource.keyLevel or 0,
            runType = "custom",
            buildLabel = buildLabel,
            stats = stats,
            talents = capturedSource.talents or BuildCompare_SnapshotTalents(),
            dt = dt,
            dtps = dtps,
            avoidableDT = avoidableDT,
            avoidableDTPS = avoidableDTPS,
            healing = healing,
            hps = hps,
            duration = duration,
            damage = damage,
            dps = dps,
            interrupts = interrupts,
            dispels = dispels,
            deaths = deaths,
            defensiveCDsUsed = defensiveCDsUsed,
            meterSessionId = isOverall and "overall" or "current",
        }

        -- Classify the run for the new scoped UI (mythic full, raid boss, or custom)
        if capturedSource.runType == "mythic" or (capturedSource.keyLevel and capturedSource.keyLevel > 0) then
            record.runType = "mythic"
            record.dungeon = capturedSource.dungeon or capturedSource.instance or instanceName
        elseif capturedSource.runType == "raid" or capturedSource.bossName then
            record.runType = "raid"
            record.raid = capturedSource.raid or capturedSource.instance or instanceName
            record.boss = capturedSource.bossName or capturedSource.buildLabel
        else
            record.runType = "custom"
        end

        table.insert(DB.runs, record)
        table.insert(CharDB.runs or {}, record)

        local function SafeFormatVal(val)
            if not val then return "0" end
            if IsSecret(val) then
                return "Pending Reload"
            end
            return BuildCompare_FormatNumber(val)
        end

        local function SafeFormatRate(val)
            if not val then return "0" end
            if IsSecret(val) then
                return "Pending Reload"
            end
            return BuildCompare_FormatNumber(val)
        end

        Print(string.format("Recorded run: %s - %s +%d | DT: %s (%s DTPS) | AvDT: %s | Heal: %s | DefCDs: %d | Build: %s",
            record.instance, record.difficulty, record.keyLevel,
            SafeFormatVal(record.dt), SafeFormatRate(record.dtps), SafeFormatVal(record.avoidableDT), SafeFormatVal(record.healing),
            #defensiveCDsUsed, record.buildLabel))

        if BuildCompareFrame and BuildCompareFrame:IsShown() then
            BuildCompare_RefreshUI()
        end
    end

    -- Delay the finalization slightly to ensure C_DamageMeter is fully populated
    if InCombatLockdown() then
        Print("Combat still active. Finalizing run as soon as you drop combat...")
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_REGEN_ENABLED")
        f:SetScript("OnEvent", function(self)
            Print("Dropped combat. Finalizing combat data in 2.0 seconds...")
            C_Timer.After(2.0, function()
                FinalizeRecord()
            end)
            self:UnregisterAllEvents()
        end)
    else
        Print("Finalizing combat data in 2.0 seconds...")
        C_Timer.After(2.0, FinalizeRecord)
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
        StartActiveRun()
        if activeRun then
            activeRun.runType = "mythic"
        end
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        EndActiveRunAndRecord("M+ complete")
    elseif event == "ENCOUNTER_START" then
        local encounterID, encounterName = ...
        if activeRun and activeRun.keyLevel and activeRun.keyLevel > 0 then
            -- Do not interrupt/segment an active M+ run on internal bosses
            return
        end
        if IsTrackableContent() then
            StartActiveRun(encounterName or "Boss")
            if activeRun then
                activeRun.runType = "raid"
                activeRun.bossName = encounterName
            end
        end
    elseif event == "ENCOUNTER_END" then
        local encounterID, encounterName, difficultyID, groupSize, success = ...
        if activeRun and activeRun.keyLevel and activeRun.keyLevel > 0 then
            -- Do not end/segment an active M+ run on boss kill
            return
        end
        if success == 1 and activeRun then
            EndActiveRunAndRecord("boss kill")
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if not playerGUID then
            playerGUID = UnitGUID("player")
        end
        -- No auto start for dummies, delves, outdoor or raid trash anymore.
        -- Only M+ and raid bosses auto-start via their specific events.
        -- Custom runs are started manually via UI button.
        -- We still let any active run (M+, boss, custom) continue tracking here.
    elseif event == "PLAYER_REGEN_ENABLED" then
        if activeRun then
            local duration = time() - activeRun.startTime
            
            -- Snapshot for manual "Record Current" fallback during a run (M+, boss, or custom).
            -- No more automatic per-pack recording for non-M+/boss content.
            BuildCompare_LastCombatSegment = {
                startTime = activeRun.startTime,
                duration = duration,
                instance = activeRun.instance,
                difficulty = activeRun.difficulty,
                keyLevel = activeRun.keyLevel,
                runType = activeRun.runType,
                bossName = activeRun.bossName,
                dungeon = activeRun.dungeon,
                raid = activeRun.raid,
                boss = activeRun.boss,
                buildLabel = activeRun.buildLabel,
                initialStats = activeRun.initialStats,
                talents = activeRun.talents,
                defensiveCDsUsed = activeRun.defensiveCDsUsed,
                damage = activeRun.damage,
                dt = activeRun.dt,
                healing = activeRun.healing,
                interrupts = activeRun.interrupts,
                dispels = activeRun.dispels,
                deaths = activeRun.deaths,
            }
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit == "player" then
            LogDefensiveCD(spellID)
            -- Only tracking defensive CDs (DPS/Healing CD lists removed for streamlining)
        end
    elseif event == "PLAYER_DEAD" then
        if activeRun then
            activeRun.deaths = (activeRun.deaths or 0) + 1
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
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("PLAYER_DEAD")
f:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == AddonName then
        BuildCompareDB = BuildCompareDB or { runs = {}, settings = {} }
        BuildCompareCharDB = BuildCompareCharDB or { runs = {} }
        DB = BuildCompareDB
        CharDB = BuildCompareCharDB
        Print("BuildCompare loaded. Use /bc to open. Auto-records on M+ complete / boss kill.")
    elseif event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        BuildCompareDB = BuildCompareDB or { runs = {}, settings = {} }
        BuildCompareCharDB = BuildCompareCharDB or { runs = {} }
        DB = BuildCompareDB
        CharDB = BuildCompareCharDB
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

-- Expose custom start/stop for UI buttons
_G.StartCustomRun = StartCustomRun
_G.StopCustomTracking = StopCustomTracking

-- Expose for mini current-run overlay (live DT/AvDT/Heal + defensive CD count during active run)
_G.BuildCompare_GetActiveRun = function() return activeRun end
