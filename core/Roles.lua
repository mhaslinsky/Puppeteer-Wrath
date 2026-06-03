PTUtil.SetEnvironment(Puppeteer)
local _G = getfenv(0)
local util = PTUtil
local colorize = util.Colorize
local GetColoredRoleText = util.GetColoredRoleText

AssignedRoles = nil

function GetAssignedRole(name)
    if not AssignedRoles or not AssignedRoles[name] then
        return
    end
    AssignedRoles[name]["lastSeen"] = time()
    return AssignedRoles[name]["role"]
end

function GetUnitAssignedRole(unit)
    if not UnitIsPlayer(unit) then
        return
    end
    return GetAssignedRole(UnitName(unit))
end

-- Priority: manual > auto-tank > auto-heal. Auto-detection writes cannot
-- overwrite a higher-priority source. Manual writes overwrite anything.
-- Old entries without a source field are treated as "manual" (backwards-
-- compatible: existing PTRoleCache stays usable, no migration required).
local SOURCE_PRIORITY = {["manual"] = 3, ["auto-tank"] = 2, ["auto-heal"] = 1}

function SetAssignedRole(name, role, source)
    source = source or "manual"
    if role == nil or role == "No Role" then
        -- An auto-detection pass should not clear a manual assignment.
        if source ~= "manual" then
            local existing = AssignedRoles[name]
            if existing and (existing.source or "manual") == "manual" then
                return
            end
        end
        AssignedRoles[name] = nil
        return
    end
    local existing = AssignedRoles[name]
    if existing then
        local existingSource = existing.source or "manual"
        if SOURCE_PRIORITY[source] < SOURCE_PRIORITY[existingSource] then
            return
        end
    end
    AssignedRoles[name] = {
        ["role"] = role,
        ["lastSeen"] = time(),
        ["source"] = source
    }
end

-- Returns true if role assignment failed
function SetUnitAssignedRole(unit, role, source)
    if not UnitIsPlayer(unit) then
        return true
    end
    SetAssignedRole(UnitName(unit), role, source)
end

function PruneAssignedRoles()
    local currentTime = time()
    for name, data in pairs(AssignedRoles) do
        if not data["lastSeen"] or data["lastSeen"] < currentTime - (24 * 60 * 60) then
            AssignedRoles[name] = nil
            --print("Pruned "..name.."'s role")
        end
    end
end

function SetRoleAndUpdate(name, role)
    SetAssignedRole(name, role)
    UpdateUnitFrameGroups()
end

function SetUnitRoleAndUpdate(unit, role)
    if not SetUnitAssignedRole(unit, role) then
        UpdateUnitFrameGroups()
    end
end

RoleAssignInfo = {}

RoleDropdown = PTGuiLib.Get("dropdown", UIParent)

function InitRoleDropdown()
    local initFunc = function(self)
        self.checked = (GetAssignedRole(RoleAssignInfo.Name) or "No Role") == self.role
    end

    local genRole = function(role)
        return {
            text = GetColoredRoleText(role),
            role = role,
            initFunc = initFunc,
            func = function(info)
                SetAssignedRole(RoleAssignInfo.Name, info.role)
                UpdateUnitFrameGroups()
            end
        }
    end
    local massRoleFunc = function(info)
        if not RoleAssignInfo.FrameGroup then
            return
        end
        for _, ui in pairs(RoleAssignInfo.FrameGroup.uis) do
            if (not ui:GetRole() or not info.role) and UnitIsPlayer(ui:GetUnit()) then
                SetAssignedRole(UnitName(ui:GetUnit()), info.role)
            end
        end
        UpdateUnitFrameGroups()
        RoleDropdown:SetToggleState(false)
    end
    local genMassRole = function(role)
        return {
            text = GetColoredRoleText(role),
            role = role,
            notCheckable = true,
            func = massRoleFunc
        }
    end

    local options = {
        {
            initFunc = function(self)
                self.text = colorize(RoleAssignInfo.Name.."'s Role", RoleAssignInfo.ClassColor)
            end,
            notCheckable = true,
            disabled = true,
            textHeight = 12
        }, 
        genRole("Tank"),
        genRole("Healer"),
        genRole("Damage"),
        genRole("No Role"),
        {
            notCheckable = true,
            disabled = true
        }, {
            text = "Set Unassigned As",
            tooltipTitle = "Set Unassigned As",
            tooltipText = "Mass-set the roles of unassigned players. Only applies to players contained in this UI group.",
            notCheckable = true,
            textHeight = 11,
            children = {
                genMassRole("Tank"),
                genMassRole("Healer"),
                genMassRole("Damage")
            }
        }, {
            text = "Clear Roles",
            tooltipTitle = "Clear Roles",
            tooltipText = "Clear all players' roles. Only applies to players contained in this UI group.",
            notCheckable = true,
            textHeight = 11,
            func = massRoleFunc
        }
    }
    RoleDropdown:SetOptions(options)
end


-- ---------- Auto role inference (Ascension 3.3.5a) ----------
--
-- On Project Ascension UnitGroupRolesAssigned(unit) returns boolean (true for
-- the tank, false for everyone else) instead of retail's "TANK"/"HEALER"/etc
-- string -- verified in dungeon 2026-06-02. That gets us tanks for free; we
-- watch CLEU SPELL_HEAL to flag healers once they've cast HEAL_THRESHOLD
-- cross-target heals. Manual assignments via the Role action binding still
-- win (priority encoded in SetAssignedRole above).

-- 2 cross-target heals filters obvious one-offs (DPS-with-self-heal,
-- emergency Holy Light from a Paladin) without long latency to flag a
-- real healer mid-pull.
local HEAL_THRESHOLD = 2

-- name -> session count of cross-target SPELL_HEAL events. Persists until
-- /reload; bounded by number of distinct casters encountered.
local healCounts = {}

local pendingRoleRefresh = false
local function scheduleRoleRefresh()
    if pendingRoleRefresh then return end
    pendingRoleRefresh = true
    util.RunLater(function()
        pendingRoleRefresh = false
        if UpdateUnitFrameGroups then UpdateUnitFrameGroups() end
    end)
end

local function inferTank(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
    if UnitGroupRolesAssigned(unit) == true then
        local name = UnitName(unit)
        if name then SetAssignedRole(name, "Tank", "auto-tank") end
    end
end

function ScanRosterForRoles()
    inferTank("player")
    local raidN = GetNumRaidMembers() or 0
    if raidN > 0 then
        for i = 1, raidN do inferTank("raid"..i) end
    else
        for i = 1, 4 do inferTank("party"..i) end
    end
    scheduleRoleRefresh()
end

-- True if `name` matches any current party/raid member's UnitName. Cheap
-- enough: max 40 string compares per CLEU heal event.
local function nameInGroup(name)
    if not name then return false end
    if UnitName("player") == name then return true end
    local raidN = GetNumRaidMembers() or 0
    if raidN > 0 then
        for i = 1, raidN do
            if UnitName("raid"..i) == name then return true end
        end
    else
        for i = 1, 4 do
            if UnitName("party"..i) == name then return true end
        end
    end
    return false
end

local function onCLEUHeal()
    -- Wrath CLEU arg layout (no hideCaster on 3.3.5a): timestamp, subevent,
    -- sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags,
    -- then prefix/suffix payload starting at arg9.
    if arg2 ~= "SPELL_HEAL" then return end
    local sourceName = arg4
    if not sourceName then return end
    if not nameInGroup(sourceName) then return end
    -- Originally required cross-target heals to filter DPS-with-self-heal
    -- false positives, but in small groups a healer mostly self-heals and
    -- never tripped the threshold. Accept the false-positive risk; manual
    -- Role binding still overrides.

    local count = (healCounts[sourceName] or 0) + 1
    healCounts[sourceName] = count
    if count >= HEAL_THRESHOLD then
        SetAssignedRole(sourceName, "Healer", "auto-heal")
        scheduleRoleRefresh()
    end
end

function InitRoleInference()
    local f = CreateFrame("Frame", "PTRoleInferenceFrame")
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:RegisterEvent("PARTY_MEMBERS_CHANGED")
    f:RegisterEvent("RAID_ROSTER_UPDATE")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function()
        if event == "COMBAT_LOG_EVENT_UNFILTERED" then
            onCLEUHeal()
        else
            ScanRosterForRoles()
        end
    end)
end