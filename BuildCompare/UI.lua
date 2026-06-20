-- BuildCompare/UI.lua
-- In-game GUI that mimics a damage meter with comparison readouts and % diffs.

local AddonName, _ = ...

local frame = nil
local scroll = nil
local content = nil

local function CreateBarRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(22)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4 - (index-1)*24)
    row:SetPoint("RIGHT", parent, "RIGHT", -4, 0)

    -- Background bar (DT)
    row.dtBar = CreateFrame("StatusBar", nil, row)
    row.dtBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.dtBar:SetStatusBarColor(0.8, 0.2, 0.2)  -- red-ish for damage taken
    row.dtBar:SetMinMaxValues(0, 100)
    row.dtBar:SetValue(50)
    row.dtBar:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.dtBar:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.dtBar:SetHeight(18)

    -- Text overlay
    row.text = row.dtBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", row.dtBar, "LEFT", 4, 0)
    row.text:SetText("DT: 12345 (456 DTPS)  |  Heal: 2345")

    row.buildLabel = row.dtBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.buildLabel:SetPoint("RIGHT", row.dtBar, "RIGHT", -4, 0)
    row.buildLabel:SetText("mastery v1")

    return row
end

function BuildCompare_CreateMainFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "BuildCompareFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(520, 380)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    frame.title:SetPoint("LEFT", frame.TitleBg, "LEFT", 8, 0)
    frame.title:SetText("BuildCompare - Tank Run Comparison")

    -- Instructions
    frame.instructions = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.instructions:SetPoint("TOP", frame, "TOP", 0, -30)
    frame.instructions:SetText("After a run: /bc record \"my mastery build\"   |   Compare runs below. Data from built-in C_DamageMeter.")

    -- Comparison container (simple list of recent runs + manual compare)
    local listFrame = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    listFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -60)
    listFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 50)

    scroll = CreateFrame("ScrollFrame", nil, listFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)

    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(460, 1)
    scroll:SetScrollChild(content)

    frame.rows = {}

    -- Bottom buttons
    local btnRecord = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnRecord:SetSize(120, 24)
    btnRecord:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 14)
    btnRecord:SetText("Record Current Run")
    btnRecord:SetScript("OnClick", function()
        -- Simple prompt for label
        StaticPopupDialogs["BUILDCOMPARE_LABEL"] = {
            text = "Enter build label (e.g. mastery heavy +10):",
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
    btnRefresh:SetSize(80, 24)
    btnRefresh:SetPoint("LEFT", btnRecord, "RIGHT", 8, 0)
    btnRefresh:SetText("Refresh")
    btnRefresh:SetScript("OnClick", function() BuildCompare_RefreshUI() end)

    local btnClear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnClear:SetSize(80, 24)
    btnClear:SetPoint("LEFT", btnRefresh, "RIGHT", 8, 0)
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
    btnClose:SetSize(60, 24)
    btnClose:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 14)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() frame:Hide() end)

    -- Comparison summary area (simple text for now; expand later)
    frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.summary:SetPoint("BOTTOM", frame, "BOTTOM", 0, 38)
    frame.summary:SetText("Select two runs above or use /bc record then compare. % diffs shown in list.")

    frame:Hide()
    return frame
end

function BuildCompare_RefreshUI()
    if not frame then BuildCompare_CreateMainFrame() end
    if not content then return end

    -- Clear old rows
    for _, row in ipairs(frame.rows or {}) do row:Hide() end
    frame.rows = {}

    local runs = (BuildCompareDB and BuildCompareDB.runs) or {}
    local y = 0

    -- Show most recent first
    for i = #runs, math.max(1, #runs - 19), -1 do   -- last ~20
        local run = runs[i]
        local row = CreateBarRow(content, #frame.rows + 1)

        local dtStr = string.format("DT: %d (%.0f DTPS)", run.dt or 0, run.dtps or 0)
        local hStr = string.format("Heal: %d (%.0f HPS)", run.healing or 0, run.hps or 0)
        row.text:SetText(dtStr .. "  |  " .. hStr)
        row.buildLabel:SetText(BuildCompare_GetRunLabel(run) or run.buildLabel or "?")

        -- Simple bar scale (normalize to max DT in list for visual)
        local maxDT = 1
        for _, r in ipairs(runs) do if (r.dt or 0) > maxDT then maxDT = r.dt end end
        row.dtBar:SetMinMaxValues(0, maxDT)
        row.dtBar:SetValue(run.dt or 0)

        table.insert(frame.rows, row)
        y = y + 26
    end

    content:SetHeight(math.max(200, y + 10))

    -- Update summary with last two runs if present
    if #runs >= 2 then
        local a = runs[#runs-1]
        local b = runs[#runs]
        local dtDiff = BuildCompare_FormatPercentDiff(a.dt, b.dt)
        local hDiff = BuildCompare_FormatPercentDiff(a.healing, b.healing)
        frame.summary:SetText(string.format("Last vs prev: DT %s   |   Healing %s   (lower DT = better for tank)", dtDiff, hDiff))
    else
        frame.summary:SetText("Record at least two runs to see % differences. Data source: C_DamageMeter (built-in).")
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
