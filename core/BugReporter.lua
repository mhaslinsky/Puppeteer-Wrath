PTBugReporter = {}
PTUtil.SetEnvironment(PTBugReporter)
local _G = getfenv(0)

local MAX_BUG_LOG = 20
local DEDUPE_WINDOW = 5
local ISSUE_URL = "https://github.com/mhaslinsky/Puppeteer-Wrath/issues/new"

local dialog
local previousHandler
local handlerInstalled = false

local function isPuppeteerError(msg)
    if type(msg) ~= "string" then return false end
    if string.find(msg, "AddOns\\Puppeteer\\", 1, true) then return true end
    if string.find(msg, "AddOns/Puppeteer/", 1, true) then return true end
    return false
end

local function ensureLog()
    if not _G.PTBugLog then _G.PTBugLog = {} end
    if not _G.PTBugLog.Errors then _G.PTBugLog.Errors = {} end
    return _G.PTBugLog
end

local function pushError(msg)
    local log = ensureLog()
    local now = _G.time and _G.time() or 0
    local errors = log.Errors
    local last = errors[table.getn(errors)]
    if last and last.message == msg and (now - (last.lastTime or now)) < DEDUPE_WINDOW then
        last.count = (last.count or 1) + 1
        last.lastTime = now
        return
    end
    table.insert(errors, {
        message = msg,
        firstTime = now,
        lastTime = now,
        count = 1,
    })
    while table.getn(errors) > MAX_BUG_LOG do
        table.remove(errors, 1)
    end
end

function CaptureError(msg)
    if previousHandler then
        local ok, err = pcall(previousHandler, msg)
        if not ok and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("[Puppeteer] chained error handler failed: "..tostring(err))
        end
    end
    if isPuppeteerError(msg) then
        pcall(pushError, tostring(msg))
    end
end

function InstallErrorHandler()
    if handlerInstalled then return end
    if _G.geterrorhandler then
        previousHandler = _G.geterrorhandler()
    end
    if previousHandler == CaptureError then
        previousHandler = nil
    end
    _G.seterrorhandler(CaptureError)
    handlerInstalled = true
end

local function captureContext()
    local log = ensureLog()
    local context = {}

    context.puppeteerVersion = tostring(_G.Puppeteer and _G.Puppeteer.VERSION or "unknown")

    local version, build, _, tocversion = GetBuildInfo()
    context.wowVersion = tostring(version or "?")
    context.wowBuild = tostring(build or "?")
    context.tocVersion = tostring(tocversion or "?")

    context.realm = GetRealmName() or "?"

    local _, class = UnitClass("player")
    context.class = class or "?"
    context.level = UnitLevel("player") or 0
    context.name = UnitName("player") or "?"

    if GetNumRaidMembers() > 0 then
        context.groupState = "Raid("..GetNumRaidMembers()..")"
    elseif GetNumPartyMembers() > 0 then
        context.groupState = "Party("..GetNumPartyMembers()..")"
    else
        context.groupState = "Solo"
    end

    local addons = {}
    local count = _G.GetNumAddOns and _G.GetNumAddOns() or 0
    for i = 1, count do
        local loaded = _G.IsAddOnLoaded and _G.IsAddOnLoaded(i)
        if loaded then
            local name = GetAddOnInfo(i)
            local v = _G.GetAddOnMetadata and _G.GetAddOnMetadata(i, "Version") or ""
            if v and v ~= "" then
                table.insert(addons, name.." "..v)
            else
                table.insert(addons, name)
            end
        end
    end
    context.addons = addons

    log.Context = context
    return context
end

local function fmtTimestamp(t)
    if not t or t == 0 then return "?" end
    if _G.date then
        local ok, s = pcall(_G.date, "%H:%M:%S", t)
        if ok and s then return s end
    end
    return tostring(t)
end

local function buildReport()
    local log = ensureLog()
    local ctx = log.Context or captureContext()
    local lines = {}
    table.insert(lines, "**Puppeteer**: "..ctx.puppeteerVersion)
    table.insert(lines, "**WoW**: "..ctx.wowVersion.." build "..ctx.wowBuild.." (interface "..ctx.tocVersion..")")
    table.insert(lines, "**Character**: "..ctx.name.." / "..ctx.class.." "..ctx.level.." @ "..ctx.realm)
    table.insert(lines, "**Group**: "..ctx.groupState)
    table.insert(lines, "")
    table.insert(lines, "**Active addons** ("..table.getn(ctx.addons or {}).."):")
    for _, a in ipairs(ctx.addons or {}) do
        table.insert(lines, "- "..a)
    end
    table.insert(lines, "")

    local errors = log.Errors or {}
    local nErr = table.getn(errors)
    table.insert(lines, "**Recent Puppeteer errors** ("..nErr.." captured, oldest first):")
    if nErr == 0 then
        table.insert(lines, "_(none)_")
    else
        table.insert(lines, "```")
        for _, e in ipairs(errors) do
            local stamp = fmtTimestamp(e.lastTime)
            local rep = (e.count and e.count > 1) and " (x"..e.count..")" or ""
            table.insert(lines, "["..stamp.."]"..rep.." "..(e.message or "?"))
        end
        table.insert(lines, "```")
    end
    table.insert(lines, "")
    table.insert(lines, "**Steps to reproduce**:")
    table.insert(lines, "1. ")
    table.insert(lines, "")
    table.insert(lines, "**Expected**:")
    table.insert(lines, "")
    table.insert(lines, "**Actual**:")
    table.insert(lines, "")

    return table.concat(lines, "\n")
end

local function createDialog()
    if dialog then return dialog end

    local f = CreateFrame("Frame", "PTBugReporterDialog", UIParent)
    f:SetWidth(580)
    f:SetHeight(440)
    f:SetPoint("CENTER", UIParent, "CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:Hide()

    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    f:SetScript("OnMouseDown", function()
        if arg1 == "LeftButton" then f:StartMoving() end
    end)
    f:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("Puppeteer Bug Report")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    local instructions = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    instructions:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -42)
    instructions:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -42)
    instructions:SetJustifyH("LEFT")
    instructions:SetText("Fill in Steps/Expected/Actual below, click |cffffd200Select all|r, then press |cffffd200Ctrl-C|r to copy. Paste into the GitHub issue at:")
    instructions:SetTextColor(0.9, 0.9, 0.9)
    instructions:SetHeight(36)

    local urlBox = CreateFrame("EditBox", "PTBugReporterUrlBox", f)
    urlBox:SetFontObject(ChatFontNormal)
    urlBox:SetTextColor(0.5, 0.85, 1)
    urlBox:SetAutoFocus(false)
    urlBox:SetHeight(20)
    urlBox:SetMaxLetters(0)
    urlBox:SetPoint("TOPLEFT", instructions, "BOTTOMLEFT", 0, -8)
    urlBox:SetPoint("TOPRIGHT", instructions, "BOTTOMRIGHT", 0, -8)
    urlBox:SetText(ISSUE_URL)
    urlBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    urlBox:SetScript("OnEditFocusGained", function() this:HighlightText() end)
    urlBox:SetScript("OnTextChanged", function()
        if this:GetText() ~= ISSUE_URL then this:SetText(ISSUE_URL) end
    end)

    local scrollFrame = CreateFrame("ScrollFrame", "PTBugReporterScroll", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", urlBox, "BOTTOMLEFT", 0, -16)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 56)

    local scrollBg = CreateFrame("Frame", nil, f)
    scrollBg:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", -4, 4)
    scrollBg:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", 4, -4)
    scrollBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    scrollBg:SetBackdropColor(0, 0, 0, 0.6)
    scrollBg:SetFrameLevel(scrollFrame:GetFrameLevel() - 1)

    local editBox = CreateFrame("EditBox", "PTBugReporterEditBox", scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetMaxLetters(0)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(520)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    editBox:SetScript("OnTextChanged", function()
        local sb = getglobal("PTBugReporterScrollScrollBar")
        if not sb then return end
        scrollFrame:UpdateScrollChildRect()
        local _, max = sb:GetMinMaxValues()
        sb.prevMaxValue = sb.prevMaxValue or max
        if math.abs(sb.prevMaxValue - sb:GetValue()) <= 1 then
            sb:SetValue(max)
        end
        if max ~= sb.prevMaxValue then
            sb.prevMaxValue = max
        end
    end)
    scrollFrame:SetScrollChild(editBox)

    local closeBottom = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBottom:SetWidth(100) closeBottom:SetHeight(22)
    closeBottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 16)
    closeBottom:SetText("Close")
    closeBottom:SetScript("OnClick", function() f:Hide() end)

    local selectAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    selectAllBtn:SetWidth(110) selectAllBtn:SetHeight(22)
    selectAllBtn:SetPoint("RIGHT", closeBottom, "LEFT", -8, 0)
    selectAllBtn:SetText("Select all")
    selectAllBtn:SetScript("OnClick", function()
        editBox:SetFocus()
        editBox:HighlightText()
    end)

    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetWidth(130) refreshBtn:SetHeight(22)
    refreshBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 16)
    refreshBtn:SetText("Refresh report")
    refreshBtn:SetScript("OnClick", function() Refresh() end)

    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetWidth(130) clearBtn:SetHeight(22)
    clearBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 8, 0)
    clearBtn:SetText("Clear error log")
    clearBtn:SetScript("OnClick", function() ClearErrors() end)

    f.editBox = editBox
    f.scrollFrame = scrollFrame
    dialog = f
    return f
end

function Refresh()
    if not dialog then return end
    captureContext()
    dialog.editBox:SetText(buildReport())
    dialog.editBox:SetCursorPosition(0)
end

function ClearErrors()
    local log = ensureLog()
    log.Errors = {}
    Refresh()
    if _G.Puppeteer and _G.Puppeteer.Info then
        _G.Puppeteer.Info("Bug-report error log cleared.")
    end
end

function OpenDialog()
    createDialog()
    captureContext()
    dialog.editBox:SetText(buildReport())
    dialog.editBox:SetCursorPosition(0)
    dialog:Show()
end

pcall(InstallErrorHandler)
