-- BuildCompare/UI.lua
-- In-game GUI that mimics a damage meter with comparison readouts and % diffs.

local AddonName, _ = ...

local SEASON_1_MYTHICS = (BuildCompareData and BuildCompareData.SEASON_1_MYTHICS) or {
    "Magisters' Terrace",
    "Maisara Caverns",
    "Nexus-Point Xenas",
    "Windrunner Spire",
    "Algeth'ar Academy",
    "Pit of Saron",
    "Seat of the Triumvirate",
    "Skyreach"
}
local SEASON_1_RAIDS = (BuildCompareData and BuildCompareData.SEASON_1_RAIDS) or {
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

local currentMode = "mythic"  -- "mythic", "raid", "custom"
local currentDungeon = nil
local currentRaid = nil
local currentBoss = nil

local issecretvalue = issecretvalue or function() return false end
local function IsSecret(val)
    return issecretvalue(val)
end

-- Used for SetFormattedText in secure UI widgets (keeps secret value intact so the engine can render it)
-- Enhanced for issue #2 (tracking list + mini only): for non-secrets returns clean k/m abbr (via BuildCompare_FormatNumber with .1 precision); for IsSecret returns the raw val unchanged so SetFormattedText lets the engine render abbreviated (1.5m, 40.5k etc). This ensures DT/AvDT/Dmg/Heal (and rates) always abbreviated in saved-runs list rows and mini overlay even when values from C_DamageMeter/GetNativeMeterData are secret protected. Uses local IsSecret (taint-safe). SafeFormatVal/ToSafeString unchanged (for other paths).
local function SafeDisplayVal(val)
    if not val then return "0" end
    if IsSecret(val) then
        return _G.AbbreviateNumbers and _G.AbbreviateNumbers(val) or val
    end
    return BuildCompare_FormatNumber(val)
end

-- Used for standard string formatting and concatenation in tainted Lua (prevents crashes)
local function SafeFormatVal(val)
    if not val then return "0" end
    if IsSecret(val) then
        return "Pending Reload"
    end
    return BuildCompare_FormatNumber(val)
end

-- Safe string for use in table.concat / manual string building in compare panel etc.
-- Secrets cannot be concatenated directly without taint or "invalid value (secret)" errors.
local function ToSafeString(val)
    if IsSecret(val) then
        return "Pending"
    end
    if type(val) == "string" then
        return val
    end
    return tostring(val)
end

local function MakeScrollFrameTaintSafe(scrollFrame)
    scrollFrame:SetScript("OnScrollRangeChanged", function(self, xrange, yrange)
        local scrollbar = self.ScrollBar or (self:GetName() and _G[self:GetName() .. "ScrollBar"])
        if not scrollbar then return end

        local scrollChild = self:GetScrollChild()
        if not scrollChild then return end

        local childHeight = scrollChild:GetHeight() or 0
        local frameHeight = self:GetHeight() or 0
        local y = childHeight - frameHeight
        if y < 0 then y = 0 end

        scrollbar:SetMinMaxValues(0, y)
        if y > 0 then
            scrollbar:Enable()
        else
            scrollbar:Disable()
        end
    end)
end

local frame = nil
local scroll = nil
local content = nil

local selectedForCompare = {}  -- run ids

local function CreateBarRow(parent, index, run)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(40)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4 - (index-1)*44)
    row:SetPoint("RIGHT", parent, "RIGHT", -4, 0)

    -- Select for compare button (left side)
    row.selectBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.selectBtn:SetSize(50, 24)
    row.selectBtn:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.selectBtn:SetText("Sel")
    row.selectBtn:SetScript("OnClick", function()
        if not run or not run.id then return end
        local foundIndex = nil
        for i, r in ipairs(selectedForCompare) do
            if r.id == run.id then
                foundIndex = i
                break
            end
        end
        if foundIndex then
            table.remove(selectedForCompare, foundIndex)
        else
            if #selectedForCompare >= 2 then
                selectedForCompare = {}
            end
            table.insert(selectedForCompare, run)
        end
        BuildCompare_RefreshUI()  -- refresh to update compare panel
    end)

    -- Top Line: Run name and build label
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("TOPLEFT", row, "TOPLEFT", 55, -2)
    row.label:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetText(BuildCompare_GetRunLabel(run) or run.buildLabel or "?")

    -- Bottom Line: Background bar (DT)
    row.dtBar = CreateFrame("StatusBar", nil, row)
    row.dtBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.dtBar:SetStatusBarColor(0.8, 0.2, 0.2)  -- red-ish for damage taken
    row.dtBar:SetMinMaxValues(0, 100)
    row.dtBar:SetValue(50)
    row.dtBar:SetPoint("TOPLEFT", row, "TOPLEFT", 55, -18)
    row.dtBar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, -4)

    -- Text overlay on bar
    row.text = row.dtBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", row.dtBar, "LEFT", 4, 0)
    row.text:SetText("DT: " .. BuildCompare_FormatNumber(0) .. " | Heal: " .. BuildCompare_FormatNumber(0))

    -- Store run ref
    row.run = run

    return row
end

-- Helper for simple dropdown menus (no external libs, streamlined)
local function ShowSimpleDropdown(anchor, options, onSelect)
    if not anchor or not options or #options == 0 then return end
    if type(onSelect) ~= "function" then
        onSelect = function() end
    end
    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left=4, right=4, top=4, bottom=4 }
    })
    menu:SetBackdropColor(0, 0, 0, 0.95)
    menu:SetFrameStrata("DIALOG")
    menu:SetSize(240, 8 + #options * 22)
    menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)

    local y = -4
    for _, opt in ipairs(options) do
        local btn = CreateFrame("Button", nil, menu)
        btn:SetSize(230, 20)
        btn:SetPoint("TOPLEFT", menu, "TOPLEFT", 5, y)
        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetText(opt)
        btn:SetScript("OnClick", function()
            onSelect(opt)
            menu:Hide()
        end)
        y = y - 22
    end
    menu:Show()
end

local function SetMode(mode)
    currentMode = mode
    currentDungeon = nil
    currentRaid = nil
    currentBoss = nil

    if frame.mythicDungeonBtn then frame.mythicDungeonBtn:Hide() end
    if frame.raidSelector then frame.raidSelector:Hide() end
    if frame.bossSelector then frame.bossSelector:Hide() end

    if mode == "mythic" then
        if frame.mythicDungeonBtn then
            frame.mythicDungeonBtn:Show()
            frame.mythicDungeonBtn:SetText("Dungeon: All")
        end
    elseif mode == "raid" then
        if frame.raidSelector then
            frame.raidSelector:Show()
            frame.raidSelector:SetText("Raid: All")
        end
    end

    -- Highlight the active mode button
    if frame.mbMythic then frame.mbMythic:UnlockHighlight() end
    if frame.mbRaid then frame.mbRaid:UnlockHighlight() end
    if frame.mbCustom then frame.mbCustom:UnlockHighlight() end
    if mode == "mythic" and frame.mbMythic then frame.mbMythic:LockHighlight() end
    if mode == "raid" and frame.mbRaid then frame.mbRaid:LockHighlight() end
    if mode == "custom" and frame.mbCustom then frame.mbCustom:LockHighlight() end

    if BuildCompare_RefreshUI then BuildCompare_RefreshUI() end
end

local function ShowMythicDropdown()
    local options = {"All"}
    for _, d in ipairs(SEASON_1_MYTHICS) do table.insert(options, d) end
    ShowSimpleDropdown(frame.mythicDungeonBtn, options, function(choice)
        if choice == "All" then
            currentDungeon = nil
            if frame and frame.mythicDungeonBtn then frame.mythicDungeonBtn:SetText("Dungeon: All") end
        else
            currentDungeon = choice
            if frame and frame.mythicDungeonBtn then frame.mythicDungeonBtn:SetText("Dungeon: " .. choice) end
        end
        if _G.BuildCompare_RefreshUI then _G.BuildCompare_RefreshUI() end
    end)
end

local function ShowRaidDropdown()
    local options = {"All"}
    for r in pairs(SEASON_1_RAIDS) do table.insert(options, r) end
    ShowSimpleDropdown(frame.raidSelector, options, function(choice)
        if choice == "All" then
            currentRaid = nil
            currentBoss = nil
            if frame and frame.raidSelector then frame.raidSelector:SetText("Raid: All") end
            if frame and frame.bossSelector then frame.bossSelector:Hide() end
        else
            currentRaid = choice
            currentBoss = nil
            if frame and frame.raidSelector then frame.raidSelector:SetText("Raid: " .. choice) end
            if frame and frame.bossSelector then frame.bossSelector:Show() end
            if frame and frame.bossSelector then frame.bossSelector:SetText("Boss: All") end
        end
        if _G.BuildCompare_RefreshUI then _G.BuildCompare_RefreshUI() end
    end)
end

local function ShowBossDropdown()
    if not currentRaid then return end
    local bossList = SEASON_1_RAIDS[currentRaid] or {}
    local options = {"All"}
    for _, b in ipairs(bossList) do table.insert(options, b) end
    ShowSimpleDropdown(frame.bossSelector, options, function(choice)
        if choice == "All" then
            currentBoss = nil
            if frame and frame.bossSelector then frame.bossSelector:SetText("Boss: All") end
        else
            currentBoss = choice
            if frame and frame.bossSelector then frame.bossSelector:SetText("Boss: " .. choice) end
        end
        if _G.BuildCompare_RefreshUI then _G.BuildCompare_RefreshUI() end
    end)
end

-- Expose for button scripts to ensure they can find the functions even if scoping is tricky
BuildCompare_SetMode = SetMode
BuildCompare_ShowMythicDropdown = ShowMythicDropdown
BuildCompare_ShowRaidDropdown = ShowRaidDropdown
BuildCompare_ShowBossDropdown = ShowBossDropdown

function BuildCompare_CreateMainFrame()
    if frame then return frame end

    -- Setup DB Settings defaults

    frame = CreateFrame("Frame", "BuildCompareFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(800, 520)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    frame.title:SetPoint("LEFT", frame.TitleBg, "LEFT", 8, 0)
    frame.title:SetText("BuildCompare - Run & Build Comparison Tool")

    -- Minimize button. We create it early but position + size it in the delayed block
    -- so it can perfectly match the template's CloseButton (X) and sit right next to it.
    local minBtn = CreateFrame("Button", nil, frame)
    minBtn:SetSize(20, 20)  -- default; will be overridden to exactly match the X
    minBtn:SetScript("OnClick", function()
        if _G.BuildCompare_ShowMiniCurrent then _G.BuildCompare_ShowMiniCurrent() end
        frame:Hide()
    end)
    frame.minBtn = minBtn

    -- Safely override the template X close button's handler (delayed for layout) with plain Hide()
    -- to prevent "Interface action failed because of an AddOn" taint errors.
    -- Also position the minimize button to be exactly the same size as the X and
    -- right next to it (like a normal window title bar: [–][X] with 1px gap, vertically level).
    C_Timer.After(0, function()
        local cb = frame.CloseButton
        if not cb then
            for i = 1, frame:GetNumChildren() do
                local child = select(i, frame:GetChildren())
                if child and child:IsObjectType("Button") then
                    local w, h = child:GetSize()
                    if w >= 16 and w <= 32 and h >= 16 and h <= 32 then
                        local right = child:GetRight() or 0
                        local fRight = frame:GetRight() or 0
                        if (fRight - right) < 50 then
                            cb = child
                            break
                        end
                    end
                end
            end
        end
        if cb then
            cb:SetScript("OnClick", function() frame:Hide() end)

            -- Position + size the minimize button snug against the X
            local mb = frame.minBtn
            if mb then
                local size = cb:GetWidth() or 20
                mb:SetSize(size, size)
                mb:ClearAllPoints()
                mb:SetPoint("TOPRIGHT", cb, "TOPLEFT", -1, 0)  -- 1px gap, same top, left of X

                mb:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
                mb:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
                mb:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")

                if not mb.mask then
                    mb.mask = mb:CreateTexture(nil, "OVERLAY", nil, 1)
                    mb.mask:SetSize(10, 10)
                    mb.mask:SetPoint("CENTER", mb, "CENTER", 0, 0)
                    mb.mask:SetColorTexture(0.42, 0.05, 0.05, 1)
                end

                if not mb.minusLine then
                    mb.minusLine = mb:CreateTexture(nil, "OVERLAY", nil, 2)
                    mb.minusLine:SetSize(10, 2)
                    mb.minusLine:SetPoint("CENTER", mb, "CENTER", 0, 0)
                    mb.minusLine:SetColorTexture(0.9, 0.8, 0.1, 1)
                end

                -- Tooltip for clarity (matches normal window behavior)
                mb:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Minimize to mini display (over the default damage meter)")
                    GameTooltip:Show()
                end)
                mb:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end
        else
            -- Fallback (if X not found for some reason): put it near top-right
            local mb = frame.minBtn
            if mb then
                mb:ClearAllPoints()
                mb:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -26, -5)
            end
        end
    end)

    -- Instructions
    frame.instructions = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.instructions:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -26)
    frame.instructions:SetText("Sel 2 runs for aligned 3-col compare (A | B | Diff). Rows line up perfectly with vertical dividers. Higher number = green.")

    -- ==================== NEW SCOPED MODE SELECTORS (replaces old Instance/Key/Build filters) ====================
    -- Three main buttons + context dropdowns for Mythic/Raid
    frame.modeBar = CreateFrame("Frame", nil, frame)
    frame.modeBar:SetSize(400, 26)
    frame.modeBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -42)

    local mbMythic = CreateFrame("Button", nil, frame.modeBar, "UIPanelButtonTemplate")
    mbMythic:SetSize(90, 22)
    mbMythic:SetText("Mythic")
    mbMythic:SetPoint("LEFT", 0, 0)
    mbMythic:SetScript("OnClick", function() BuildCompare_SetMode("mythic") end)

    local mbRaid = CreateFrame("Button", nil, frame.modeBar, "UIPanelButtonTemplate")
    mbRaid:SetSize(90, 22)
    mbRaid:SetText("Raid")
    mbRaid:SetPoint("LEFT", mbMythic, "RIGHT", 5, 0)
    mbRaid:SetScript("OnClick", function() BuildCompare_SetMode("raid") end)

    local mbCustom = CreateFrame("Button", nil, frame.modeBar, "UIPanelButtonTemplate")
    mbCustom:SetSize(90, 22)
    mbCustom:SetText("Custom")
    mbCustom:SetPoint("LEFT", mbRaid, "RIGHT", 5, 0)
    mbCustom:SetScript("OnClick", function() BuildCompare_SetMode("custom") end)

    frame.mbMythic = mbMythic
    frame.mbRaid = mbRaid
    frame.mbCustom = mbCustom

    -- Sub selectors (shown/hidden based on mode)
    frame.mythicDungeonBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.mythicDungeonBtn:SetSize(170, 20)
    frame.mythicDungeonBtn:SetPoint("TOPLEFT", frame.modeBar, "BOTTOMLEFT", 0, -2)
    frame.mythicDungeonBtn:SetText("Dungeon: All")
    frame.mythicDungeonBtn:SetNormalFontObject("GameFontNormalSmall")
    frame.mythicDungeonBtn:Hide()
    frame.mythicDungeonBtn:SetScript("OnClick", function() BuildCompare_ShowMythicDropdown() end)

    frame.raidSelector = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.raidSelector:SetSize(145, 20)
    frame.raidSelector:SetPoint("TOPLEFT", frame.modeBar, "BOTTOMLEFT", 0, -2)
    frame.raidSelector:SetText("Raid: All")
    frame.raidSelector:SetNormalFontObject("GameFontNormalSmall")
    frame.raidSelector:Hide()
    frame.raidSelector:SetScript("OnClick", function() BuildCompare_ShowRaidDropdown() end)

    frame.bossSelector = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.bossSelector:SetSize(165, 20)
    frame.bossSelector:SetPoint("LEFT", frame.raidSelector, "RIGHT", 5, 0)
    frame.bossSelector:SetText("Boss: All")
    frame.bossSelector:SetNormalFontObject("GameFontNormalSmall")
    frame.bossSelector:Hide()
    frame.bossSelector:SetScript("OnClick", function() BuildCompare_ShowBossDropdown() end)

    -- List container
    local listFrame = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    listFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -100)  -- shifted down for new selectors
    listFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", 310, 50)  -- give more room to the compare panel on the right for wider columns (shifted left for 3-col breathing room)

    scroll = CreateFrame("ScrollFrame", nil, listFrame, "UIPanelScrollFrameTemplate")
    MakeScrollFrameTaintSafe(scroll)
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)

    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(340, 1)
    scroll:SetScrollChild(content)

    frame.rows = {}

    -- Bottom action buttons
    -- Custom manual tracking buttons (moved to bottom as requested)
    local btnStartCustom = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnStartCustom:SetSize(120, 20)
    btnStartCustom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 15)
    btnStartCustom:SetText("Start Custom")
    btnStartCustom:SetScript("OnClick", StartCustomRun)

    local btnStopCustom = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnStopCustom:SetSize(130, 20)
    btnStopCustom:SetPoint("LEFT", btnStartCustom, "RIGHT", 5, 0)
    btnStopCustom:SetText("Stop & Save Custom")
    btnStopCustom:SetScript("OnClick", StopCustomTracking)

    -- Close button removed per request. Clear DB now placed exactly where Close was (right after Stop & Save Custom).
    local btnClear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnClear:SetSize(65, 22)
    btnClear:SetPoint("LEFT", btnStopCustom, "RIGHT", 6, 0)
    btnClear:SetText("Clear DB")
    btnClear:SetScript("OnClick", function()
        StaticPopupDialogs["BUILDCOMPARE_CONFIRM_CLEAR"] = {
            text = "Clear ALL saved runs?",
            button1 = "Yes, clear",
            button2 = "Cancel",
            OnAccept = BuildCompare_ClearDB,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
        }
        StaticPopup_Show("BUILDCOMPARE_CONFIRM_CLEAR")
    end)

    -- ==================== RIGHT COLUMN (Comparison & Customization) ====================

    -- Comparison panel container
    frame.comparePanel = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    frame.comparePanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 325, -42)
    frame.comparePanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 15)

    -- ScrollFrame for comparison details
    local compareScroll = CreateFrame("ScrollFrame", "BuildCompareCompareScroll", frame.comparePanel, "UIPanelScrollFrameTemplate")
    MakeScrollFrameTaintSafe(compareScroll)
    compareScroll:SetPoint("TOPLEFT", 4, -4)
    compareScroll:SetPoint("BOTTOMRIGHT", -28, 4)

    local compareContent = CreateFrame("Frame", nil, compareScroll)
    compareContent:SetSize(480, 1)
    compareScroll:SetScrollChild(compareContent)
    frame.compareContentFrame = compareContent

    -- Message shown when <2 runs selected for compare. Hidden when we build the row table.
    frame.compareNoSel = compareContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.compareNoSel:SetPoint("TOPLEFT", compareContent, "TOPLEFT", 6, -6)
    frame.compareNoSel:SetPoint("RIGHT", compareContent, "RIGHT", -6, 0)
    frame.compareNoSel:SetJustifyH("LEFT")
    frame.compareNoSel:SetText("Select exactly 2 runs with the 'Sel' buttons (left list) to see aligned 3-column comparison.\n\nRun A | Run B | % Diff\n\nRows are strictly aligned with vertical divider lines. Higher numeric value per row is shown in green.")

    -- Note: actual 3-col rows (with perfect vertical alignment + dividers) are created dynamically in RefreshUI
    -- using CreateAlignedCompareRow into compareContent. Old multi-line colA/B/C removed for alignment.

    SetMode(currentMode)  -- init mode buttons and sub selectors

    frame:Hide()
    return frame
end

-- ============================================================
-- Aligned 3-column comparison row builder (for perfect vertical alignment)
-- Columns: [narrow metric label] | [Run A value] | [Run B value] | [% Diff]  (widths + content tuned below for breathing room on long rates/headers + 3 dividers + offsets)
-- Vertical divider lines between columns.
-- aIsGreen / bIsGreen: embed green color on the higher side's value.
-- Header rows use isHeader=true and put run labels in the A/B slots.
-- ============================================================
local LABEL_W = 106
local A_W = 106
local B_W = 106
local DIFF_W = 106

local function CreateAlignedCompareRow(parent, y, isHeader, metric, aVal, bVal, diffVal, aIsGreen, bIsGreen)
    local rowH = isHeader and 17 or 14
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(rowH)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, -y)
    row:SetPoint("RIGHT", parent, "RIGHT", -2, 0)

    if isHeader then
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.label:SetPoint("LEFT", 2, 0)
        row.label:SetWidth(LABEL_W)
        row.label:SetText(metric or "Metric")
        row.a = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.a:SetPoint("LEFT", row.label, "RIGHT", 3, 0)
        row.a:SetWidth(A_W)
        row.a:SetFormattedText("%s", aVal or "")
        row.b = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.b:SetPoint("LEFT", row.a, "RIGHT", 3, 0)
        row.b:SetWidth(B_W)
        row.b:SetFormattedText("%s", bVal or "")
        row.d = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.d:SetPoint("LEFT", row.b, "RIGHT", 3, 0)
        row.d:SetWidth(DIFF_W)
        row.d:SetFormattedText("%s", diffVal or "")
    else
        -- metric / label col
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.label:SetPoint("LEFT", 2, 0)
        row.label:SetWidth(LABEL_W)
        row.label:SetText(metric or "")

        -- vertical divider after label
        local v1 = row:CreateTexture(nil, "OVERLAY")
        v1:SetColorTexture(0.35, 0.35, 0.35, 0.85)
        v1:SetSize(1, rowH - 1)
        v1:SetPoint("LEFT", row.label, "RIGHT", 1, 0)

        -- Col A (Run A value) -- green if higher on this row
        row.a = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.a:SetPoint("LEFT", v1, "RIGHT", 2, 0)
        row.a:SetWidth(A_W)
        if IsSecret(aVal) then
            row.a:SetFormattedText("%s", aVal)
        else
            local aText = tostring(aVal or "")
            if aIsGreen then
                aText = "|cFF00FF00" .. aText .. "|r"
            end
            row.a:SetFormattedText("%s", aText)
        end

        -- vertical divider after A
        local v2 = row:CreateTexture(nil, "OVERLAY")
        v2:SetColorTexture(0.35, 0.35, 0.35, 0.85)
        v2:SetSize(1, rowH - 1)
        v2:SetPoint("LEFT", row.a, "RIGHT", 1, 0)

        -- Col B (Run B value)
        row.b = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.b:SetPoint("LEFT", v2, "RIGHT", 2, 0)
        row.b:SetWidth(B_W)
        if IsSecret(bVal) then
            row.b:SetFormattedText("%s", bVal)
        else
            local bText = tostring(bVal or "")
            if bIsGreen then
                bText = "|cFF00FF00" .. bText .. "|r"
            end
            row.b:SetFormattedText("%s", bText)
        end

        -- vertical divider after B
        local v3 = row:CreateTexture(nil, "OVERLAY")
        v3:SetColorTexture(0.35, 0.35, 0.35, 0.85)
        v3:SetSize(1, rowH - 1)
        v3:SetPoint("LEFT", row.b, "RIGHT", 1, 0)

        -- Col C: % Diff
        row.d = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.d:SetPoint("LEFT", v3, "RIGHT", 2, 0)
        row.d:SetWidth(DIFF_W)
        row.d:SetFormattedText("%s", tostring(diffVal or ""))
    end

    return row, rowH
end

-- New scoped view: only runs matching the selected Mythic/Raid/Custom + sub-filters
local function GetViewRuns()
    local allRuns = (BuildCompareDB and BuildCompareDB.runs) or {}
    local filtered = {}
    for i = #allRuns, 1, -1 do  -- recent first
        local r = allRuns[i]
        -- Infer type for old runs (backward compat after scope change)
        local rt = r.runType or (r.keyLevel and r.keyLevel > 0 and "mythic") or (r.bossName and "raid") or "custom"

        local match = false
        if currentMode == "mythic" and rt == "mythic" then
            if not currentDungeon or (r.dungeon == currentDungeon or r.instance == currentDungeon) then
                match = true
            end
        elseif currentMode == "raid" and rt == "raid" then
            if not currentRaid or (r.raid == currentRaid or r.instance == currentRaid) then
                if not currentBoss or (r.boss == currentBoss or r.buildLabel == currentBoss) then
                    match = true
                end
            end
        elseif currentMode == "custom" and rt == "custom" then
            match = true
        end
        if match then
            table.insert(filtered, r)
        end
    end
    return filtered
end

function BuildCompare_RefreshUI()
    if not frame then BuildCompare_CreateMainFrame() end
    if not content then return end

    -- Clean up selectedForCompare to remove runs that no longer exist in the database (e.g. cleared)
    local allRuns = (BuildCompareDB and BuildCompareDB.runs) or {}
    local runsSet = {}
    for _, r in ipairs(allRuns) do
        if r.id then
            runsSet[r.id] = true
        end
    end
    local newSelected = {}
    for _, r in ipairs(selectedForCompare) do
        if r.id and runsSet[r.id] then
            table.insert(newSelected, r)
        end
    end
    selectedForCompare = newSelected

    -- Clear old rows
    for _, row in ipairs(frame.rows or {}) do row:Hide() end
    frame.rows = {}

    local runs = GetViewRuns()
    local y = 0

    -- Build list
    local maxShow = 18
    for i = 1, math.min(#runs, maxShow) do
        local run = runs[i]
        local row = CreateBarRow(content, #frame.rows + 1, run)

        -- Enhanced status bar text layout using SetFormattedText for taint safety (issue #2 fix)
        -- Use SafeDisplayVal(...) + SetFormattedText so that for secret protected numbers (from C_DamageMeter in runs or live) the engine does the k/m abbr, and for normal values we get the .1f k/m from inside SafeDisplayVal/FormatNumber. DT, AvDT, Dmg, Heal now always clean abbreviated in the main saved-runs list rows.
        -- Include Dmg for custom/dummy tests where DT may be 0 but outgoing damage is the key metric
        row.text:SetFormattedText("DT: %s | AvDT: %s | Dmg: %s | Heal: %s", SafeDisplayVal(run.dt), SafeDisplayVal(run.avoidableDT or 0), SafeDisplayVal(run.damage or 0), SafeDisplayVal(run.healing or 0))

        -- Bar scale relative to filtered list max DT
        local maxDT = 1
        for _, r in ipairs(runs) do
            local val = r.dt or 0
            if not IsSecret(val) and val > maxDT then
                maxDT = val
            end
        end
        local val = run.dt or 0
        if IsSecret(val) then
            row.dtBar:SetMinMaxValues(0, 1)
            row.dtBar:SetValue(0)
        else
            row.dtBar:SetMinMaxValues(0, maxDT)
            row.dtBar:SetValue(val)
        end

        -- Pre-select state
        if selectedForCompare[1] and selectedForCompare[1].id == run.id then
            row.selectBtn:SetText("A")
        elseif selectedForCompare[2] and selectedForCompare[2].id == run.id then
            row.selectBtn:SetText("B")
        else
            row.selectBtn:SetText("Sel")
        end

        table.insert(frame.rows, row)
        y = y + 44
    end

    content:SetHeight(math.max(380, y + 10))

    -- Update detailed comparison panel with STRICTLY ALIGNED 3-column rows + vertical divider lines.
    -- Layout per row: [Metric] | [Run A value] | [Run B value] | [% Diff]
    -- Every data line (DT of A next to DT of B etc) shares the exact same vertical position.
    -- Higher raw number on a row gets green in its column (as requested).
    -- Stats are shown in the exact same 3-col format at the bottom (no crammed "vs" text).
    local selectedList = selectedForCompare

    -- Hide old row frames from previous compare (safe for any non-Frame entries)
    if frame.compareRows then
        for _, r in ipairs(frame.compareRows) do
            if r and r.Hide then r:Hide() end
        end
    end
    frame.compareRows = {}

    -- Show/hide the no-selection message
    if frame.compareNoSel then frame.compareNoSel:Hide() end

    if #selectedList >= 2 then
        local a = selectedList[1]
        local b = selectedList[2] or a
        local labelA = BuildCompare_GetColumnHeaderLabel(a) or "A"
        local labelB = BuildCompare_GetColumnHeaderLabel(b) or "B"
        -- Truncate long labels for the header row (more aggressive truncation so full "A: " + name fits safely inside the (now wider) A_W/B_W columns)
        if #labelA > 20 then labelA = labelA:sub(1,18) .. "..." end
        if #labelB > 20 then labelB = labelB:sub(1,18) .. "..." end

        local content = frame.compareContentFrame
        local y = 2
        local rows = frame.compareRows

        local function addRow(m, rawA, rawB, txtA, txtB, diffTxt, greenA, greenB, spacingAfter)
            local r, h = CreateAlignedCompareRow(content, y, false, m, txtA, txtB, diffTxt, greenA, greenB)
            table.insert(rows, r)
            y = y + h + (spacingAfter or 1)
            return h
        end

        local function addSection(title, spacingAfter)
            local r, h = CreateAlignedCompareRow(content, y, true, title, "", "", "", false, false)
            table.insert(rows, r)
            y = y + h + (spacingAfter or 2)
        end

        -- Header row with the actual run labels (so user sees which is A vs B)
        local hr, hh = CreateAlignedCompareRow(content, y, true, "Metric", "A: " .. labelA, "B: " .. labelB, "% Diff", false, false)
        table.insert(rows, hr)
        y = y + hh + 12

        -- === Performance metrics (aligned rows) ===

        -- Section 1: Tank
        addSection("|cFFFFD100Tank:|r", 6)

        -- DT (total and DTPS, e.g. 470k (13k/s))
        local na, nb = a.dt or 0, b.dt or 0
        local ta, tb
        if IsSecret(na) then
            ta = BuildCompare_FormatNumber(na)
        else
            ta = BuildCompare_FormatNumber(na) .. " (" .. BuildCompare_FormatNumber(a.dtps or 0) .. "/s)"
        end
        if IsSecret(nb) then
            tb = BuildCompare_FormatNumber(nb)
        else
            tb = BuildCompare_FormatNumber(nb) .. " (" .. BuildCompare_FormatNumber(b.dtps or 0) .. "/s)"
        end
        local ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        local gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("DT", na, nb, ta, tb, BuildCompare_FormatPercentDiffLowerBetter(na, nb), ga, gb, 6)

        -- Def CDs
        local cda = #(a.defensiveCDsUsed or {})
        local cdb = #(b.defensiveCDsUsed or {})
        ta, tb = tostring(cda), tostring(cdb)
        ga = cda > cdb; gb = cdb > cda
        addRow("Def CDs", cda, cdb, ta, tb, BuildCompare_FormatPercentDiffNeutral(cda, cdb), ga, gb, 18)

        -- Section 2: DMG
        addSection("|cFFFFD100DMG:|r", 6)

        -- Dmg
        na, nb = a.damage or 0, b.damage or 0
        ta = BuildCompare_FormatNumber(na)
        tb = BuildCompare_FormatNumber(nb)
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Dmg", na, nb, ta, tb, BuildCompare_FormatPercentDiffHigherBetter(na, nb), ga, gb, 6)

        -- DPS
        na, nb = a.dps or 0, b.dps or 0
        if IsSecret(na) then
            ta = BuildCompare_FormatNumber(na)
        else
            ta = BuildCompare_FormatNumber(na) .. "/s"
        end
        if IsSecret(nb) then
            tb = BuildCompare_FormatNumber(nb)
        else
            tb = BuildCompare_FormatNumber(nb) .. "/s"
        end
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("DPS", na, nb, ta, tb, BuildCompare_FormatPercentDiffHigherBetter(na, nb), ga, gb, 6)

        -- Dmg CDs
        local dmg_cda = #(a.dpsCDsUsed or {})
        local dmg_cdb = #(b.dpsCDsUsed or {})
        ta, tb = tostring(dmg_cda), tostring(dmg_cdb)
        ga = dmg_cda > dmg_cdb; gb = dmg_cdb > dmg_cda
        addRow("Dmg CDs", dmg_cda, dmg_cdb, ta, tb, BuildCompare_FormatPercentDiffNeutral(dmg_cda, dmg_cdb), ga, gb, 18)

        -- Section 3: Heals
        addSection("|cFFFFD100Heals:|r", 6)

        -- Healing
        na, nb = a.healing or 0, b.healing or 0
        ta = BuildCompare_FormatNumber(na)
        tb = BuildCompare_FormatNumber(nb)
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Healing", na, nb, ta, tb, BuildCompare_FormatPercentDiffHigherBetter(na, nb), ga, gb, 6)

        -- HPS
        na, nb = a.hps or 0, b.hps or 0
        if IsSecret(na) then
            ta = BuildCompare_FormatNumber(na)
        else
            ta = BuildCompare_FormatNumber(na) .. "/s"
        end
        if IsSecret(nb) then
            tb = BuildCompare_FormatNumber(nb)
        else
            tb = BuildCompare_FormatNumber(nb) .. "/s"
        end
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("HPS", na, nb, ta, tb, BuildCompare_FormatPercentDiffHigherBetter(na, nb), ga, gb, 6)

        -- Heal CDs
        local heal_cda = #(a.healingCDsUsed or {})
        local heal_cdb = #(b.healingCDsUsed or {})
        ta, tb = tostring(heal_cda), tostring(heal_cdb)
        ga = heal_cda > heal_cdb; gb = heal_cdb > heal_cda
        addRow("Heal CDs", heal_cda, heal_cdb, ta, tb, BuildCompare_FormatPercentDiffNeutral(heal_cda, heal_cdb), ga, gb, 18)

        -- Section 4: Misc
        addSection("|cFFFFD100Misc:|r", 6)

        -- Interrupts
        na, nb = a.interrupts or 0, b.interrupts or 0
        ta = BuildCompare_FormatNumber(na)
        tb = BuildCompare_FormatNumber(nb)
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Interrupts", na, nb, ta, tb, BuildCompare_FormatPercentDiffHigherBetter(na, nb), ga, gb, 6)

        -- Deaths
        na, nb = a.deaths or 0, b.deaths or 0
        ta = BuildCompare_FormatNumber(na)
        tb = BuildCompare_FormatNumber(nb)
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Deaths", na, nb, ta, tb, BuildCompare_FormatPercentDiffLowerBetter(na, nb), ga, gb, 60)

        -- Section 5: Stats
        addSection("|cFFFFD100Stats:|r", 6)

        local saStats = a.stats or {}
        local sbStats = b.stats or {}

        -- Mastery
        na, nb = saStats.mastery or 0, sbStats.mastery or 0
        ta = BuildCompare_FormatNumber(na)
        tb = BuildCompare_FormatNumber(nb)
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Mastery", na, nb, ta, tb, BuildCompare_FormatPercentDiffNeutral(na, nb), ga, gb, 4)

        -- Crit
        na, nb = saStats.crit or 0, sbStats.crit or 0
        ta = BuildCompare_FormatNumber(na)
        tb = BuildCompare_FormatNumber(nb)
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Crit", na, nb, ta, tb, BuildCompare_FormatPercentDiffNeutral(na, nb), ga, gb, 4)

        -- Haste
        na, nb = saStats.haste or 0, sbStats.haste or 0
        ta = BuildCompare_FormatNumber(na)
        tb = BuildCompare_FormatNumber(nb)
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Haste", na, nb, ta, tb, BuildCompare_FormatPercentDiffNeutral(na, nb), ga, gb, 4)

        -- Vers
        na, nb = saStats.vers or 0, sbStats.vers or 0
        ta = BuildCompare_FormatNumber(na)
        tb = BuildCompare_FormatNumber(nb)
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Vers", na, nb, ta, tb, BuildCompare_FormatPercentDiffNeutral(na, nb), ga, gb, 4)

        -- Dodge
        na, nb = saStats.dodgePct or 0, sbStats.dodgePct or 0
        if IsSecret(na) or IsSecret(nb) then
            ta = "Pending"
            tb = "Pending"
        else
            ta = string.format("%.1f%%", na)
            tb = string.format("%.1f%%", nb)
        end
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Dodge", na, nb, ta, tb, BuildCompare_FormatPercentDiffNeutral(na, nb), ga, gb, 4)

        -- Parry
        na, nb = saStats.parryPct or 0, sbStats.parryPct or 0
        if IsSecret(na) or IsSecret(nb) then
            ta = "Pending"
            tb = "Pending"
        else
            ta = string.format("%.1f%%", na)
            tb = string.format("%.1f%%", nb)
        end
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Parry", na, nb, ta, tb, BuildCompare_FormatPercentDiffNeutral(na, nb), ga, gb, 4)

        -- Block
        na, nb = saStats.blockPct or 0, sbStats.blockPct or 0
        if IsSecret(na) or IsSecret(nb) then
            ta = "Pending"
            tb = "Pending"
        else
            ta = string.format("%.1f%%", na)
            tb = string.format("%.1f%%", nb)
        end
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Block", na, nb, ta, tb, BuildCompare_FormatPercentDiffNeutral(na, nb), ga, gb, 4)

        -- Mast %
        na, nb = saStats.masteryPct or 0, sbStats.masteryPct or 0
        if IsSecret(na) or IsSecret(nb) then
            ta = "Pending"
            tb = "Pending"
        else
            ta = string.format("%.1f%%", na)
            tb = string.format("%.1f%%", nb)
        end
        ga = not IsSecret(na) and not IsSecret(nb) and na > nb
        gb = not IsSecret(na) and not IsSecret(nb) and nb > na
        addRow("Mast %", na, nb, ta, tb, BuildCompare_FormatPercentDiffNeutral(na, nb), ga, gb, 4)

        -- Resize content for the rows we created + a little padding for scroll
        local finalH = y + 12
        content:SetHeight(math.max(120, finalH))

        -- Show a compact talent note at very bottom if there were unique talents (non-row text for long content)
        -- (kept minimal to preserve row alignment focus; full diff still available via other UI if needed)
        if BuildCompare_TalentDiff then
            local onlyA, onlyB = BuildCompare_TalentDiff(a.talents, b.talents)
            if #onlyA > 0 or #onlyB > 0 then
                local note = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                note:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y - 2)
                note:SetPoint("RIGHT", content, "RIGHT", -4, 0)
                local t = "Talents diff: "
                if #onlyA > 0 then t = t .. "A only: " .. table.concat(onlyA, ", ") end
                if #onlyB > 0 then t = t .. (#onlyA > 0 and " | " or "") .. "B only: " .. table.concat(onlyB, ", ") end
                note:SetText(t)
                -- Not inserted into rows to avoid :Hide() on FontString; it will be replaced on next compare anyway.
            end
        end
    else
        if frame.compareNoSel then frame.compareNoSel:Show() end
        if frame.compareContentFrame then
            frame.compareContentFrame:SetHeight(90)
        end
    end
end

function BuildCompare_ShowUI()
    local f = BuildCompare_CreateMainFrame()
    f:Show()
    BuildCompare_RefreshUI()
end

-- Make sure global hooks work
_G.BuildCompare_ShowUI = BuildCompare_ShowUI
_G.BuildCompare_RefreshUI = BuildCompare_RefreshUI

-- ==================== MINI CURRENT-RUN OVERLAY (for placing over default WoW damage meters) ====================
-- Compact, movable, live-updating view of current combat metrics from GetNativeMeterData (prefer Current).
-- + = restore full UI, x = hide mini. (Rec removed per request)
-- Polls ~4x/sec via OnUpdate. Shows DT/AvDT/Heal/Dmg (outgoing for context) + live Def CDs + recording timer (from activeRun.startTime or meter duration). Use SetFormattedText for secret-safe k/m decimals in combat.
local miniFrame = nil

function BuildCompare_UpdateMiniDisplay(mf)
    if not mf then return end
    local data = nil
    if _G.GetNativeMeterData then
        data = _G.GetNativeMeterData(true)  -- preferCurrent for live pull/segment view (Current first)
    end
    if not data then
        mf.dtLine:SetText("DT: -- (no meter data)")
        mf.avdtLine:SetText("AvDT: --")
        mf.healLine:SetText("Heal: --")
        mf.dmgLine:SetText("Dmg: --")
        mf.cdsLine:SetText("Def CDs: --")
        mf.timeLine:SetText("Time: --")
        if miniFrame.startRecBtn then miniFrame.startRecBtn:Hide() end
        if miniFrame.stopRecBtn then miniFrame.stopRecBtn:Hide() end
        return
    end

    -- Use SetFormattedText + SafeDisplayVal for secret-safe k/m decimals in combat (issue #2 fix).
    -- SafeDisplayVal returns raw secret val (for engine abbr via SetFormattedText) or the clean .1f k/m string. Replaces prior direct FormatNumber. Ensures DT, AvDT, Dmg, Heal + rates always abbreviated (1.5m, 40.5k) in mini current-run overlay even for secret protected numbers from GetNativeMeterData. Matches updated list rows.
    mf.dtLine:SetFormattedText("DT: %s (%s/s)", SafeDisplayVal(data.dt or 0), SafeDisplayVal(data.dtps or 0))

    mf.avdtLine:SetFormattedText("AvDT: %s (%s/s)", SafeDisplayVal(data.avoidableDT or 0), SafeDisplayVal(data.avoidableDTPS or 0))

    mf.healLine:SetFormattedText("Heal: %s (%s/s)", SafeDisplayVal(data.healing or 0), SafeDisplayVal(data.hps or 0))

    mf.dmgLine:SetFormattedText("Dmg: %s (%s/s)", SafeDisplayVal(data.damage or 0), SafeDisplayVal(data.dps or 0))

    -- Live defensive CD count (only tracked if an activeRun/custom/M+ is in progress via events)
    local cdsCount = 0
    if _G.BuildCompare_GetActiveRun then
        local ar = _G.BuildCompare_GetActiveRun()
        if ar and ar.defensiveCDsUsed then
            cdsCount = #ar.defensiveCDsUsed
        end
    end
    mf.cdsLine:SetText("Def CDs: " .. cdsCount)

    -- Live recording timer (prefer activeRun for "how long recording" -- always safe clean number;
    -- only fall back to meter duration if it is not secret. FormatDuration itself also guards secrets and returns "live".)
    local dur = 0
    local ar = _G.BuildCompare_GetActiveRun and _G.BuildCompare_GetActiveRun()
    if ar and ar.startTime then
        dur = time() - ar.startTime
    elseif data and data.duration and not IsSecret(data.duration) then
        dur = data.duration
    end
    local timerStr = BuildCompare_FormatDuration and BuildCompare_FormatDuration(dur) or (math.floor(dur or 0) .. "s")
    mf.timeLine:SetText("Time: " .. timerStr)

    -- Control Start/Stop Record buttons: only show the appropriate one when NOT in active mythic or raid boss fight.
    -- This prevents accidental clicks during M+ or boss encounters. Start for new custom, Stop if custom already active.
    local showRecButtons = true
    local ar = _G.BuildCompare_GetActiveRun and _G.BuildCompare_GetActiveRun()
    if ar then
        local rt = ar.runType or (ar.keyLevel and ar.keyLevel > 0 and "mythic") or (ar.bossName and "raid") or "custom"
        if rt == "mythic" or rt == "raid" then
            showRecButtons = false
        end
    end
    if miniFrame.startRecBtn and miniFrame.stopRecBtn then
        if not showRecButtons then
            miniFrame.startRecBtn:Hide()
            miniFrame.stopRecBtn:Hide()
        else
            if ar and ar.runType == "custom" then
                miniFrame.startRecBtn:Hide()
                miniFrame.stopRecBtn:Show()
            else
                miniFrame.startRecBtn:Show()
                miniFrame.stopRecBtn:Hide()
            end
        end
    end

    -- Update title with active build label if present (e.g. custom run label or "Auto")
    local label = "Live"
    if _G.BuildCompare_GetActiveRun then
        local ar = _G.BuildCompare_GetActiveRun()
        if ar and ar.buildLabel then label = ar.buildLabel end
    end
    mf.title:SetText("BC Live: " .. label)

    -- Update thin DT bar (scale grows to max seen; provides quick visual 'level' while over meters)
    -- Guard against secret to avoid taint on SetValue / comparisons (bar is visual only; text above uses formatted path).
    if mf.dtBar then
        local v = data.dt or 0
        if IsSecret(v) then
            mf.dtBar:SetValue(0)
        else
            if v > (mf.barMax or 0) then
                mf.barMax = v
            end
            mf.dtBar:SetMinMaxValues(0, mf.barMax or 100)
            mf.dtBar:SetValue(v)
        end
    end
end

function BuildCompare_ShowMiniCurrent()
    if not miniFrame then
        miniFrame = CreateFrame("Frame", "BuildCompareMini", UIParent, "BackdropTemplate")
        miniFrame:SetSize(215, 126)
        miniFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 300, -80)  -- default near center-top; drag to overlay default meters
        miniFrame:SetMovable(true)
        miniFrame:EnableMouse(true)
        miniFrame:RegisterForDrag("LeftButton")
        miniFrame:SetScript("OnDragStart", miniFrame.StartMoving)
        miniFrame:SetScript("OnDragStop", miniFrame.StopMovingOrSizing)
        miniFrame:SetClampedToScreen(true)
        miniFrame:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        miniFrame:SetBackdropColor(0.03, 0.03, 0.03, 0.88)
        miniFrame:SetFrameStrata("MEDIUM")  -- sits nicely over meter frames

        -- Compact title
        miniFrame.title = miniFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        miniFrame.title:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 5, -3)
        miniFrame.title:SetText("BC Live: Live")

        -- Action buttons on right (x hide mini, + expand to full UI). No Rec per request; timer shows recording duration instead.
        local xBtn = CreateFrame("Button", nil, miniFrame, "UIPanelButtonTemplate")
        xBtn:SetSize(18, 18)
        xBtn:SetPoint("TOPRIGHT", miniFrame, "TOPRIGHT", -3, -2)
        xBtn:SetText("x")
        xBtn:SetScript("OnClick", function() miniFrame:Hide() end)

        local expandBtn = CreateFrame("Button", nil, miniFrame, "UIPanelButtonTemplate")
        expandBtn:SetSize(18, 18)
        expandBtn:SetPoint("TOPRIGHT", xBtn, "TOPLEFT", -1, 0)
        expandBtn:SetText("+")
        expandBtn:SetScript("OnClick", function()
            miniFrame:Hide()
            if _G.BuildCompare_ShowUI then _G.BuildCompare_ShowUI() end
        end)

        -- Start/Stop Record buttons for custom runs. Stacked below top-right actions.
        -- Only visible when NOT in active mythic or raid boss fight (to avoid accidental clicks during those).
        miniFrame.startRecBtn = CreateFrame("Button", nil, miniFrame, "UIPanelButtonTemplate")
        miniFrame.startRecBtn:SetSize(55, 14)
        miniFrame.startRecBtn:SetPoint("TOPRIGHT", expandBtn, "BOTTOMRIGHT", 0, -1)
        miniFrame.startRecBtn:SetText("Start Rec")
        miniFrame.startRecBtn:SetNormalFontObject("GameFontNormalSmall")
        miniFrame.startRecBtn:SetScript("OnClick", function()
            if _G.StartCustomRun then _G.StartCustomRun() end
        end)
        miniFrame.startRecBtn:Hide()

        miniFrame.stopRecBtn = CreateFrame("Button", nil, miniFrame, "UIPanelButtonTemplate")
        miniFrame.stopRecBtn:SetSize(55, 14)
        miniFrame.stopRecBtn:SetPoint("TOPRIGHT", miniFrame.startRecBtn, "BOTTOMRIGHT", 0, -1)
        miniFrame.stopRecBtn:SetText("Stop Rec")
        miniFrame.stopRecBtn:SetNormalFontObject("GameFontNormalSmall")
        miniFrame.stopRecBtn:SetScript("OnClick", function()
            if _G.StopCustomTracking then _G.StopCustomTracking() end
        end)
        miniFrame.stopRecBtn:Hide()

        -- Live data lines (compact, 4 rows of text)
        miniFrame.dtLine = miniFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        miniFrame.dtLine:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 5, -34)
        miniFrame.dtLine:SetText("DT: " .. BuildCompare_FormatNumber(0) .. " (" .. BuildCompare_FormatNumber(0) .. "/s)")

        miniFrame.avdtLine = miniFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        miniFrame.avdtLine:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 5, -47)
        miniFrame.avdtLine:SetText("AvDT: " .. BuildCompare_FormatNumber(0) .. " (" .. BuildCompare_FormatNumber(0) .. "/s)")

        miniFrame.healLine = miniFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        miniFrame.healLine:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 5, -60)
        miniFrame.healLine:SetText("Heal: " .. BuildCompare_FormatNumber(0) .. " (" .. BuildCompare_FormatNumber(0) .. "/s)")

        -- New: player's damage done (useful context when mini is placed over the default WoW damage meters)
        miniFrame.dmgLine = miniFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        miniFrame.dmgLine:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 5, -73)
        miniFrame.dmgLine:SetText("Dmg: " .. BuildCompare_FormatNumber(0) .. " (" .. BuildCompare_FormatNumber(0) .. "/s)")

        miniFrame.cdsLine = miniFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        miniFrame.cdsLine:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 5, -86)
        miniFrame.cdsLine:SetText("Def CDs: 0")

        -- Live recording timer (how long the current active run / combat has been tracking)
        miniFrame.timeLine = miniFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        miniFrame.timeLine:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 5, -99)
        miniFrame.timeLine:SetText("Time: 0s")

        -- Thin visual bar at bottom (DT relative; live so absolute feel only)
        miniFrame.dtBar = CreateFrame("StatusBar", nil, miniFrame)
        miniFrame.dtBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        miniFrame.dtBar:SetStatusBarColor(0.85, 0.25, 0.25)
        miniFrame.dtBar:SetMinMaxValues(0, 100)
        miniFrame.dtBar:SetValue(0)
        miniFrame.dtBar:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 4, -113)
        miniFrame.dtBar:SetPoint("BOTTOMRIGHT", miniFrame, "BOTTOMRIGHT", -4, 3)
        miniFrame.dtBar:SetHeight(5)

        -- Live updater (fast poll for during-run feel; 0.25s = responsive without spam)
        miniFrame.lastUpdate = 0
        miniFrame:SetScript("OnUpdate", function(self, elapsed)
            self.lastUpdate = self.lastUpdate + elapsed
            if self.lastUpdate > 0.25 then
                self.lastUpdate = 0
                BuildCompare_UpdateMiniDisplay(self)
            end
        end)

        -- init bar max (grows as higher DT seen this session for visual scale)
        miniFrame.barMax = 100
    end
    miniFrame:Show()
    BuildCompare_UpdateMiniDisplay(miniFrame)
end

-- Expose mini
_G.BuildCompare_ShowMiniCurrent = BuildCompare_ShowMiniCurrent
