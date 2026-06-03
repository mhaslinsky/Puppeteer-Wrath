-- Phase 5 / Slice 1: secure click-cast + secure keybind dispatch (Wrath 3.3.5a).
--
-- Architecture (read .research/BINDINGS-AND-CLICK-CAST.md before editing):
--   1. Per-frame overlay: every Puppeteer unit frame gets a button inheriting both
--      SecureActionButtonTemplate (for click-cast) and SecureHandlerEnterLeaveTemplate
--      (for hover-driven keybind override). Carries unit="<frame's unit>" and per-
--      modifier type/spell attributes. Direct clicks dispatch through WoW's secure
--      code, no taint, works in combat. The unit attribute also makes WoW set its
--      `mouseover` token when the cursor enters this button -- which is what the
--      keybind path needs.
--   2. Hidden keybind buttons: one or more SecureActionButtonTemplate buttons carry
--      static [@mouseover] macrotext per modifier slot. They're the *target* of
--      hover-scoped overrides installed by the per-frame overlay's _onenter snippet.
--      The macro's [@mouseover] resolves at click-time against whatever frame the
--      cursor is over.
--   3. Binding registry: a SecureFrameTemplate Frame whose attributes describe the
--      current set of (key, button-name, click) triples. Each per-frame overlay holds
--      a FrameRef to it; the _onenter snippet walks the registry and calls
--      self:SetBindingClick() for each entry. _onleave calls self:ClearBindings().
--      Both run in WoW's restricted secure env -- not subject to combat lockdown --
--      so hover toggling works mid-fight. (The registry MUST inherit a secure
--      template; a plain Frame gives "Invalid frame handle" inside the snippet,
--      because only secure-template frames get a snippet-handle wrapper.) Lua-side
--      install/clear via SetOverrideBindingClick was tried first and bounced off
--      combat protection ("prevented the call of the secure function
--      'ClearOverrideBindings()'"); the snippet pattern is the same approach
--      Clique-on-Wrath uses.
--
-- Why overrides instead of permanent SetBindingClick: SetBindingClick replaces the
-- key's base binding for the whole session, which made the action bar's keybind
-- label disappear (e.g. Numpad7 = PW:Fortitude on bar, also bound in Puppeteer ->
-- bar label vanished even though the cast still worked). The hover-scoped override
-- layers on top of the base binding without clobbering it; ClearBindings on
-- _onleave restores the bar's label and dispatch instantly.
--
-- Slice 1 scope: SPELL bindings only. Other binding types (ACTION/MACRO/SCRIPT/MULTI)
-- fall through to the existing insecure path -- protected ones won't work in combat,
-- which is the same limitation as before slice 1.

PTUtil.SetEnvironment(Puppeteer)
local _G = getfenv(0)
local util = PTUtil

SecureClickCast = {}

-- Modifier name (PTBindings format) -> WoW secure attribute prefix.
-- Wrath requires strict order: alt-, ctrl-, shift-.
local MODIFIER_PREFIXES = {
    ["None"] = "",
    ["Shift"] = "shift-",
    ["Control"] = "ctrl-",
    ["Alt"] = "alt-",
    ["Shift+Control"] = "ctrl-shift-",
    ["Shift+Alt"] = "alt-shift-",
    ["Control+Alt"] = "alt-ctrl-",
    ["Shift+Control+Alt"] = "alt-ctrl-shift-",
}
local ALL_MODIFIERS = {"None", "Shift", "Control", "Alt",
    "Shift+Control", "Shift+Alt", "Control+Alt", "Shift+Control+Alt"}

local MOUSE_BUTTON_TO_VARIANT = {
    ["LeftButton"] = 1, ["RightButton"] = 2, ["MiddleButton"] = 3,
    ["Button4"] = 4, ["Button5"] = 5,
}
local VARIANT_TO_VIRTUAL = {
    [1] = "LeftButton", [2] = "RightButton", [3] = "MiddleButton",
    [4] = "Button4", [5] = "Button5",
}
local MAX_VARIANTS_PER_BUTTON = 5

local keybindButtons = {}    -- ordered list of secure keybind buttons
local keyToSlot = {}         -- key name -> {button=<frame>, variant=1..5, hasBinding=bool}
local overlaysByFrame = {}   -- unitFrame -> overlay button
local bindingRegistry        -- plain Frame; (key, btnName, click) triples as attrs. Read by snippets.
local pendingRefreshOnRegen = false
local initialized = false


-- ---------- Restricted-env snippets ----------
-- Run inside WoW's secure environment when the overlay is hovered/unhovered.
-- 'self' is the overlay button (SecureHandlerEnterLeaveTemplate). The bindings
-- it installs are owned by the overlay, so self:ClearBindings() on leave
-- removes only those (does not touch other addons' bindings).
local SNIPPET_ONENTER = [[
    local r = self:GetFrameRef("registry")
    if not r then return end
    local n = r:GetAttribute("keyCount") or 0
    for i = 1, n do
        local key = r:GetAttribute("key"..i)
        local btn = r:GetAttribute("btnName"..i)
        local click = r:GetAttribute("click"..i)
        if key and btn and click then
            self:SetBindingClick(true, key, btn, click)
        end
    end
]]
local SNIPPET_ONLEAVE = [[
    self:ClearBindings()
]]


-- ---------- Feature flag ----------

function SecureClickCast.IsEnabled()
    if not PTGlobalOptions then return true end
    if PTGlobalOptions.UseSecureClickCast == nil then return true end
    return PTGlobalOptions.UseSecureClickCast
end

-- "AnyUp" / "AnyDown" derived from PTOptions.CastWhen. Single edge per click
-- to avoid the AnyDown+AnyUp double-dispatch (#14, #15); the user's CastWhen
-- preference picks which edge.
function SecureClickCast.GetClickEdge()
    if PTOptions and PTOptions.CastWhen == "Mouse Down" then
        return "AnyDown"
    end
    return "AnyUp"
end

-- Re-register the click edge on every existing overlay. Read by both the
-- CastWhen settings dropdown (live propagation) and RefreshAll (so a refresh
-- deferred by combat picks up the current CastWhen on flush).
local function applyClickEdgeToOverlays()
    local edge = SecureClickCast.GetClickEdge()
    for _, overlay in pairs(overlaysByFrame) do
        overlay:RegisterForClicks(edge)
    end
end

function SecureClickCast.RefreshClicks()
    -- RegisterForClicks on a SecureActionButtonTemplate is combat-protected;
    -- silently dropped (or taints) inside lockdown. Defer to PLAYER_REGEN_
    -- ENABLED via the existing pending flag; RefreshAll's flush at the end
    -- of combat invokes applyClickEdgeToOverlays, so the edge update lands
    -- without /reload. Settings panel auto-closes on PLAYER_REGEN_DISABLED
    -- (gui/Settings.lua), but this guard covers the race where the dropdown
    -- click lands on the same frame combat begins.
    if InCombatLockdown() then
        pendingRefreshOnRegen = true
        return
    end
    applyClickEdgeToOverlays()
end


-- ---------- Binding translation ----------

-- Action binding names that map cleanly to native secure dispatch (no addon Lua).
-- Anything not listed here (Menu, Role*, etc.) needs the insecure OnClick fallback
-- and won't work for protected calls in combat.
local SECURE_ACTIONS = {
    ["Target"] = "target",
    ["Assist"] = "assist",
    ["Follow"] = "follow",
}

-- Build a macro line for one binding. Tries [@mouseover] first; falls through to
-- the player's current target when no valid mouseover exists. The fall-through is
-- mostly belt-and-suspenders -- normally the override binding is only installed
-- while hovering a Puppeteer frame, so [@mouseover] resolves cleanly. But because
-- ClearOverrideBindings is combat-protected on 3.3.5a, the override can persist
-- past hover-leave during combat; the fall-through means a keypress in that state
-- still casts on the current target instead of failing silently. Returns nil if the
-- binding can't be expressed via macrotext (Menu, Role*, etc.).
-- targetClause is ""/",help,nodead"/",harm,nodead".
-- fallbackClause is ""/"help,nodead"/"harm,nodead" (no leading comma; standalone).
local function bindingToMacroLine(binding, targetClause, fallbackClause)
    if not binding or not binding.Type or not binding.Data or binding.Data == "" then
        return nil
    end
    local conditional = "[@mouseover" .. targetClause .. "]"
    if fallbackClause and fallbackClause ~= "" then
        conditional = conditional .. "[" .. fallbackClause .. "]"
    end
    if binding.Type == "SPELL" then
        return "/cast " .. conditional .. " " .. binding.Data
    elseif binding.Type == "ACTION" then
        local action = SECURE_ACTIONS[binding.Data]
        if not action then return nil end
        return "/" .. action .. " " .. conditional
    end
    return nil
end

-- Synthesize a multi-line macrotext for one (key, modifier) slot covering both
-- friendly and hostile bindings. Returns nil if neither side is expressible.
local function buildMacrotextForSlot(modifierName, buttonName)
    local friendly = GetBinding("Friendly", modifierName, buttonName)
    local hostile = GetBinding("Hostile", modifierName, buttonName)

    local lines = {}
    local fLine = bindingToMacroLine(friendly, ",help,nodead", "help,nodead")
    local hLine = bindingToMacroLine(hostile, ",harm,nodead", "harm,nodead")
    if fLine then table.insert(lines, fLine) end
    if hLine then table.insert(lines, hLine) end

    if table.getn(lines) == 0 then return nil end
    return table.concat(lines, "\n")
end

-- For a per-frame overlay (unit baked in via the unit attribute), translate one
-- binding into a {type=..., spell=...} or {type=..., macrotext=...} spec to be
-- written to type<N> / spell<N> / macrotext<N> attributes. Returns nil if the
-- binding can't be securely dispatched (caller should fall through to insecure).
local function bindingToFrameSpec(binding)
    if not binding or not binding.Type or not binding.Data or binding.Data == "" then
        return nil
    end
    if binding.Type == "SPELL" then
        return {type = "spell", spell = binding.Data}
    elseif binding.Type == "ACTION" then
        local action = SECURE_ACTIONS[binding.Data]
        if action then return {type = action} end
    end
    return nil
end


-- ---------- Per-frame overlay ----------

-- Forward an event from the secure overlay to the original button's script so the
-- existing tooltip / mouseover-state / .pressed bookkeeping keeps working.
local function forwardScript(overlay, original, scriptName)
    overlay:SetScript(scriptName, function()
        local fn = original:GetScript(scriptName)
        if fn then fn() end
    end)
end

-- Wipe and rewrite the (unit, type<N>, spell<N>) attribute set for the
-- per-frame overlay. Bindings whose Type can't be securely dispatched (Menu,
-- Role*, Script, Macro, Multi) leave their slot empty here; the OnClick
-- fallback hook routes those clicks through to the legacy insecure handler.
local function writeUnitAttrs(btn, unit, isHostile)
    btn:SetAttribute("unit", unit)

    -- Wipe stale attrs across all 8 modifiers x 5 variants.
    for _, modName in ipairs(ALL_MODIFIERS) do
        local prefix = MODIFIER_PREFIXES[modName]
        for variant = 1, MAX_VARIANTS_PER_BUTTON do
            btn:SetAttribute(prefix .. "type" .. variant, nil)
            btn:SetAttribute(prefix .. "spell" .. variant, nil)
        end
    end

    local side = isHostile and "Hostile" or "Friendly"
    for _, modName in ipairs(ALL_MODIFIERS) do
        local prefix = MODIFIER_PREFIXES[modName]
        for buttonName, variant in pairs(MOUSE_BUTTON_TO_VARIANT) do
            local spec = bindingToFrameSpec(GetBinding(side, modName, buttonName))
            if spec then
                btn:SetAttribute(prefix .. "type" .. variant, spec.type)
                if spec.spell then
                    btn:SetAttribute(prefix .. "spell" .. variant, spec.spell)
                end
            end
        end
    end
end

-- Install a HookScript that fires AFTER the secure template's OnClick. If the
-- (modifier, variant) slot has a secure type set, the cast already happened --
-- skip to avoid double-firing. Otherwise fall through to the legacy insecure
-- handler so unsupported binding types (Menu, Role*, Script, Macro, Multi)
-- still work OOC. Must use HookScript, not SetScript -- see Bug 7.
local function installFallbackHook(btn, unitFrame)
    btn:HookScript("OnClick", function()
        local clickName = arg1
        if not clickName then return end
        local variant = MOUSE_BUTTON_TO_VARIANT[clickName]
        local prefix = ""
        local mod = util.GetKeyModifier()
        if mod and mod ~= "None" then
            prefix = MODIFIER_PREFIXES[mod] or ""
        end
        if variant and btn:GetAttribute(prefix .. "type" .. variant) then
            return  -- already handled by secure dispatch
        end
        local unit = unitFrame:GetUnit()
        if unit then UnitFrame_OnClick(clickName, unit, unitFrame) end
    end)
end

local function refreshPerFrameAttrs(overlay, unit)
    if InCombatLockdown() then
        pendingRefreshOnRegen = true
        return
    end
    writeUnitAttrs(overlay, unit, UnitCanAttack("player", unit))
end

function SecureClickCast.AttachOverlay(unitFrame)
    if not SecureClickCast.IsEnabled() then return end
    if overlaysByFrame[unitFrame] then return end

    local existing = unitFrame.button
    if not existing then return end

    -- Dual template: Action for click-cast, EnterLeave for the snippet-driven
    -- hover override. Setting attributes / FrameRef / snippets on this button
    -- is combat-protected, but AttachOverlay runs at addon-load (OOC).
    local overlay = CreateFrame("Button", nil, existing,
        "SecureActionButtonTemplate,SecureHandlerEnterLeaveTemplate")
    overlay:SetAllPoints(existing)
    overlay:SetFrameLevel(existing:GetFrameLevel() + 1)
    -- Single edge per click. AnyDown+AnyUp made SecureActionButton dispatch
    -- the same action twice per click: spell cast on key-down succeeded, the
    -- key-up retry hit the just-started cooldown and surfaced "Spell is not
    -- ready yet" (#14). RMB-on-empty-bind also opened the legacy unit
    -- dropdown on down and closed it on up (#15). Edge follows PTOptions.
    -- CastWhen so a user who chose "Mouse Down" still gets that behavior.
    overlay:RegisterForClicks(SecureClickCast.GetClickEdge())
    overlay:EnableMouse(true)

    -- Wire snippet-based hover override.
    if bindingRegistry then
        overlay:SetFrameRef("registry", bindingRegistry)
    end
    overlay:SetAttribute("_onenter", SNIPPET_ONENTER)
    overlay:SetAttribute("_onleave", SNIPPET_ONLEAVE)

    -- Forward OnEnter/OnLeave to the original button's script so PT.Mouseover and
    -- friends keep updating. HookScript (not SetScript) so we don't clobber the
    -- SecureHandlerEnterLeaveTemplate's OnEnter wiring that fires the snippet.
    overlay:HookScript("OnEnter", function()
        local fn = existing:GetScript("OnEnter")
        if fn then fn() end
    end)
    overlay:HookScript("OnLeave", function()
        local fn = existing:GetScript("OnLeave")
        if fn then fn() end
    end)
    forwardScript(overlay, existing, "OnMouseDown")
    forwardScript(overlay, existing, "OnMouseUp")

    installFallbackHook(overlay, unitFrame)

    overlaysByFrame[unitFrame] = overlay

    refreshPerFrameAttrs(overlay, unitFrame:GetUnit())
end

function SecureClickCast.RefreshOverlay(unitFrame)
    local overlay = overlaysByFrame[unitFrame]
    if not overlay then return end
    refreshPerFrameAttrs(overlay, unitFrame:GetUnit())
end


-- ---------- Hidden keybind buttons ----------

local function newKeybindButton(index)
    local btn = CreateFrame("Button", "PuppeteerKeybindButton" .. index, UIParent,
        "SecureActionButtonTemplate")
    btn:Hide()
    -- Fallback: if no macrotext was set for the (variant, modifier) combo (e.g.
    -- the user bound an unsupported Action like Menu or Role to this key), fire
    -- the legacy insecure handler against the currently-hovered Puppeteer frame.
    -- Won't work over non-Puppeteer frames since PT.Mouseover isn't set there.
    btn:HookScript("OnClick", function()
        local clickName = arg1
        if not clickName then return end
        local variant = MOUSE_BUTTON_TO_VARIANT[clickName]
        local prefix = ""
        local mod = util.GetKeyModifier()
        if mod and mod ~= "None" then
            prefix = MODIFIER_PREFIXES[mod] or ""
        end
        if variant and btn:GetAttribute(prefix .. "type" .. variant) then
            return  -- already handled by secure dispatch
        end
        if Mouseover and MouseoverFrame then
            UnitFrame_OnClick(clickName, Mouseover, MouseoverFrame)
        end
    end)
    return btn
end

local function ensureKeybindCapacity(needed)
    while table.getn(keybindButtons) * MAX_VARIANTS_PER_BUTTON < needed do
        local idx = table.getn(keybindButtons) + 1
        table.insert(keybindButtons, newKeybindButton(idx))
    end
end

-- Build keyToSlot from the current PTOptions.Buttons list (key-style only --
-- mouse buttons are handled by per-frame overlays).
local function rebuildKeyAssignments()
    util.ClearTable(keyToSlot)
    local mouseSet = util.GetAllButtonsSet()
    local keys = {}
    for _, button in ipairs(PTOptions.Buttons) do
        if not mouseSet[button] then
            table.insert(keys, button)
        end
    end
    ensureKeybindCapacity(table.getn(keys))
    for i, key in ipairs(keys) do
        local btnIdx = math.floor((i - 1) / MAX_VARIANTS_PER_BUTTON) + 1
        local variant = ((i - 1) - (btnIdx - 1) * MAX_VARIANTS_PER_BUTTON) + 1
        keyToSlot[key] = {button = keybindButtons[btnIdx], variant = variant}
    end
end

local function refreshKeybindAttrs()
    if InCombatLockdown() then
        pendingRefreshOnRegen = true
        return
    end

    -- Wipe everything first so a removed binding doesn't linger.
    for _, btn in ipairs(keybindButtons) do
        for _, modName in ipairs(ALL_MODIFIERS) do
            local prefix = MODIFIER_PREFIXES[modName]
            for variant = 1, MAX_VARIANTS_PER_BUTTON do
                btn:SetAttribute(prefix .. "type" .. variant, nil)
                btn:SetAttribute(prefix .. "macrotext" .. variant, nil)
            end
        end
    end

    -- Write per-(key, modifier) macrotexts. Track which slots actually got at least
    -- one macrotext so syncBindingRegistry can skip keys with no real binding --
    -- avoids registering empty entries in the snippet's iteration set.
    for keyName, slot in pairs(keyToSlot) do
        slot.hasBinding = nil
        for _, modName in ipairs(ALL_MODIFIERS) do
            local macro = buildMacrotextForSlot(modName, keyName)
            if macro then
                local prefix = MODIFIER_PREFIXES[modName]
                slot.button:SetAttribute(prefix .. "type" .. slot.variant, "macro")
                slot.button:SetAttribute(prefix .. "macrotext" .. slot.variant, macro)
                slot.hasBinding = true
            end
        end
    end
end


-- ---------- Binding registry ----------

-- Populate bindingRegistry attributes from keyToSlot, in a form the _onenter
-- snippet iterates over. SetAttribute on a SecureFrameTemplate Frame is combat-
-- protected, but only-callable-from-RefreshAll which is gated on
-- InCombatLockdown anyway (refreshKeybindAttrs writes to secure buttons).
local function syncBindingRegistry()
    if not bindingRegistry then return end

    -- Wipe the previous range. keyCount is authoritative for old-set size.
    local prev = bindingRegistry:GetAttribute("keyCount") or 0
    for i = 1, prev do
        bindingRegistry:SetAttribute("key" .. i, nil)
        bindingRegistry:SetAttribute("btnName" .. i, nil)
        bindingRegistry:SetAttribute("click" .. i, nil)
    end

    local i = 0
    for keyName, slot in pairs(keyToSlot) do
        if slot.hasBinding then
            i = i + 1
            bindingRegistry:SetAttribute("key" .. i, keyName)
            bindingRegistry:SetAttribute("btnName" .. i, slot.button:GetName())
            bindingRegistry:SetAttribute("click" .. i, VARIANT_TO_VIRTUAL[slot.variant])
        end
    end
    bindingRegistry:SetAttribute("keyCount", i)
end


-- ---------- Public refresh ----------

function SecureClickCast.RefreshAll()
    if not SecureClickCast.IsEnabled() then return end
    if InCombatLockdown() then
        pendingRefreshOnRegen = true
        return
    end
    rebuildKeyAssignments()
    refreshKeybindAttrs()
    syncBindingRegistry()
    for unitFrame, _ in pairs(overlaysByFrame) do
        SecureClickCast.RefreshOverlay(unitFrame)
    end
    -- Also re-register click edges. RefreshClicks defers when called in
    -- combat by flipping pendingRefreshOnRegen; this is where that deferred
    -- write actually lands.
    applyClickEdgeToOverlays()
    pendingRefreshOnRegen = false
end


-- ---------- Init ----------

local function onRegenEnabled()
    if pendingRefreshOnRegen then
        SecureClickCast.RefreshAll()
    end
    -- Flush deferred Show/Hide on unit-frame group containers AND individual unit
    -- frames. Once the secure overlay is parented under either, container:Show/Hide()
    -- is combat-protected and was being silently dropped (or producing taint warnings)
    -- until now. Per-frame flush added 2026-05-04 after a 5-man combat surface report.
    if Puppeteer.UnitFrameGroups then
        for _, group in pairs(Puppeteer.UnitFrameGroups) do
            if group.FlushPendingShown then group:FlushPendingShown() end
        end
    end
    if Puppeteer.AllUnitFrames then
        for _, ui in ipairs(Puppeteer.AllUnitFrames) do
            if ui.FlushPendingShown then ui:FlushPendingShown() end
        end
    end
end

function SecureClickCast.Init()
    if initialized then return end
    initialized = true
    if not SecureClickCast.IsEnabled() then return end

    -- Must inherit a secure template so the restricted-env snippet can
    -- dereference its FrameRef handle. Plain Frames give "Invalid frame handle"
    -- on r:GetAttribute(...) inside the _onenter snippet -- the snippet handle
    -- wrapper only exists for secure-template frames. SetAttribute writes on
    -- this frame ARE combat-protected as a result, but RefreshAll gates on
    -- InCombatLockdown anyway (refreshKeybindAttrs writes to secure buttons).
    bindingRegistry = CreateFrame("Frame", "PuppeteerKeybindRegistry", UIParent,
        "SecureFrameTemplate")
    bindingRegistry:Hide()

    -- One-time event registration via the addon's frame-based dispatcher.
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- PLAYER_ENTERING_WORLD fires once per /reload after all addons have
    -- finished init. The OnAddonLoaded RefreshAll alone gets clobbered by
    -- other addons (notably ElvUI action bars) re-applying their bindings
    -- after Puppeteer's load, so re-run once everything has settled.
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function()
        if event == "PLAYER_REGEN_ENABLED" then
            onRegenEnabled()
        elseif event == "PLAYER_ENTERING_WORLD" then
            SecureClickCast.RefreshAll()
        end
    end)

    SecureClickCast.RefreshAll()
end
