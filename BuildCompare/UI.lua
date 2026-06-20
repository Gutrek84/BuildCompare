-- BuildCompare/UI.lua
-- In-game GUI that mimics a damage meter with comparison readouts and % diffs.

local AddonName, _ = ...

local frame = nil
local scroll = nil
local content = nil

-- UI filter state
local filterInstance = "All"
local filterKeyLevel = "All"
local filterBuild = "All"
local selectedForCompare = {}  -- run ids

local function CreateBarRow(parent, index, run)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(26)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4 - (index-1)*28)
    row:SetPoint("RIGHT", parent, "RIGHT", -4, 0)

    -- Background bar (DT)
    row.dtBar = CreateFrame("StatusBar", nil, row)
    row.dtBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.dtBar:SetStatusBarColor(0.8, 0.2, 0.2)  -- red-ish for damage taken
    row.dtBar:SetMinMaxValues(0, 100)
    row.dtBar:SetValue(50)
    row.dtBar:SetPoint("LEFT", row, "LEFT", 60, 0)  -- leave space for select button
    row.dtBar:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.dtBar:SetHeight(20)

    -- Text overlay on bar
    row.text = row.dtBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", row.dtBar, "LEFT", 4, 0)
    row.text:SetText("DT: 12345 (456 DTPS)  |  Heal: 2345 | Abs: 123 | CDs: 2")

    row.buildLabel = row.dtBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.buildLabel:SetPoint("RIGHT", row.dtBar, "RIGHT", -4, 0)
    row.buildLabel:SetText("mastery v1")

    -- Select for compare button (left side)
    row.selectBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.selectBtn:SetSize(50, 18)
    row.selectBtn:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.selectBtn:SetText("Sel")
    row.selectBtn:SetScript("OnClick", function()
        if not run or not run.id then return end
        if selectedForCompare[run.id] then
            selectedForCompare[run.id] = nil
            row.selectBtn:SetText("Sel")
        else
            selectedForCompare[run.id] = run
            row.selectBtn:SetText("X")
        end
        BuildCompare_RefreshUI()  -- refresh to update compare panel
    end)

    -- Store run ref
    row.run = run

    return row
end

function BuildCompare_CreateMainFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "BuildCompareFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(620, 480)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    frame.title:SetPoint("LEFT", frame.TitleBg, "LEFT", 8, 0)
    frame.title:SetText("BuildCompare - Tank Run Comparison (w/ Filters & Detailed Compare)")

    -- Instructions
    frame.instructions = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.instructions:SetPoint("TOP", frame, "TOP", 0, -28)
    frame.instructions:SetText("Auto-records on M+ complete / boss kill. Click 'Sel' to pick runs for detailed comparison table. Data: C_DamageMeter.")

    -- Filter bar (simple cycling "dropdowns" via buttons)
    frame.filterBar = CreateFrame("Frame", nil, frame)
    frame.filterBar:SetSize(580, 26)
    frame.filterBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -52)

    local function MakeFilterButton(parent, label, getValue, setValue, getOptions)
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn:SetSize(140, 20)
        btn.label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.label:SetPoint("LEFT", btn, "RIGHT", 4, 0)
        btn:SetText(label .. ": " .. (getValue() or "All"))
        btn:SetScript("OnClick", function()
            local opts = getOptions()
            local current = getValue()
            local idx = 1
            for i, v in ipairs(opts) do if v == current then idx = i; break end end
            local nextVal = opts[idx % #opts + 1] or "All"
            setValue(nextVal)
            btn:SetText(label .. ": " .. nextVal)
            BuildCompare_RefreshUI()
        end)
        return btn
    end

    -- Collect unique options helper (used in refresh too)
    frame._getUnique = function(field)
        local runs = (BuildCompareDB and BuildCompareDB.runs) or {}
        local set = { ["All"] = true }
        for _, r in ipairs(runs) do
            local v = tostring(r[field] or "Unknown")
            if field == "keyLevel" then v = tostring(r.keyLevel or 0) end
            set[v] = true
        end
        local list = {}
        for k in pairs(set) do table.insert(list, k) end
        table.sort(list)
        return list
    end

    local instBtn = MakeFilterButton(frame.filterBar, "Instance", 
        function() return filterInstance end, 
        function(v) filterInstance = v end,
        function() return frame._getUnique("instance") end)
    instBtn:SetPoint("LEFT", frame.filterBar, "LEFT", 0, 0)

    local keyBtn = MakeFilterButton(frame.filterBar, "Key", 
        function() return filterKeyLevel end, 
        function(v) filterKeyLevel = v end,
        function() return frame._getUnique("keyLevel") end)
    keyBtn:SetPoint("LEFT", instBtn, "RIGHT", 150, 0)

    local buildBtn = MakeFilterButton(frame.filterBar, "Build", 
        function() return filterBuild end, 
        function(v) filterBuild = v end,
        function() return frame._getUnique("buildLabel") end)
    buildBtn:SetPoint("LEFT", keyBtn, "RIGHT", 150, 0)

    local resetBtn = CreateFrame("Button", nil, frame.filterBar, "UIPanelButtonTemplate")
    resetBtn:SetSize(60, 20)
    resetBtn:SetPoint("LEFT", buildBtn, "RIGHT", 150, 0)
    resetBtn:SetText("Reset")
    resetBtn:SetScript("OnClick", function()
        filterInstance, filterKeyLevel, filterBuild = "All", "All", "All"
        selectedForCompare = {}
        BuildCompare_RefreshUI()
    end)

    -- List container
    local listFrame = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    listFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -82)
    listFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 120)  -- leave room for compare panel

    scroll = CreateFrame("ScrollFrame", nil, listFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)

    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(560, 1)
    scroll:SetScrollChild(content)

    frame.rows = {}

    -- Bottom action buttons
    local btnRecord = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnRecord:SetSize(120, 22)
    btnRecord:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 90)
    btnRecord:SetText("Record Current")
    btnRecord:SetScript("OnClick", function()
        StaticPopupDialogs["BUILDCOMPARE_LABEL"] = {
            text = "Enter build label (or leave for Auto):",
            button1 = "Save",
            button2 = "Cancel",
            hasEditBox = 1,
            OnAccept = function(self)
                local label = self.editBox:GetText()
                BuildCompare_RecordCurrentRun(label ~= "" and label or nil)
            end,
            EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
        }
        StaticPopup_Show("BUILDCOMPARE_LABEL")
    end)

    local btnRefresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnRefresh:SetSize(70, 22)
    btnRefresh:SetPoint("LEFT", btnRecord, "RIGHT", 6, 0)
    btnRefresh:SetText("Refresh")
    btnRefresh:SetScript("OnClick", function() BuildCompare_RefreshUI() end)

    local btnClear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnClear:SetSize(70, 22)
    btnClear:SetPoint("LEFT", btnRefresh, "RIGHT", 6, 0)
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

    local btnClose = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnClose:SetSize(50, 22)
    btnClose:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 90)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() frame:Hide() end)

    -- Detailed Comparison Panel (better table)
    frame.comparePanel = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    frame.comparePanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
    frame.comparePanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)
    frame.comparePanel:SetHeight(75)

    frame.compareTitle = frame.comparePanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.compareTitle:SetPoint("TOPLEFT", frame.comparePanel, "TOPLEFT", 6, -4)
    frame.compareTitle:SetText("Comparison (select 2+ runs above with 'Sel'):")

    frame.compareText = frame.comparePanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.compareText:SetPoint("TOPLEFT", frame.comparePanel, "TOPLEFT", 6, -18)
    frame.compareText:SetPoint("RIGHT", frame.comparePanel, "RIGHT", -6, 0)
    frame.compareText:SetJustifyH("LEFT")
    frame.compareText:SetText("No runs selected for comparison.")

    frame:Hide()
    return frame
end

-- Filter runs based on current filter state + include new metrics
local function GetFilteredRuns()
    local allRuns = (BuildCompareDB and BuildCompareDB.runs) or {}
    local filtered = {}
    for i = #allRuns, 1, -1 do  -- recent first
        local r = allRuns[i]
        local instMatch = (filterInstance == "All" or tostring(r.instance or "Unknown") == filterInstance)
        local keyMatch = (filterKeyLevel == "All" or tostring(r.keyLevel or 0) == filterKeyLevel)
        local buildMatch = (filterBuild == "All" or tostring(r.buildLabel or "") == filterBuild)
        if instMatch and keyMatch and buildMatch then
            table.insert(filtered, r)
        end
    end
    return filtered
end

function BuildCompare_RefreshUI()
    if not frame then BuildCompare_CreateMainFrame() end
    if not content then return end

    -- Clear old rows
    for _, row in ipairs(frame.rows or {}) do row:Hide() end
    frame.rows = {}

    local runs = GetFilteredRuns()
    local y = 0

    -- Build list (capped)
    local maxShow = 18
    for i = 1, math.min(#runs, maxShow) do
        local run = runs[i]
        local row = CreateBarRow(content, #frame.rows + 1, run)

        -- Enhanced text with new metrics
        local dtStr = string.format("DT: %d (%.0f)", run.dt or 0, run.dtps or 0)
        local hStr = string.format("Heal: %d", run.healing or 0)
        local absStr = string.format("Abs: %d", run.absorbs or 0)
        local cdStr = string.format("CDs: %s", BuildCompare_FormatDefensives(run))
        row.text:SetText(dtStr .. " | " .. hStr .. " | " .. absStr .. " | " .. cdStr)

        row.buildLabel:SetText(BuildCompare_GetRunLabel(run) or run.buildLabel or "?")

        -- Bar scale relative to filtered list max DT
        local maxDT = 1
        for _, r in ipairs(runs) do if (r.dt or 0) > maxDT then maxDT = r.dt end end
        row.dtBar:SetMinMaxValues(0, maxDT)
        row.dtBar:SetValue(run.dt or 0)

        -- Pre-select state
        if selectedForCompare[run.id] then
            row.selectBtn:SetText("X")
        else
            row.selectBtn:SetText("Sel")
        end

        table.insert(frame.rows, row)
        y = y + 28
    end

    content:SetHeight(math.max(220, y + 10))

    -- Update detailed comparison table / text
    local selectedList = {}
    for id, r in pairs(selectedForCompare) do table.insert(selectedList, r) end

    if #selectedList >= 2 then
        -- Show a simple side-by-side table for first 2 (extendable)
        local a = selectedList[1]
        local b = selectedList[2] or a

        local lines = {}
        table.insert(lines, string.format("Run A: %s   vs   Run B: %s", BuildCompare_GetRunLabel(a), BuildCompare_GetRunLabel(b)))

        -- DT row
        local dtDiff = BuildCompare_FormatPercentDiff(a.dt or 0, b.dt or 0)
        table.insert(lines, string.format("DT: %d vs %d   %s", a.dt or 0, b.dt or 0, dtDiff))

        local dtpsDiff = BuildCompare_FormatPercentDiff(a.dtps or 0, b.dtps or 0)
        table.insert(lines, string.format("DTPS: %.1f vs %.1f   %s", a.dtps or 0, b.dtps or 0, dtpsDiff))

        -- Healing
        local hDiff = BuildCompare_FormatPercentDiff(a.healing or 0, b.healing or 0)
        table.insert(lines, string.format("Heal: %d vs %d   %s", a.healing or 0, b.healing or 0, hDiff))

        -- Absorbs
        local absDiff = BuildCompare_FormatPercentDiff(a.absorbs or 0, b.absorbs or 0)
        table.insert(lines, string.format("Absorbs: %d vs %d   %s", a.absorbs or 0, b.absorbs or 0, absDiff))

        -- CDs
        table.insert(lines, string.format("Def CDs used: %s vs %s", BuildCompare_FormatDefensives(a), BuildCompare_FormatDefensives(b)))

        -- Damage breakdown if present
        local dba = BuildCompare_FormatDamageBreakdown(a)
        local dbb = BuildCompare_FormatDamageBreakdown(b)
        if dba ~= "" or dbb ~= "" then
            table.insert(lines, string.format("Dmg Types: %s  |  %s", dba, dbb))
        end

        -- === Stat Delta Columns ===
        local sa = a.stats or {}
        local sb = b.stats or {}

        table.insert(lines, "")
        table.insert(lines, "Build Stats (deltas):")
        table.insert(lines, BuildCompare_GetStatDeltaHeader())

        table.insert(lines, BuildCompare_FormatStatDelta("Mastery", sa.mastery, sb.mastery))
        table.insert(lines, BuildCompare_FormatStatDelta("Mastery %", sa.masteryPct, sb.masteryPct))
        table.insert(lines, BuildCompare_FormatStatDelta("Crit", sa.crit, sb.crit))
        table.insert(lines, BuildCompare_FormatStatDelta("Crit %", sa.critPct, sb.critPct))
        table.insert(lines, BuildCompare_FormatStatDelta("Haste", sa.haste, sb.haste))
        table.insert(lines, BuildCompare_FormatStatDelta("Haste %", sa.hastePct, sb.hastePct))
        table.insert(lines, BuildCompare_FormatStatDelta("Vers", sa.vers, sb.vers))
        table.insert(lines, BuildCompare_FormatStatDelta("Vers %", sa.versPct, sb.versPct))

        if sa.specName or sb.specName then
            table.insert(lines, string.format("%-12s | %8s vs %8s |", "Spec", sa.specName or sa.spec or "?", sb.specName or sb.spec or "?"))
        end

        -- === Talent Comparison ===
        local ta = a.talents or { loadoutName = "?", selected = {} }
        local tb = b.talents or { loadoutName = "?", selected = {} }

        table.insert(lines, "")
        table.insert(lines, "Talents (same gear, different talents comparison):")
        table.insert(lines, string.format("Loadout A: %s    vs    Loadout B: %s", ta.loadoutName or "?", tb.loadoutName or "?"))

        -- Build sets for diff
        local setA = {}
        for _, name in ipairs(ta.selected or {}) do setA[name] = true end
        local setB = {}
        for _, name in ipairs(tb.selected or {}) do setB[name] = true end

        local onlyA = {}
        local onlyB = {}
        for name in pairs(setA) do
            if not setB[name] then table.insert(onlyA, name) end
        end
        for name in pairs(setB) do
            if not setA[name] then table.insert(onlyB, name) end
        end

        if #onlyA > 0 then
            table.insert(lines, "Talents only in A: " .. table.concat(onlyA, ", "))
        end
        if #onlyB > 0 then
            table.insert(lines, "Talents only in B: " .. table.concat(onlyB, ", "))
        end
        if #onlyA == 0 and #onlyB == 0 then
            table.insert(lines, "Talent selections are identical between the two runs.")
        end

        frame.compareText:SetText(table.concat(lines, "\n"))
    else
        frame.compareText:SetText("Select 2+ runs using the 'Sel' buttons on the left of list rows to see detailed side-by-side comparison (performance + build stat deltas with % diffs).")
    end
end

function BuildCompare_ShowUI()
    local f = BuildCompare_CreateMainFrame()
    f:Show()
    BuildCompare_RefreshUI()
end

-- Make sure global hook from Core works
_G.BuildCompare_ShowUI = BuildCompare_ShowUI
_G.BuildCompare_RefreshUI = BuildCompare_RefreshUI
