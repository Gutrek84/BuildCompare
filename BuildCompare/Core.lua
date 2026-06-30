-- BuildCompare/Core.lua
-- Main logic: DB, C_DamageMeter polling, run recording, slash commands, instance/build detection.

local AddonName, _ = ...

-- Saved DB (populated by WoW from SavedVariables in .toc)
BuildCompareDB = BuildCompareDB or { runs = {}, settings = {} }
BuildCompareCharDB = BuildCompareCharDB or { runs = {} }  -- per-char if preferred
_G.BuildCompare_SessionErrors = _G.BuildCompare_SessionErrors or {}

local DB = BuildCompareDB
local CharDB = BuildCompareCharDB

-- Active run tracking for auto-record and during-run metrics
local activeRun = nil
local currentCombat = nil
BuildCompare_LastCombatSegment = nil
local playerGUID = nil
local lastCleanStats = nil

-- Tracked Buffs & Cooldowns for Uptime Tracking
local TRACKED_BUFF_CDS = {
    -- Weapon enchants
    [369962] = "Sophic Devotion",
    [370701] = "Shadowflame Wreathe",
    [371131] = "Wafting Devotion",
    -- Cooldowns
    [31884] = "Avenging Wrath",
    [231895] = "Crusade",
    [389539] = "Sentinel",
    [107574] = "Avatar",
    [190319] = "Combustion",
    [162264] = "Metamorphosis",
    [1719] = "Recklessness",
    [114050] = "Ascendance",
    [114051] = "Ascendance",
    [114052] = "Ascendance",
    -- Bloodlust
    [2825] = "Bloodlust",
    [80353] = "Time Warp",
    [32182] = "Heroism",
}

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

-- Common DPS cooldowns (spellID -> name)
local DPS_CDS = {
    [231895] = "Crusade",
    [107574] = "Avatar",
    [190319] = "Combustion",
    [102560] = "Incarnation: Chosen of Elune",
    [194223] = "Celestial Alignment",
    [10060] = "Power Infusion",
    [2825] = "Bloodlust",
    [32182] = "Heroism",
    [47568] = "Empower Rune Weapon",
    [191427] = "Metamorphosis",
    [13750] = "Adrenaline Rush",
    [205180] = "Summon Darkglare",
    [265187] = "Summon Demonic Tyrant",
    [31884] = "Avenging Wrath", -- Paladin wings (also dps)
}

-- Common Healing cooldowns (spellID -> name)
local HEALING_CDS = {
    [740] = "Tranquility",
    [375901] = "Divine Toll",
    [31821] = "Aura Mastery",
    [64843] = "Divine Hymn",
    [62618] = "Power Word: Barrier",
    [108280] = "Healing Tide Totem",
    [98008] = "Spirit Link Totem",
    [115310] = "Revival",
    [357170] = "Rewind",
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

-- Taint-safe unbox/equal/key wrappers. Use everywhere a meter session/dur or aura numeric ID is used for decision, compare, or key.
local function SafeUnbox(val)
    if not val then return 0 end
    if IsSecret(val) then
        return BuildCompare_UnboxSecret(val)
    end
    return val
end


local function SafeSessionIDsEqual(a, b)
    if a == nil and b == nil then return true end
    if not a or not b then return false end
    -- Never let secret participate in native == for IDs (even if one side plain). Use string identity (safe, no taint, IDs are unique).
    if IsSecret(a) or IsSecret(b) then
        return tostring(a) == tostring(b)
    end
    return a == b
end

local function SafeSetAuraKey(tbl, rawKey, value)
    -- Eliminate any possibility of secret (or even plain large num auraID) as table key. Always string key for activeAuras / similar.
    if not tbl then return end
    local k = tostring(rawKey or "")
    if k == "" then return end
    tbl[k] = value
end

local function SafeGetAuraKey(tbl, rawKey)
    if not tbl then return nil end
    local k = tostring(rawKey or "")
    return tbl[k]
end

local function SafeAuraKeyDelete(tbl, rawKey)
    if not tbl then return end
    local k = tostring(rawKey or "")
    tbl[k] = nil
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

local function GetLatestSessionID()
    if C_DamageMeter and C_DamageMeter.GetAvailableCombatSessions then
        local sessions = BuildCompare_SafeCall(C_DamageMeter.GetAvailableCombatSessions, nil)
        for _, sess in ipairs(sessions or {}) do
            return sessions[#sessions].sessionID
        end
    end
    return nil
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
            local sessions = BuildCompare_SafeCall(C_DamageMeter.GetAvailableCombatSessions, nil)
            Print("Sessions count: " .. #sessions)
            for i, sInfo in ipairs(sessions or {}) do
                Print(string.format("  [%d] SessionID: %s, Name: %s, Duration: %ss", 
                    i, tostring(sInfo.sessionID), tostring(sInfo.name), tostring(sInfo.durationSeconds)))
            end
            if sessions and #sessions > 0 then
                sessionID = sessions[#sessions].sessionID
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
            if Enum and Enum.DamageMeterSessionType and Enum.DamageMeterType and C_DamageMeter.GetCombatSessionFromType then
                local dtSess = BuildCompare_SafeCall(C_DamageMeter.GetCombatSessionFromType, nil, Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.DamageTaken)
                local dSess = BuildCompare_SafeCall(C_DamageMeter.GetCombatSessionFromType, nil, Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.Damage)
                if dtSess then
                    Print("Direct Overall+DT session: totalAmount=" .. SafeFormatVal(dtSess.totalAmount) .. " sources=" .. #(dtSess.combatSources or {}))
                end
            end
        else
            Print("Native C_DamageMeter summary not available (or no activity / not 12.0+). Try in combat or after a pull. Use /dump C_DamageMeter.IsDamageMeterAvailable()")
        end

        if sessionID and C_DamageMeter.GetCombatSessionFromID then
            local idSess = BuildCompare_SafeCall(C_DamageMeter.GetCombatSessionFromID, nil, sessionID, Enum.DamageMeterType.DamageTaken)
            if idSess then
                Print("SessionFromID DT available, sources: " .. #(idSess.combatSources or {}))
            end

            -- Debug look up player's source for Enum.DamageMeterType.Interrupts
            local intSess = BuildCompare_SafeCall(C_DamageMeter.GetCombatSessionFromID, nil, sessionID, Enum.DamageMeterType.Interrupts)
            if intSess and intSess.combatSources then
                local pGUID = UnitGUID("player")
                for _, src in ipairs(intSess.combatSources) do
                    if src.isLocalPlayer or (pGUID and src.guid == pGUID) then
                        Print("Player Interrupts Source found in debug:")
                        for k, v in pairs(src) do
                            if type(v) == "table" then
                                Print(string.format("  src.%s = [table] (size: %d)", tostring(k), #v))
                                if k == "combatSpells" then
                                    for idx, spell in ipairs(v) do
                                        Print(string.format("    spell[%d]: ID=%s, name=%s, totalAmount=%s", idx, tostring(spell.spellID), tostring(spell.name), tostring(spell.totalAmount)))
                                    end
                                end
                            else
                                Print(string.format("  src.%s = %s", tostring(k), tostring(v)))
                            end
                        end
                    end
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
    elseif msg == "errors" then
        Print("Last 10 Session Errors:")
        local errs = _G.BuildCompare_SessionErrors or {}
        local startIdx = math.max(1, #errs - 9)
        for i = startIdx, #errs do
            Print(i .. ": " .. tostring(errs[i]))
        end
        if #errs == 0 then Print("No errors logged.") end
    else
        Print("Commands: /bc | /bc open | /bc record | /bc clear | /bc debug | /bc mini | /bc errors")
    end
end

-- Detect if we are in a trackable instance (M+ focus for now; extend for raids)
local function GetCurrentInstanceContext()
    local name, instanceType, difficultyID, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, instanceMapID, instanceGroupSize = BuildCompare_SafeCall(GetInstanceInfo, nil)
    local context = {name = name, difficultyID = difficultyID}
    -- Streamlined: only auto-track full Mythic+ runs (via keystone) and individual raid bosses (via ENCOUNTER).
    -- Removed all auto for dummies, delves, outdoor, raid trash, etc.
    if instanceType == "party" and difficultyID == 8 then -- Mythic Keystone
        local keystoneLevel = C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo and select(1, BuildCompare_SafeCall(C_ChallengeMode.GetActiveKeystoneInfo, 0)) or 0
        context.name = string.format("%s (+%d)", name or "Unknown", keystoneLevel)
        return true, context
    elseif difficultyID == 16 or difficultyID == 15 or difficultyID == 17 then -- M+, mythic, heroic, etc.
        return true, context
    end
    return false, context
end

local function GetHeroSpecName()
    if not C_ClassTalents or not C_ClassTalents.GetActiveConfigID then
        return "None"
    end
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        return "None"
    end
    local configInfo = C_Traits and C_Traits.GetConfigInfo and BuildCompare_SafeCall(C_Traits.GetConfigInfo, nil, configID)
    if configInfo and configInfo.treeIDs then
        for _, treeID in ipairs(configInfo.treeIDs) do
            local nodes = BuildCompare_SafeCall(C_Traits.GetTreeNodes, nil, treeID)
            if nodes then
                for _, nodeID in ipairs(nodes) do
                    local nodeInfo = BuildCompare_SafeCall(C_Traits.GetNodeInfo, nil, configID, nodeID)
                    if nodeInfo and nodeInfo.subTreeID then
                        local subTreeInfo = BuildCompare_SafeCall(C_Traits.GetSubTreeInfo, nil, configID, nodeInfo.subTreeID)
                        if subTreeInfo and subTreeInfo.isActive and subTreeInfo.name and subTreeInfo.name ~= "" then
                            return subTreeInfo.name
                        end
                    end
                end
            end
        end
    end
    return "None"
end

-- -- Snapshot relevant player stats for the "build"
local function SnapshotPlayerStats()
    local stats = {}
    
    -- Use SafeUnbox for all numeric stats that can be secret (from GetCombatRating etc in 12.0+). Prevents secret number compare taint/errors inside Snapshot and when stats used later in recording/UI diffs.
    local ok, value = pcall(GetCombatRating, CR_MASTERY)
    stats.mastery = SafeUnbox( ok and value or 0 )
    
    ok, value = pcall(GetCombatRating, CR_CRIT_MELEE)
    stats.crit = SafeUnbox( ok and value or 0 )
    
    ok, value = pcall(GetCombatRating, CR_HASTE_MELEE)
    stats.haste = SafeUnbox( ok and value or 0 )
    
    ok, value = pcall(GetCombatRating, CR_VERSATILITY_DAMAGE_DONE)
    stats.vers = SafeUnbox( ok and value or 0 )

    stats.masteryPct = SafeUnbox( GetMastery() or 0 )
    
    -- School 1 to 7 spell crit check combined with standard crit chance
    local maxCrit = SafeUnbox( tonumber(GetCritChance()) or 0 )
    for school = 1, 7 do
        local critChance = SafeUnbox( tonumber(GetSpellCritChance(school)) or 0 )
        if critChance > maxCrit then
            maxCrit = critChance
        end
    end
    stats.critPct = maxCrit
    
    stats.hastePct = SafeUnbox( GetHaste() or 0 )
    
    ok, value = pcall(GetCombatRatingBonus, CR_VERSATILITY_DAMAGE_DONE)
    stats.versPct = SafeUnbox( ok and value or 0 )

    stats.dodgePct = SafeUnbox( GetDodgeChance() or 0 )
    stats.parryPct = SafeUnbox( GetParryChance() or 0 )
    stats.blockPct = SafeUnbox( GetBlockChance() or 0 )
    -- Snapshot Primary Stats
    stats.strength = SafeUnbox( BuildCompare_SafeCall(UnitStat, 0, "player", 1) or 0 )
    stats.stamina = SafeUnbox( BuildCompare_SafeCall(UnitStat, 0, "player", 3) or 0 )
    stats.agility = SafeUnbox( BuildCompare_SafeCall(UnitStat, 0, "player", 2) or 0 )
    stats.intellect = SafeUnbox( BuildCompare_SafeCall(UnitStat, 0, "player", 4) or 0 )
    stats.mastery = SafeUnbox( GetMasteryEffect() or 0 )
    local _, equippedItemLevel = GetAverageItemLevel()
    stats.ilvl = SafeUnbox(equippedItemLevel or 0)

    stats.class = UnitClass("player") or "Unknown"
    
    stats.spec = "None"
    if GetSpecialization then
        local specIndex = GetSpecialization()
        if specIndex then
            local specID, specName = GetSpecializationInfo(specIndex)
            stats.spec = specName or "None"
        end
    end

    stats.heroSpec = GetHeroSpecName()

    return stats
end

-- Out-of-combat stats caching
local statCacheFrame = CreateFrame("Frame")
statCacheFrame:RegisterEvent("PLAYER_LOGIN")
statCacheFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
statCacheFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
statCacheFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
statCacheFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
statCacheFrame:SetScript("OnEvent", function(self, event, ...)
    if not InCombatLockdown() then
        C_Timer.After(0.5, function()
            if not InCombatLockdown() then
                lastCleanStats = SnapshotPlayerStats()
            end
        end)
    end
end)

local MAJOR_EXTERNAL_BUFFS = {
    [2825] = true,   -- Bloodlust
    [32182] = true,  -- Heroism
    [80353] = true,  -- Time Warp
    [264667] = true, -- Primal Rage
    [10060] = true,  -- Power Infusion
}

local RAID_BUFFS = {
    [21562] = true,  -- Power Word: Fortitude
    [1126] = true,   -- Mark of the Wild
    [1459] = true,   -- Arcane Intellect
    [364314] = true, -- Blessing of the Bronze
    [465] = true,    -- Devotion Aura
    [183435] = true, -- Retribution Aura
    [6673] = true,   -- Battle Shout
    [462854] = true, -- Skyfury
}

local function ShouldTrackAura(aura)
    if not aura then return false end
    local spellID = SafeUnbox(aura.spellId)
    if aura.isHelpful and (MAJOR_EXTERNAL_BUFFS[spellID] or RAID_BUFFS[spellID]) then
        return true
    end
    local duration = SafeUnbox(aura.duration)
    return aura.isFromPlayerOrPlayerPet and duration and duration > 0
end

local auraTrackingSuspended = false

local function ReconcileActiveAuras()
    -- All activeAuras keys now strings via Safe* helpers. Eliminates secret-key indexing risk entirely (and future-proofs if auraInstanceID ever protected).
    if not activeRun then return end
    activeRun.activeAuras = activeRun.activeAuras or {}
    activeRun.buffDurations = activeRun.buffDurations or {}
    
    local now = GetTime()
    local currentAuras = {}
    local index = 1
    while true do
        local aura = C_UnitAuras.GetAuraDataByIndex("player", index, "HELPFUL")
        if not aura then break end
        
        if ShouldTrackAura(aura) then
            local instID = aura.auraInstanceID or aura.auraInstanceId
            if instID then
                SafeSetAuraKey(currentAuras, instID, SafeUnbox(aura.spellId))
            end
        end
        index = index + 1
    end
    
    -- Check for removals
    for instanceID, cache in pairs(activeRun.activeAuras) do
        local cache = SafeGetAuraKey(activeRun.activeAuras, instanceID)
        if instanceID and instanceID ~= "" then
            if not SafeGetAuraKey(currentAuras, instanceID) then
                local duration = now - cache.startTime
                if duration > 0 then
                    local unboxedSpellID = SafeUnbox(cache.spellID)
                    activeRun.buffDurations[unboxedSpellID] = (activeRun.buffDurations[unboxedSpellID] or 0) + duration
                end
                SafeAuraKeyDelete(activeRun.activeAuras, instanceID)
            end
        end
    end
    
    -- Check for additions
    for instanceID, spellID in pairs(currentAuras) do
        if not SafeGetAuraKey(activeRun.activeAuras, instanceID) then
            SafeSetAuraKey(activeRun.activeAuras, instanceID, {
                spellID = SafeUnbox(spellID),
                startTime = now
            })
        end
    end
end

local function CheckWeaponEnchants()
    -- All activeAuras keys now strings via Safe* helpers. Eliminates secret-key indexing risk entirely (and future-proofs if auraInstanceID ever protected).
    if not activeRun then return end
    activeRun.activeAuras = activeRun.activeAuras or {}
    activeRun.buffDurations = activeRun.buffDurations or {}
    
    local now = GetTime()
    local hasMH, mhExpire, mhCharges, mhEnchantID, hasOH, ohExpire, ohCharges, ohEnchantID = GetWeaponEnchantInfo()
    
    -- Unbox enchant IDs using SafeUnbox before storing them.
    mhEnchantID = mhEnchantID and SafeUnbox(mhEnchantID)
    ohEnchantID = ohEnchantID and SafeUnbox(ohEnchantID)
    
    -- Process Main Hand
    local mhCache = SafeGetAuraKey(activeRun.activeAuras, "mh_imbue")
    if hasMH and mhEnchantID then
        if mhCache then
            local mhCacheSpellID = SafeUnbox(mhCache.spellID)
            if mhCacheSpellID ~= mhEnchantID then
                local duration = now - mhCache.startTime
                if duration > 0 then
                    activeRun.buffDurations[mhCacheSpellID] = (activeRun.buffDurations[mhCacheSpellID] or 0) + duration
                end
                SafeSetAuraKey(activeRun.activeAuras, "mh_imbue", {
                    spellID = mhEnchantID,
                    startTime = now
                })
            end
        else
            SafeSetAuraKey(activeRun.activeAuras, "mh_imbue", {
                spellID = mhEnchantID,
                startTime = now
            })
        end
    else
        if mhCache then
            local duration = now - mhCache.startTime
            if duration > 0 then
                local mhCacheSpellID = SafeUnbox(mhCache.spellID)
                activeRun.buffDurations[mhCacheSpellID] = (activeRun.buffDurations[mhCacheSpellID] or 0) + duration
            end
            SafeAuraKeyDelete(activeRun.activeAuras, "mh_imbue")
        end
    end
    
    -- Process Off Hand
    local ohCache = SafeGetAuraKey(activeRun.activeAuras, "oh_imbue")
    if hasOH and ohEnchantID then
        if ohCache then
            local ohCacheSpellID = SafeUnbox(ohCache.spellID)
            if ohCacheSpellID ~= ohEnchantID then
                local duration = now - ohCache.startTime
                if duration > 0 then
                    activeRun.buffDurations[ohCacheSpellID] = (activeRun.buffDurations[ohCacheSpellID] or 0) + duration
                end
                SafeSetAuraKey(activeRun.activeAuras, "oh_imbue", {
                    spellID = ohEnchantID,
                    startTime = now
                })
            end
        else
            SafeSetAuraKey(activeRun.activeAuras, "oh_imbue", {
                spellID = ohEnchantID,
                startTime = now
            })
        end
    else
        if ohCache then
            local duration = now - ohCache.startTime
            if duration > 0 then
                local ohCacheSpellID = SafeUnbox(ohCache.spellID)
                activeRun.buffDurations[ohCacheSpellID] = (activeRun.buffDurations[ohCacheSpellID] or 0) + duration
            end
            SafeAuraKeyDelete(activeRun.activeAuras, "oh_imbue")
        end
    end
end

local function FlushActiveAuras(endTime)
    -- All activeAuras keys now strings via Safe* helpers. Eliminates secret-key indexing risk entirely (and future-proofs if auraInstanceID ever protected).
    if not activeRun or not activeRun.activeAuras then return end
    local now = endTime or GetTime()
    for instanceID, cache in pairs(activeRun.activeAuras) do
        local duration = now - cache.startTime
        if duration > 0 then
            local unboxedSpellID = SafeUnbox(cache.spellID)
            activeRun.buffDurations[unboxedSpellID] = (activeRun.buffDurations[unboxedSpellID] or 0) + duration
        end
    end
    activeRun.activeAuras = {}
end

-- Start tracking an active run (called on M+ start or boss pull)
local function StartActiveRun(buildLabel)
    if not IsTrackableContent() then return end

    local success, instanceName, diffName, keyLevel = IsTrackableContent()
    
    local group = {}
    local numMembers = GetNumGroupMembers()
    if numMembers > 0 then
        local prefix = IsInRaid() and "raid" or "party"
        local limit = IsInRaid() and numMembers or (numMembers - 1)
        
        -- Player
        local pSpec = "Unknown"
        if GetSpecialization and GetSpecialization() then
            local _, specName = GetSpecializationInfo(GetSpecialization())
            pSpec = specName or "Unknown"
        end
        table.insert(group, {
            class = select(2, UnitClass("player")),
            role = UnitGroupRolesAssigned("player") or "NONE",
            spec = pSpec,
            isPlayer = true,
        })
        
        -- Members
        for i = 1, limit do
            local unit = prefix .. i
            if UnitExists(unit) then
                table.insert(group, {
                    class = select(2, UnitClass(unit)),
                    role = UnitGroupRolesAssigned(unit) or "NONE",
                    spec = "Unknown",
                })
            end
        end
    end
    -- Sort group: Tank first, then Healer, then DPS (alphabetically by class within roles)
    table.sort(group, function(x, y)
        local roleOrder = { TANK = 1, HEALER = 2, DAMAGER = 3, NONE = 4 }
        local ox = roleOrder[x.role] or 4
        local oy = roleOrder[y.role] or 4
        if ox ~= oy then return ox < oy end
        return (x.class or "") < (y.class or "")
    end)

    activeRun = {
        startTime = time(),
        startGetTime = GetTime(),
        initialSessionID = GetLatestSessionID(),
        startedInCombat = InCombatLockdown(),
        hadCombat = InCombatLockdown(),
        instance = instanceName or "Unknown",
        difficulty = diffName or "Unknown",
        keyLevel = keyLevel or 0,
        buildLabel = buildLabel or "Auto",
        initialStats = lastCleanStats or SnapshotPlayerStats(),
        talents = BuildCompare_SnapshotTalents(),
        defensiveCDsUsed = {},
        dpsCDsUsed = {},
        healingCDsUsed = {},
        buffDurations = {},
        activeAuras = {},
        damage = 0,
        dt = 0,
        healing = 0,
        interrupts = 0,
        dispels = 0,
        deaths = 0,
        group = group,
    }
    ReconcileActiveAuras()
    CheckWeaponEnchants()
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

            local group = {}
            local numMembers = GetNumGroupMembers()
            if numMembers > 0 then
                local prefix = IsInRaid() or "party"
                local limit = IsInRaid() and numMembers or (numMembers - 1)
                
                -- Player
                local pSpec = "Unknown"
                if GetSpecialization and GetSpecialization() then
                    local _, specName = GetSpecializationInfo(GetSpecialization())
                    pSpec = specName or "Unknown"
                end
                table.insert(group, {
                    class = select(2, UnitClass("player")),
                    role = UnitGroupRolesAssigned("player") or "NONE",
                    spec = pSpec,
                    isPlayer = true,
                })
                
                -- Members
                for i = 1, limit do
                    local unit = prefix .. i
                    if UnitExists(unit) then
                        table.insert(group, {
                            class = select(2, UnitClass(unit)),
                            role = UnitGroupRolesAssigned(unit) or "NONE",
                            spec = "Unknown",
                        })
                    end
                end
            end
            -- Sort group: Tank first, then Healer, then DPS (alphabetically by class within roles)
            table.sort(group, function(x, y)
                local roleOrder = { TANK = 1, HEALER = 2, DAMAGER = 3, NONE = 4 }
                local ox = roleOrder[x.role] or 4
                local oy = roleOrder[y.role] or 4
                if ox ~= oy then return ox < oy end
                return (x.class or "") < (y.class or "")
            end)

            activeRun = {
                startTime = time(),
                startGetTime = GetTime(),
                initialSessionID = GetLatestSessionID(),
                startedInCombat = InCombatLockdown(),
                hadCombat = InCombatLockdown(),
                instance = "Custom",
                difficulty = "Custom",
                keyLevel = 0,
                runType = "custom",
                buildLabel = label,
                initialStats = lastCleanStats or SnapshotPlayerStats(),
                talents = BuildCompare_SnapshotTalents(),
                defensiveCDsUsed = {},
                dpsCDsUsed = {},
                healingCDsUsed = {},
                buffDurations = {},
                activeAuras = {},
                damage = 0,
                dt = 0,
                healing = 0,
                interrupts = 0,
                dispels = 0,
                deaths = 0,
                group = group,
            }
            ReconcileActiveAuras()
            CheckWeaponEnchants()
            Print("Custom tracking started: " .. label .. ". Use Stop button or /bc record when done.")
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
    }
    StaticPopup_Show("BUILDCOMPARE_CUSTOM_LABEL")
end

StaticPopupDialogs["BUILDCOMPARE_CONFIRM_DELETE"] = {
    text = "Are you sure you want to delete the run '%s'?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, run)
        if run and run.id then
            BuildCompare_DeleteRun(run.id)
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

local function StopCustomTracking()
    if activeRun and activeRun.runType == "custom" then
        BuildCompare_RecordCurrentRun(activeRun.buildLabel)
    else
        Print("No active custom run to stop.")
    end
end

-- Log a CD usage (called from event handlers)
local function LogCD(spellId, spellName)
    if not activeRun then return end

    local isDef = DEFENSIVE_CDS[spellId]
    local isDps = DPS_CDS[spellId]
    local isHeal = HEALING_CDS[spellId]

    if not (isDef or isDps or isHeal) then return end

    local name = spellName or isDef or isDps or isHeal
    local cd = {
        spellId = spellId,
        name = name,
        timestamp = time(),
    }

    if isDef then
        table.insert(activeRun.defensiveCDsUsed, cd)
    end
    if isDps then
        table.insert(activeRun.dpsCDsUsed, cd)
    end
    if isHeal then
        table.insert(activeRun.healingCDsUsed, cd)
    end
end

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
local function GetBestSessionIDForCurrentPull(initialSessionID, startedInCombat, hadCombat)
    if not C_DamageMeter or not C_DamageMeter.GetAvailableCombatSessions then
        return nil
    end
    local sessions = BuildCompare_SafeCall(C_DamageMeter.GetAvailableCombatSessions, nil) or {}
    if #sessions == 0 then return nil end

    local latest = sessions[#sessions]

    if latest and SafeSessionIDsEqual(latest.sessionID, initialSessionID) then
        if startedInCombat or hadCombat then
            return latest.sessionID
        end
        return nil
    end

    -- Walk from the end (most recent first)
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        if SafeSessionIDsEqual(s.sessionID, initialSessionID) then
            -- Reached the session that was active when we started tracking, anything before/at this is old
            break
        end
        local d = s.durationSeconds
        d = SafeUnbox(d)
        if IsSecret(d) then
            return s.sessionID
        end
        if d and d >= 2 and d <= 300 then
            return s.sessionID
        end
    end

    local latestID = sessions[#sessions].sessionID
    if not SafeSessionIDsEqual(latestID, initialSessionID) then
        return latestID
    end
    return nil
    -- Note: returned sessionID may be secret (for direct pass to C_DamageMeter.GetCombatSessionFromID etc). Our matching logic above now uses SafeSessionIDsEqual to avoid taint in compares. Per plan Step C.
end

local function GetActorTotalFromSpells(sessionID, dmType)
    if not C_DamageMeter or not C_DamageMeter.GetCombatSessionSourceFromID then
        return nil
    end
    local pGUID = UnitGUID("player")
    if not pGUID then return nil end
    local source = BuildCompare_SafeCall(C_DamageMeter.GetCombatSessionSourceFromID, nil, sessionID, dmType, pGUID)
    if source and source.combatSpells then
        local sum = 0
        for _, spell in ipairs(source.combatSpells) do
            sum = sum + (spell.totalAmount or 0)
        end
        return sum
    end
    return nil
end

local function GetActorTotalFromSpellsByType(sessionType, dmType)
    if not C_DamageMeter or not C_DamageMeter.GetCombatSessionSourceFromType then
        return nil
    end
    local pGUID = UnitGUID("player")
    if not pGUID then return nil end
    local source = BuildCompare_SafeCall(C_DamageMeter.GetCombatSessionSourceFromType, nil, sessionType, dmType, pGUID)
    if source and source.combatSpells then
        local sum = 0
        for _, spell in ipairs(source.combatSpells) do
            sum = sum + (spell.totalAmount or 0)
        end
        return sum
    end
    return nil
end

-- Native C_DamageMeter data fetch (primary/only source for 12.0+ per AGENTS.md).
-- Pure direct from WoW APIs, no external addon dependency.
-- Returns summary (with hasActivity) or nil.
-- preferCurrent: when true (non-M+ / solo dummy / short boss), we try to lock to a specific recent short sessionID
-- (instead of just preferring Current type). This ensures DT, Heal, AvoidableDT etc. all come from the *same* pull.
local function GetNativeMeterData(preferCurrent, initialSessionID, startedInCombat, hadCombat)
    if not C_DamageMeter or not C_DamageMeter.IsDamageMeterAvailable then
        return nil
    end
    local avail, _reason = BuildCompare_SafeCall(C_DamageMeter.IsDamageMeterAvailable, false)
    if not avail then return nil end
    if not Enum or not Enum.DamageMeterSessionType or not Enum.DamageMeterType then
        return nil
    end

    -- For short content, try to get one consistent sessionID from the available list.
    -- Then we'll query every metric type from that exact ID.
    -- Note: lockedSessionID may be a secret value (from C_DamageMeter); it is ONLY passed raw to C_DamageMeter.GetCombatSessionFromID etc in the preferCurrent path. No comparisons or table key use on it here (Safe* used upstream in GetBest).
    local lockedSessionID = preferCurrent and GetBestSessionIDForCurrentPull(initialSessionID, startedInCombat, hadCombat) or nil

    local function fetchForType(dmType)
        if preferCurrent then
            if lockedSessionID then
                if C_DamageMeter.GetCombatSessionFromID then
                    local sess = BuildCompare_SafeCall(C_DamageMeter.GetCombatSessionFromID, nil, lockedSessionID, dmType)
                    if sess and sess.combatSources and #sess.combatSources > 0 then
                        for _, src in ipairs(sess.combatSources) do
                            if src.isLocalPlayer then
                                local totalVal = BuildCompare_UnboxSecret(src.totalAmount)
                                if dmType == Enum.DamageMeterType.Interrupts or dmType == Enum.DamageMeterType.Dispels or dmType == Enum.DamageMeterType.Deaths then
                                    local spellSum = GetActorTotalFromSpells(lockedSessionID, dmType)
                                    if spellSum ~= nil then
                                        totalVal = BuildCompare_UnboxSecret(spellSum)
                                    end
                                end
                                return {
                                    total = totalVal,
                                    perSec = BuildCompare_UnboxSecret(src.amountPerSecond),
                                    duration = BuildCompare_UnboxSecret(sess.durationSeconds or 0),
                                }
                            end
                        end
                    end
                end
            end
            return nil
        end

        -- Fallback / M+ path: use FromType with smart order
        local sessionOrder = {Enum.DamageMeterSessionType.Overall, Enum.DamageMeterSessionType.Current}

        for _, st in ipairs(sessionOrder) do
            local sess = BuildCompare_SafeCall(C_DamageMeter.GetCombatSessionFromType, nil, st, dmType)
            if sess and sess.combatSources and #sess.combatSources > 0 then
                for _, src in ipairs(sess.combatSources) do
                    if src.isLocalPlayer then
                        local totalVal = BuildCompare_UnboxSecret(src.totalAmount)
                        if dmType == Enum.DamageMeterType.Interrupts or dmType == Enum.DamageMeterType.Dispels or dmType == Enum.DamageMeterType.Deaths then
                            local spellSum = GetActorTotalFromSpellsByType(st, dmType)
                            if spellSum ~= nil then
                                totalVal = BuildCompare_UnboxSecret(spellSum)
                            end
                        end
                        return {
                            total = totalVal,
                            perSec = BuildCompare_UnboxSecret(src.amountPerSecond),
                            duration = BuildCompare_UnboxSecret(sess.durationSeconds or 0),
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
    -- Fixed by SafeUnbox + always-plain dur locals + SafeSessionIDsEqual. No secret participates in any == or key op.
    local function getSafeDur(d)
        if not d then return 0 end
        local u = SafeUnbox(d)
        if IsSecret(d) or u == 0 then return 0 end   -- note: check secret on *original* for intent, but return plain 0
        return u
    end

    -- dur is *always* a plain Lua number here. All meter .duration values were unboxed at source in fetch returns.
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
local function GetPlayerMeterSummary(isOverall, runStartTime, initialSessionID, startedInCombat, hadCombat)
    -- For M+ (keyLevel > 0) we want the Overall full-run numbers (the type-based Overall is usually correct).
    -- For dummy/solo/short content we compute a lockedSessionID (most recent short session from GetAvailableCombatSessions)
    -- and query *every* metric type from that exact same sessionID. This prevents the previous problem where
    -- DT might come from Current but Healing/AvoidableDT fell back to a huge cumulative Overall (now prevented by locked sessionID for short runs).
    local preferCurrent = not isOverall
    local native = GetNativeMeterData(preferCurrent, initialSessionID, startedInCombat, hadCombat)
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
        startGetTime = recordSource.startGetTime,
        initialSessionID = recordSource.initialSessionID,
        startedInCombat = recordSource.startedInCombat,
        hadCombat = recordSource.hadCombat,
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
        dpsCDsUsed = recordSource.dpsCDsUsed,
        healingCDsUsed = recordSource.healingCDsUsed,
        damage = recordSource.damage,
        dt = recordSource.dt,
        healing = recordSource.healing,
        interrupts = recordSource.interrupts,
        dispels = recordSource.dispels,
        deaths = recordSource.deaths,
        buffDurations = recordSource.buffDurations,
        activeAuras = recordSource.activeAuras,
        group = recordSource.group,
    }

    -- Clear active run and combat segment immediately to allow new runs to start
    activeRun = nil
    BuildCompare_LastCombatSegment = nil

    local function FinalizeRecord()
        -- duration/runDuration now guaranteed plain number before any comparison. Eliminates all secret-number compare paths for run lengths.
        local duration = SafeUnbox(capturedSource.duration or 0)
        if duration == 0 and capturedSource.startGetTime then
            duration = GetTime() - capturedSource.startGetTime
        elseif duration == 0 and capturedSource.startTime then
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
        local dpsCDsUsed = capturedSource.dpsCDsUsed or {}
        local healingCDsUsed = capturedSource.healingCDsUsed or {}
        local hasActivity = false

        -- Fetch the combat summary directly from the built-in C_DamageMeter (pure WoW, no external addons)
        local isOverall = (capturedSource.keyLevel and capturedSource.keyLevel > 0)
        local meterSummary = GetPlayerMeterSummary(isOverall, capturedSource.startTime, capturedSource.initialSessionID, capturedSource.startedInCombat, capturedSource.hadCombat)
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

        if capturedSource.runType == "custom" and dt == 0 and damage == 0 and healing == 0 then
            Print("No combat activity recorded. Custom run not saved.")
            return
        end

        -- (Removed solo auto-run logic per narrowed scope; no more per-pack dummy/delve/outdoor records)

        local buildLabel = optionalLabel or capturedSource.buildLabel or ("Build " .. date("%H%M"))
        local stats = capturedSource.initialStats or lastCleanStats or SnapshotPlayerStats()
        local ts = time()

        -- Calculate buff/cooldown uptimes
        local buffUptimes = {}
        local runDuration = SafeUnbox(duration)
        if runDuration == 0 and capturedSource.startGetTime then
            runDuration = GetTime() - capturedSource.startGetTime
        elseif runDuration == 0 and capturedSource.startTime then
            runDuration = time() - capturedSource.startTime
        end
        if runDuration <= 0 then runDuration = 1 end

        local bDurations = capturedSource.buffDurations or {}
        local actAuras = capturedSource.activeAuras or {}
        local now = GetTime()
        for instanceID, cache in pairs(actAuras) do
            local dur = now - cache.startTime
            if dur > 0 then
                local unboxedSpellID = SafeUnbox(cache.spellID)
                bDurations[unboxedSpellID] = (bDurations[unboxedSpellID] or 0) + dur
            end
        end
        for spellID, dur in pairs(bDurations) do
            local pct = (dur / runDuration) * 100
            if pct > 100 then pct = 100 end
            buffUptimes[SafeUnbox(spellID)] = pct
        end

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
            dpsCDsUsed = dpsCDsUsed,
            healingCDsUsed = healingCDsUsed,
            buffUptimes = buffUptimes,
            meterSessionId = isOverall and "overall" or "current",
            group = capturedSource.group,
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

        if record.keyLevel and record.keyLevel > 0 then
            Print(string.format("Recorded run: %s - %s +%d", record.instance, record.difficulty, record.keyLevel))
        else
            Print(string.format("Recorded run: %s - %s", record.instance, record.difficulty))
        end


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
        if activeRun then
            activeRun.hadCombat = true
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
                startGetTime = activeRun.startGetTime,
                initialSessionID = activeRun.initialSessionID,
                startedInCombat = activeRun.startedInCombat,
                hadCombat = activeRun.hadCombat,
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
                dpsCDsUsed = activeRun.dpsCDsUsed,
                healingCDsUsed = activeRun.healingCDsUsed,
                damage = activeRun.damage,
                dt = activeRun.dt,
                healing = activeRun.healing,
                interrupts = activeRun.interrupts,
                dispels = activeRun.dispels,
                deaths = activeRun.deaths,
                buffDurations = activeRun.buffDurations,
                activeAuras = activeRun.activeAuras,
                group = activeRun.group,
            }
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit == "player" then
            LogCD(SafeUnbox(spellID))
        end
    elseif event == "PLAYER_DEAD" then
        if activeRun then
            activeRun.deaths = (activeRun.deaths or 0) + 1
        end
    elseif event == "UNIT_AURA" then
        -- All activeAuras keys now strings via Safe* helpers. Eliminates secret-key indexing risk entirely (and future-proofs if auraInstanceID ever protected).
        local unit, updateInfo = ...
        if unit ~= "player" then return end
        if not activeRun then return end
        if auraTrackingSuspended then return end
        
        activeRun.activeAuras = activeRun.activeAuras or {}
        activeRun.buffDurations = activeRun.buffDurations or {}
        
        if updateInfo and not updateInfo.isFullUpdate then
            -- Removals
            if updateInfo.removedAuraInstanceIDs then
                local now = GetTime()
                for _, instanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
                    local cache = SafeGetAuraKey(activeRun.activeAuras, instanceID)
                    if cache then
                        local duration = now - cache.startTime
                        if duration > 0 then
                            local unboxedSpellID = SafeUnbox(cache.spellID)
                            activeRun.buffDurations[unboxedSpellID] = (activeRun.buffDurations[unboxedSpellID] or 0) + duration
                        end
                        SafeAuraKeyDelete(activeRun.activeAuras, instanceID)
                    end
                end
            end
            -- Additions
            if updateInfo.addedAuras then
                local now = GetTime()
                for _, aura in ipairs(updateInfo.addedAuras) do
                    if aura.isHelpful and ShouldTrackAura(aura) then
                        local instID = aura.auraInstanceID or aura.auraInstanceId
                        if instID then
                            SafeSetAuraKey(activeRun.activeAuras, instID, {
                                spellID = SafeUnbox(aura.spellId),
                                startTime = now
                            })
                        end
                    end
                end
            end
        else
            ReconcileActiveAuras()
        end
    elseif event == "PLAYER_LEAVING_WORLD" then
        auraTrackingSuspended = true
        FlushActiveAuras()
    elseif event == "PLAYER_ENTERING_WORLD" then
        auraTrackingSuspended = false
        if activeRun then
            activeRun.activeAuras = {}
            ReconcileActiveAuras()
            CheckWeaponEnchants()
        end
    elseif event == "UNIT_INVENTORY_CHANGED" then
        local unit = ...
        if unit == "player" then
            CheckWeaponEnchants()
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
f:RegisterEvent("UNIT_AURA")
f:RegisterEvent("PLAYER_LEAVING_WORLD")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("UNIT_INVENTORY_CHANGED")
f:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == AddonName then
        BuildCompareDB = BuildCompareDB or { runs = {}, settings = {} }
        BuildCompareCharDB = BuildCompareCharDB or { runs = {} }
        DB = BuildCompareDB
        CharDB = BuildCompareCharDB
        
        if not DB.schemaVersion or DB.schemaVersion < 1 then
            DB.schemaVersion = 1
            for _, run in ipairs(DB.runs or {}) do
                run.damageTaken = run.damageTaken or 0
                run.healingDone = run.healingDone or 0
                run.dps = run.dps or 0
            end
            Print("BuildCompare database schema updated to version 1.")
        end

        Print("BuildCompare loaded. Use /bc to open. Auto-records on M+ complete / boss kill.")
    elseif event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        BuildCompareDB = BuildCompareDB or { runs = {}, settings = {} }
        BuildCompareCharDB = BuildCompareCharDB or { runs = {} }
        DB = BuildCompareDB
        CharDB = BuildCompareCharDB
        DB.runs = DB.runs or {}
        CharDB.runs = CharDB.runs or {}
        BuildCompareDB.settings = BuildCompareDB.settings or {}
        BuildCompareDB.settings.collapsedSections = BuildCompareDB.settings.collapsedSections or {}
        BuildCompareDB.settings.minimapAngle = BuildCompareDB.settings.minimapAngle or 45
        if BuildCompare_CreateMinimapButton then
            BuildCompare_CreateMinimapButton()
        end
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

function BuildCompare_IsActiveCooldown(spellID)
    local numID = tonumber(spellID)
    if not numID then return false end
    return (DEFENSIVE_CDS[numID] ~= nil) or (DPS_CDS[numID] ~= nil) or (HEALING_CDS[numID] ~= nil) or (MAJOR_EXTERNAL_BUFFS[numID] ~= nil)
end

function BuildCompare_DeleteRun(runID)
    if not runID then return end
    if DB and DB.runs then
        for i = #DB.runs, 1, -1 do
            if DB.runs[i].id == runID then
                table.remove(DB.runs, i)
            end
        end
    end
    if CharDB and CharDB.runs then
        for i = #CharDB.runs, 1, -1 do
            if CharDB.runs[i].id == runID then
                table.remove(CharDB.runs, i)
            end
        end
    end
    Print("Run deleted successfully.")
    if BuildCompareFrame and BuildCompareFrame:IsShown() then
        BuildCompare_RefreshUI()
    end
end
_G.BuildCompare_DeleteRun = BuildCompare_DeleteRun

local function BuildCompare_SaveRunNote(runID, note)
    if not runID then return end
    if DB and DB.runs then
        for i = 1, #DB.runs do
            if DB.runs[i].id == runID then
                DB.runs[i].note = note
            end
        end
    end
    if CharDB and CharDB.runs then
        for i = 1, #CharDB.runs do
            if CharDB.runs[i].id == runID then
                CharDB.runs[i].note = note
            end
        end
    end
    Print("Note saved successfully.")
    if BuildCompareFrame and BuildCompareFrame:IsShown() then
        BuildCompare_RefreshUI()
    end
end
_G.BuildCompare_SaveRunNote = BuildCompare_SaveRunNote

StaticPopupDialogs["BUILDCOMPARE_EDIT_NOTE"] = {
    text = "Enter note for this run:",
    button1 = "Save",
    button2 = "Cancel",
    hasEditBox = 1,
    OnShow = function(self, run)
        local eb = self.EditBox or _G[self:GetName().."EditBox"]
        if eb then
            eb:SetText(run and run.note or "")
            eb:SetFocus()
            eb:HighlightText()
        end
    end,
    OnAccept = function(self, run)
        local eb = self.EditBox or _G[self:GetName().."EditBox"]
        local note = eb and eb:GetText() or ""
        BuildCompare_SaveRunNote(run.id, note)
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}
