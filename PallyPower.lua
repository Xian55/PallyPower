-- PallyPower (Vanilla 1.12) — Event-driven scanning version
-- Notes:
--  * Replaces periodic full raid scans with UNIT_AURA-driven incremental updates
--  * Rebuilds roster on roster/pet changes
--  * Uses BAG_UPDATE to refresh symbol count
--  * Debounces UI updates to avoid thrashing

local initalized = false
local clearTime = 0
local lastReqSent = 0
FiveMinuteBlessingOn = false
ppRefreshAfterClear = false

local TURTLE_REALMS = { Nordanaar=true, ["Tel'Abim"]=true, Ambershire=true }
local IS_TURTLE = TURTLE_REALMS[GetRealmName()] or false
local REGULAR_BLESSING_DURATION = IS_TURTLE and (10 * 60) or (5 * 60)
local GREATER_BLESSING_DURATION = IS_TURTLE and (30 * 60) or (15 * 60)

BINDING_HEADER_PALLYPOWER_HEADER = "Pally Power"
BINDING_NAME_TOGGLE = "Toggle Buff Bar"
BINDING_NAME_REPORT = "Report Assignments"

AllPallys = {}
PallyPower_Assignments = {}
PallyPower = {}

-- Global snapshot of buffs per class -> unit
CurrentBuffs = CurrentBuffs or {}

BlessingIcon = {}
BuffIcon = {}
PP_PerUser = {
    scalemain = 1,
    scalebar = 1,
    scanfreq = 1,        -- UI refresh interval in seconds

    smartbuffs = 1,
    chatfeedback = 1,
    opacity = 0.5,        -- frame backdrop alpha (0.0–1.0)
}

-- === Event-driven state ===
local RosterUnits = {}        -- array of unit ids (player, partyN, raidN, *petN)
local UnitClassID = {}        -- map unit -> classID (0..9); pets use 9
local RosterSet = {}            -- NEW: unit -> true for all valid units
local UnitAlias = {}            -- maps "player" -> "raidN" (etc.) when in raid
local uiDirty = false         -- mark UI needs refresh
local uiDebounce = 0          -- countdown timer for debounced refresh

-- Old fields kept for compatibility with existing code
LastCast = {}
LastCastOn = {}
PP_Symbols = 0
IsPally = 0
PP_PREFIX = "PLPWR"

local RestorSelfAutoCastTimeOut = 1
local RestorSelfAutoCast = false

-- Vanilla-safe helpers
local function table_wipe(t)
  for k in pairs(t) do t[k] = nil end
end

local function PP_Debug(str)
    if not str then str = "(nil)" end
    if PP_DebugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("[PP] " .. str, 1, 0, 0)
    end
end

-- === Performance: cached state ===

-- Cached player name (set on first event, avoids repeated UnitName API calls)
local playerName

-- Reusable array for ScanOneUnit buff detection (avoids per-call allocation)
local scanHave = {false, false, false, false, false, false}

-- Cached UI frame references (populated lazily to avoid getglobal string lookups)
local BuffBarCache = {}      -- [1..10] = { btn, classIcon, buffIcon, text, time, need, have, range, dead }
local PlayerFrameCache = {}  -- [1..12] = { frame, name, symbols, icons[0..5], skills[0..5], classes[0..9] }

local function GetBuffBarEntry(n)
    if not BuffBarCache[n] then
        local prefix = "PallyPowerBuffBarBuff" .. n
        BuffBarCache[n] = {
            btn = getglobal(prefix),
            classIcon = getglobal(prefix .. "ClassIcon"),
            buffIcon = getglobal(prefix .. "BuffIcon"),
            text = getglobal(prefix .. "Text"),
            time = getglobal(prefix .. "Time"),
            need = {},
            have = {},
            range = {},
            dead = {},
        }
    end
    return BuffBarCache[n]
end

local function GetPlayerFrameEntry(n)
    if not PlayerFrameCache[n] then
        local prefix = "PallyPowerFramePlayer" .. n
        local entry = {
            frame = getglobal(prefix),
            name = getglobal(prefix .. "Name"),
            symbols = getglobal(prefix .. "Symbols"),
            icons = {},
            skills = {},
            classes = {},
        }
        for id = 0, 5 do
            entry.icons[id] = getglobal(prefix .. "Icon" .. id)
            entry.skills[id] = getglobal(prefix .. "Skill" .. id)
        end
        for id = 0, 9 do
            entry.classes[id] = getglobal(prefix .. "Class" .. id .. "Icon")
        end
        PlayerFrameCache[n] = entry
    end
    return PlayerFrameCache[n]
end

-- Pre-allocated parts table for PallyPower_SendSelf string building
local sendSelfParts = {}

-- Track active LastCast entries to skip iteration when nothing is ticking
local LastCastCount = 0

-- Deferred roster rebuild to catch pets that load after PARTY_MEMBERS_CHANGED
local pendingRosterRebuild = 0

-- =========================
--  UI/Icon presets (unchanged)
-- =========================
function PallyPower_SwapIconsForFiveMin()
    BlessingIcon[0] = "Interface\\Icons\\Spell_Holy_SealOfWisdom"
    BlessingIcon[1] = "Interface\\Icons\\Spell_Holy_FistOfJustice"
    BlessingIcon[2] = "Interface\\Icons\\Spell_Holy_SealOfSalvation"
    BlessingIcon[3] = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02"
    BlessingIcon[4] = "Interface\\Icons\\Spell_Magic_MageArmor"
    BlessingIcon[5] = "Interface\\Icons\\Spell_Nature_LightningShield"
    BuffIcon[0] = "Interface\\Icons\\Spell_Holy_SealOfWisdom"
    BuffIcon[1] = "Interface\\Icons\\Spell_Holy_FistOfJustice"
    BuffIcon[2] = "Interface\\Icons\\Spell_Holy_SealOfSalvation"
    BuffIcon[3] = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02"
    BuffIcon[4] = "Interface\\Icons\\Spell_Magic_MageArmor"
    BuffIcon[5] = "Interface\\Icons\\Spell_Nature_LightningShield"
end

function PallyPower_SwapIconsForFifteenMin()
    BlessingIcon[0] = "Interface\\Icons\\Spell_Holy_GreaterBlessingofWisdom"
    BlessingIcon[1] = "Interface\\Icons\\Spell_Holy_GreaterBlessingofKings"
    BlessingIcon[2] = "Interface\\Icons\\Spell_Holy_GreaterBlessingofSalvation"
    BlessingIcon[3] = "Interface\\Icons\\Spell_Holy_GreaterBlessingofLight"
    BlessingIcon[4] = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings"
    BlessingIcon[5] = "Interface\\Icons\\Spell_Holy_GreaterBlessingofSanctuary"
    BuffIcon[0] = "Interface\\Icons\\Spell_Holy_GreaterBlessingofWisdom"
    BuffIcon[1] = "Interface\\Icons\\Spell_Holy_GreaterBlessingofKings"
    BuffIcon[2] = "Interface\\Icons\\Spell_Holy_GreaterBlessingofSalvation"
    BuffIcon[3] = "Interface\\Icons\\Spell_Holy_GreaterBlessingofLight"
    BuffIcon[4] = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings"
    BuffIcon[5] = "Interface\\Icons\\Spell_Holy_GreaterBlessingofSanctuary"
end

-- =========================
--  Load / Events / Update
-- =========================
function PallyPower_OnLoad()
    this:RegisterEvent("SPELLS_CHANGED")
    this:RegisterEvent("PLAYER_ENTERING_WORLD")
    this:RegisterEvent("PLAYER_LOGIN")

    this:RegisterEvent("CHAT_MSG_ADDON")
    this:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLY_DEATH")

    -- Roster + aura + pet + bags (event-driven scanning)
    this:RegisterEvent("RAID_ROSTER_UPDATE")
    this:RegisterEvent("PARTY_MEMBERS_CHANGED")
    this:RegisterEvent("UNIT_AURA")
    this:RegisterEvent("UNIT_PET")
    this:RegisterEvent("BAG_UPDATE")

    this:SetBackdropColor(0,0,0,PP_PerUser.opacity)
    this:SetScale(1)

    SlashCmdList["PALLYPOWER"] = function(msg) PallyPower_SlashCommandHandler(msg) end

    if not PP_PerUser.quietmode then
        DEFAULT_CHAT_FRAME:AddMessage("PallyPower for TurtleWoW version "..(PallyPower_Version or "?").." |cff00FF00loaded successfully!|r")
    end
end

local function PruneCurrentBuffs()
  -- Drop units no longer in roster set
  for classId, bucket in pairs(CurrentBuffs) do
    for unit in pairs(bucket) do
      if unit ~= "_mask" and not RosterSet[unit] then
        bucket[unit] = nil
      end
    end
    -- if a class bucket becomes empty, remove it
    local hasAny = false
    for _ in pairs(bucket) do hasAny = true; break end
    if not hasAny then CurrentBuffs[classId] = nil end
  end
end

local function RebuildRoster()
  -- reset
  for k in pairs(RosterUnits) do RosterUnits[k] = nil end
  for k in pairs(UnitClassID) do UnitClassID[k] = nil end
  for k in pairs(RosterSet)   do RosterSet[k]   = nil end
  for k in pairs(UnitAlias)   do UnitAlias[k]   = nil end

  local function addUnit(u, classId)
    if UnitExists(u) then
      table.insert(RosterUnits, u)
      UnitClassID[u] = classId
      RosterSet[u] = true
    end
  end

  if GetNumRaidMembers() > 0 then
    -- raid: raidN already includes the player, so no separate "player" entry
    for i=1, GetNumRaidMembers() do
      local u  = "raid"..i
      local up = "raidpet"..i
      addUnit(u,  PallyPower_GetClassID(UnitClass(u)))
      addUnit(up, 9)
      -- Map "player"/"pet" aliases so UNIT_AURA for "player" resolves correctly
      if UnitIsUnit(u, "player") then
        UnitAlias["player"] = u
        UnitAlias["pet"] = up
      end
    end
  elseif GetNumPartyMembers() > 0 then
    -- party: partyN does NOT include the player, so add them separately
    addUnit("player", PallyPower_GetClassID(UnitClass("player")))
    addUnit("pet", 9)
    for i=1, GetNumPartyMembers() do
      local u  = "party"..i
      local up = "partypet"..i
      addUnit(u,  PallyPower_GetClassID(UnitClass(u)))
      addUnit(up, 9)
    end
  else
    -- solo
    addUnit("player", PallyPower_GetClassID(UnitClass("player")))
    addUnit("pet", 9)
  end
end


local function IsRosterUnit(unit)
    return UnitClassID[unit] ~= nil
end

-- Compact paladin-relevant buff snapshot for one unit
local function ScanOneUnit(unit)
  local classID = UnitClassID and UnitClassID[unit]
  if not classID or classID < 0 then return end
  if not UnitExists(unit) then return end

  local name = UnitName(unit)
  if not name or name == "" then return end

  -- Reuse module-level scanHave array (no allocation)
  scanHave[1] = false; scanHave[2] = false; scanHave[3] = false
  scanHave[4] = false; scanHave[5] = false; scanHave[6] = false
  local j = 1
  while true do
    local icon = UnitBuff(unit, j, true)
    if not icon then break end
    local id = PallyPower_GetBuffTextureID(icon)
    if id >= 0 and id <= 5 then scanHave[id + 1] = true end
    j = j + 1
  end

  -- Numeric mask (bit flags) — cheaper comparison than string
  local mask = 0
  if scanHave[1] then mask = mask + 1 end
  if scanHave[2] then mask = mask + 2 end
  if scanHave[3] then mask = mask + 4 end
  if scanHave[4] then mask = mask + 8 end
  if scanHave[5] then mask = mask + 16 end
  if scanHave[6] then mask = mask + 32 end

  CurrentBuffs[classID] = CurrentBuffs[classID] or {}
  local entry = CurrentBuffs[classID][unit]
  local vis = UnitIsVisible(unit) and true or false

  if not entry then
    -- First time seeing this unit: allocate entry
    CurrentBuffs[classID][unit] = {
      name = name, visible = vis,
      [0] = scanHave[1], [1] = scanHave[2], [2] = scanHave[3],
      [3] = scanHave[4], [4] = scanHave[5], [5] = scanHave[6],
      _mask = mask
    }
    uiDirty = true
  elseif entry._mask ~= mask or entry.visible ~= vis or entry.name ~= name then
    -- Update in-place (no allocation)
    entry.name = name
    entry.visible = vis
    entry[0] = scanHave[1]; entry[1] = scanHave[2]; entry[2] = scanHave[3]
    entry[3] = scanHave[4]; entry[4] = scanHave[5]; entry[5] = scanHave[6]
    entry._mask = mask
    uiDirty = true
  end
end


-- Backward-compatible function name (used elsewhere in the addon)
function PallyPower_ScanRaid()
    if not PP_IsPally then return end
    RebuildRoster()
    for i = 1, table.getn(RosterUnits) do
        ScanOneUnit(RosterUnits[i])
    end
end

function PallyPower_OnUpdate(tdiff)
    -- restore auto self-cast toggled for cast macro
    if RestorSelfAutoCast then
        RestorSelfAutoCastTimeOut = RestorSelfAutoCastTimeOut - tdiff
        if RestorSelfAutoCastTimeOut < 0 then
            RestorSelfAutoCast = false
            SetCVar("autoSelfCast", "1")
        end
    end

    -- countdowns for LastCast (skip iteration when nothing is ticking)
    if LastCastCount > 0 then
        local expiredKey = nil  -- reuse single local for sequential removal
        for i, k in LastCast do
            k = k - tdiff
            if k < 0 then
                if expiredKey then
                    LastCast[expiredKey] = nil
                    LastCastCount = LastCastCount - 1
                end
                expiredKey = i
            else
                LastCast[i] = k
            end
        end
        if expiredKey then
            LastCast[expiredKey] = nil
            LastCastCount = LastCastCount - 1
        end
        uiDirty = true  -- ensure timer display refreshes at the scanfreq rate
    end

    -- Deferred roster rebuild (catches pets that load after party join)
    if pendingRosterRebuild > 0 then
        pendingRosterRebuild = pendingRosterRebuild - tdiff
        if pendingRosterRebuild <= 0 then
            pendingRosterRebuild = 0
            RebuildRoster()
            PruneCurrentBuffs()
            for _, u in ipairs(RosterUnits) do ScanOneUnit(u) end
            uiDirty = true
        end
    end

    -- Debounced UI refresh
    uiDebounce = uiDebounce - tdiff
    if uiDirty and uiDebounce <= 0 then
        uiDirty = false
        uiDebounce = PP_PerUser.scanfreq
        PallyPower_UpdateUI()
    end
end

function PallyPower_OnEvent(event)
    -- Cache player name on first event (avoids repeated API calls)
    if not playerName then playerName = UnitName("player") end

    if event == "SPELLS_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
        if UnitLevel("player") < 52 or FiveMinuteBlessingOn == true then
            FiveMinBlessing = true
            PallyPower_SwapIconsForFiveMin()
        else
            FiveMinBlessing = false
            PallyPower_SwapIconsForFifteenMin()
        end
        PallyPower_UpdateUI()
        PallyPower_ScanSpells()

        -- initial roster+scan on world entry
        if event == "PLAYER_ENTERING_WORLD" then
            playerName = UnitName("player")  -- refresh on world entry
            if not PallyPower_Assignments[playerName] then
                PallyPower_Assignments[playerName] = {}
                if playerName == "Aznamir" then PP_DebugEnabled = true end
            end
            RebuildRoster()
            PruneCurrentBuffs()
            for i = 1, table.getn(RosterUnits) do ScanOneUnit(RosterUnits[i]) end
            uiDirty = true
            if IsPally == 1 and (GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0) then
                PallyPower_SendSelf()
                PallyPower_RequestSend()
            end
        end
    elseif event == "PLAYER_LOGIN" then
        -- Merge defaults for keys added in newer versions (saved vars are now loaded)
        local defaults = { opacity = 0.5 }
        for k, v in pairs(defaults) do
            if PP_PerUser[k] == nil then
                PP_PerUser[k] = v
            end
        end
        PallyPower_ApplyOpacity()
        PallyPower_UpdateUI()

    elseif event == "CHAT_MSG_ADDON" and arg1 == PP_PREFIX and (arg3 == "PARTY" or arg3 == "RAID") then
        PallyPower_ParseMessage(arg4, arg2)

    elseif event == "CHAT_MSG_COMBAT_FRIENDLY_DEATH" then
        -- no forced scan; UI will update on UNIT_AURA of the revived unit

    elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        RebuildRoster()
        PruneCurrentBuffs()
        for _, u in ipairs(RosterUnits) do ScanOneUnit(u) end
        uiDirty = true
        pendingRosterRebuild = 2  -- deferred rebuild to catch late-loading pets

    elseif event == "UNIT_PET" then
        RebuildRoster()
        PruneCurrentBuffs()               -- NEW
        -- rescan owner + pet if present (resolve "player" -> "raidN" alias)
        local owner = UnitAlias[arg1] or arg1
        if owner then
            local pet = (string.sub(owner,1,5)=="party") and ("partypet"..string.sub(owner,6))
                    or (string.sub(owner,1,4)=="raid"  and ("raidpet"..string.sub(owner,5))
                    or "pet")
            if UnitExists(owner) then ScanOneUnit(owner) end
            if UnitExists(pet)   then ScanOneUnit(pet)   end
        end
        uiDirty = true

    elseif event == "UNIT_AURA" then
        local unit = UnitAlias[arg1] or arg1
        if unit and IsRosterUnit(unit) then
            ScanOneUnit(unit)
        end

    elseif event == "BAG_UPDATE" then
        PallyPower_ScanInventory()
    end
end

-- =========================
--  Commands / Report (unchanged)
-- =========================
function PallyPower_FiveMinuteBlessings()
    local isChecked = FiveMinBlessingChk:GetChecked()
    PP_Symbols = 0
    FiveMinuteBlessingOn = (isChecked == 1)
    ReloadUI()
end

function PallyPower_SlashCommandHandler(msg)
    if msg == "debug" then
        PP_DebugEnabled = not PP_DebugEnabled and true or nil
    end
    if msg == "report" then
        PallyPower_Report()
        return true
    end
    if PallyPowerFrame:IsVisible() then PallyPowerFrame:Hide() else PallyPowerFrame:Show() end
    PallyPower_UpdateUI()
end

function PallyPower_Report()
    if PallyPower_CanControl(playerName) then
        local channel = (GetNumRaidMembers() > 0) and "RAID" or "PARTY"
        PP_Debug(channel)
        SendChatMessage(PallyPower_Assignments1, channel)
        for name in AllPallys do
            local blessings
            local list = { [0]=0,[1]=0,[2]=0,[3]=0,[4]=0,[5]=0 }
            for id = 0, 9 do
                local bid = PallyPower_Assignments[name][id]
                if bid >= 0 then list[bid] = list[bid] + 1 end
            end
            for id = 0, 5 do
                if list[id] > 0 then
                    blessings = blessings and (blessings .. ", ") or ""
                    blessings = blessings .. PallyPower_BlessingID[id]
                end
            end
            if not blessings then blessings = "Nothing" end
            SendChatMessage(name .. ": " .. blessings, channel)
            PP_Debug(name .. ": " .. blessings)
        end
        SendChatMessage(PallyPower_Assignments2, channel)
    end
end

-- =========================
--  UI helpers (mostly unchanged)
-- =========================
function PallyPower_FormatTime(time)
    if not time or time < 0 then return "" end
    local mins = floor(time / 60)
    local secs = time - (mins * 60)
    return string.format("%d:%02d", mins, secs)
end

function PallyPowerGrid_Update()
    if not initalized then
        if not PP_PerUser.quietmode then
            DEFAULT_CHAT_FRAME:AddMessage("[PallyPower] rerunning scan")
        end
        PallyPower_ScanSpells()
    end
    local i = 1
    local numPallys = 0
    if PallyPowerFrame:IsVisible() then
        PallyPowerFrame:SetScale(PP_PerUser.scalemain)
        for name, skills in AllPallys do
            local pf = GetPlayerFrameEntry(i)
            pf.name:SetText(name)
            pf.symbols:SetText(skills["symbols"])
            pf.symbols:SetTextColor(1, 1, 0.5)
            if (PallyPower_CanControl(name)) then
                pf.name:SetTextColor(1, 1, 1)
            else
                if (PallyPower_CheckRaidLeader(name)) then
                    pf.name:SetTextColor(0, 1, 0)
                else
                    pf.name:SetTextColor(1, 0, 0)
                end
            end
            for id = 0, 5 do
                if (skills[id]) then
                    pf.icons[id]:Show()
                    pf.skills[id]:Show()
                    local txt = skills[id]["rank"]
                    if (skills[id]["talent"] + 0 > 0) then
                        txt = txt .. "+" .. skills[id]["talent"]
                    end
                    pf.skills[id]:SetText(txt)
                else
                    pf.icons[id]:Hide()
                    pf.skills[id]:Hide()
                end
            end
            for id = 0, 9 do
                if (PallyPower_Assignments[name]) then
                    pf.classes[id]:SetTexture(BlessingIcon[PallyPower_Assignments[name][id]])
                else
                    pf.classes[id]:SetTexture(nil)
                end
            end
            i = i + 1
            numPallys = numPallys + 1
        end
        PallyPowerFrame:SetHeight(14 + 24 + 56 + (numPallys * 56) + 22)
        for j = 1, 12 do
            local pf = GetPlayerFrameEntry(j)
            if j <= numPallys then pf.frame:Show() else pf.frame:Hide() end
        end
    end
end

function PallyPower_UpdateUI()
    if not initalized then PallyPower_ScanSpells() end
    PallyPowerBuffBar:SetScale(PP_PerUser.scalebar)
    local _, eclass = UnitClass("player")
    if eclass == "PALADIN" then IsPally = 1 else PallyPowerBuffBar:Hide() end

    if (IsPally == 1) or (GetNumRaidMembers() > 0 and GetNumPartyMembers() > 0) then
        PallyPowerBuffBar:Show()
        PallyPowerBuffBarTitleText:SetText(format(PallyPower_BuffBarTitle, PP_Symbols))
        local BuffNum = 1
        if PallyPower_Assignments[playerName] then
            local assign = PallyPower_Assignments[playerName]
            for class = 0, 9 do
                if (assign[class] and assign[class] ~= -1 and CurrentBuffs[class]) then
                    local bc = GetBuffBarEntry(BuffNum)
                    bc.classIcon:SetTexture(PallyPower_ClassTexture[class])
                    bc.buffIcon:SetTexture(BlessingIcon[assign[class]])

                    local btn = bc.btn
                    btn.classID = class
                    btn.buffID = assign[class]
                    btn.need = {}; btn.have = {}; btn.range = {}; btn.dead = {}

                    local nneed, nhave, ndead = 0, 0, 0
                    if CurrentBuffs[class] then
                        for unit, stats in CurrentBuffs[class] do
                            if stats["visible"] then
                                if not stats[assign[class]] then
                                    if UnitIsDeadOrGhost(unit) then
                                        ndead = ndead + 1; tinsert(btn.dead, stats["name"])
                                    else
                                        nneed = nneed + 1; tinsert(btn.need, stats["name"])
                                    end
                                else
                                    tinsert(btn.have, stats["name"]); nhave = nhave + 1
                                end
                            else
                                tinsert(btn.range, stats["name"]); nhave = nhave + 1
                            end
                        end
                    end
                    if ndead > 0 then
                        bc.text:SetText(nneed .. " (" .. ndead .. ")")
                    else
                        bc.text:SetText(nneed)
                    end
                    if (nhave > 0) then
                        bc.time:SetText(PallyPower_FormatTime(LastCast[assign[class] .. class]))
                        btn.showTimer = true
                    else
                        bc.time:SetText("")
                        btn.showTimer = false
                    end

                    if (nhave == 0) then
                        btn:SetBackdropColor(1.0, 0.0, 0.0, PP_PerUser.opacity)
                    elseif (nneed > 0) then
                        btn:SetBackdropColor(1.0, 1.0, 0.5, PP_PerUser.opacity)
                    else
                        btn:SetBackdropColor(0.0, 0.0, 0.0, PP_PerUser.opacity)
                    end
                    btn:Show()
                    BuffNum = BuffNum + 1
                end
            end
        end
        for rest = BuffNum, 10 do
            local bc = GetBuffBarEntry(rest)
            bc.btn:Hide()
        end
        PallyPowerBuffBar:SetHeight(30 + (34 * (BuffNum - 1)))
    end
end

-- =========================
--  Spell/Inventory scanning (minor edits)
-- =========================
function PallyPower_ScanSpells()
    local RankInfo = {}
    local i = 1

    while true do
        local spellName, spellRank = GetSpellName(i, BOOKTYPE_SPELL)
        local spellTexture = GetSpellTexture(i, BOOKTYPE_SPELL)
        if not spellName then break end
        if not spellRank or spellRank == "" then spellRank = PallyPower_Rank1 end

        local _, _, bless = string.find(spellName, PallyPower_BlessingSpellSearch)
        if bless then
            local tmp_str = string.find(spellName, "Greater")
            local wantGreater = (FiveMinBlessing ~= true)
            if (wantGreater and tmp_str == 1) or ((not wantGreater) and (tmp_str ~= 1)) then
                for id, name in PallyPower_BlessingID do
                    if name == bless then
                        local _, _, rank = string.find(spellRank, PallyPower_RankSearch)
                        if not (RankInfo[id] and spellRank < RankInfo[id]["rank"]) then
                            RankInfo[id] = { rank = rank, id = i, name = name, talent = 0 }
                        end
                    end
                end
            end
        end
        i = i + 1
    end

    local numTabs = GetNumTalentTabs()
    for t = 1, numTabs do
        local numTalents = GetNumTalents(t)
        for ti = 1, numTalents do
            local nameTalent, _, _, _, currRank = GetTalentInfo(t, ti)
            if string.find(nameTalent, PallyPower_BlessingTalentSearch) then
                for id = 0, 1 do -- wis, might
                    if RankInfo[id] then RankInfo[id]["talent"] = currRank end
                end
            end
        end
    end

    local _, class = UnitClass("player")
    if class == "PALADIN" then
        AllPallys[playerName] = RankInfo
        if initalized then PallyPower_SendSelf() end
        PP_IsPally = true
    else
        PP_Debug("I'm not a paladin?? " .. class)
        PP_IsPally = nil
    end
    initalized = true
    PallyPower_ScanInventory()
end

function PallyPower_ScanInventory()
    if not PP_IsPally then return end
    PP_Debug("Scanning for symbols")
    local oldcount = PP_Symbols
    PP_Symbols = 0
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        if slots then
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                if link and string.find(link, PallyPower_Symbol) then
                    local _, count = GetContainerItemInfo(bag, slot)
                    PP_Symbols = PP_Symbols + (count or 0)
                end
            end
        end
    end
    if PP_Symbols ~= oldcount then
        PallyPower_SendMessage("SYMCOUNT " .. PP_Symbols)
    end
    AllPallys[playerName] = AllPallys[playerName] or {}
    AllPallys[playerName]["symbols"] = PP_Symbols
end

-- =========================
--  Messaging / Assignments (unchanged)
-- =========================
function PallyPower_RequestSend()
    if GetTime() - lastReqSent < 5 then return end
    lastReqSent = GetTime()
    PallyPower_SendMessage("REQ")
end

function PallyPower_SendSelf()
    if not initalized then PallyPower_ScanSpells() end
    if not AllPallys[playerName] then return end
    -- Build message with reusable parts table (avoids 21+ string concatenations)
    table_wipe(sendSelfParts)
    local n = 0
    n = n + 1; sendSelfParts[n] = "SELF "
    local RankInfo = AllPallys[playerName]
    for id = 0, 5 do
        if not RankInfo[id] then
            n = n + 1; sendSelfParts[n] = "nn"
        else
            n = n + 1; sendSelfParts[n] = RankInfo[id]["rank"]
            n = n + 1; sendSelfParts[n] = RankInfo[id]["talent"]
        end
    end
    n = n + 1; sendSelfParts[n] = "@"
    local assign = PallyPower_Assignments[playerName]
    for id = 0, 9 do
        if not assign or not assign[id] or assign[id] == -1 then
            n = n + 1; sendSelfParts[n] = "n"
        else
            n = n + 1; sendSelfParts[n] = assign[id]
        end
    end
    PallyPower_SendMessage(table.concat(sendSelfParts))
    PallyPower_SendMessage("SYMCOUNT " .. PP_Symbols)
end

function PallyPower_SendMessage(msg)
    if GetNumRaidMembers() == 0 then
        SendAddonMessage(PP_PREFIX, msg, "PARTY", playerName)
    else
        SendAddonMessage(PP_PREFIX, msg, "RAID", playerName)
    end
end

-- Restores clearing of all assignments for self or by leader
function PallyPower_Clear(fromupdate, who)
    -- who = the player requesting the clear (defaults to you)
    if not who then
        who = playerName
    end

    for name, skills in PallyPower_Assignments do
        if (PallyPower_CheckRaidLeader(who) or name == who) then
            if not PP_PerUser.quietmode then
                if name == who then
                    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080    PallyPower|r -- |cffFFFF00Clearing...|r")
                else
                    -- rate-limit the "leader cleared" message
                    if (clearTime + 5) < GetTime() then
                        clearTime = GetTime()
                        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080    PallyPower|r -- |cffFFFF00Clearing as requested by leader: |r"..who)
                    end
                end
            end

            -- set all classes to -1 (unassigned)
            if PallyPower_Assignments[name] then
                for class in PallyPower_Assignments[name] do
                    PallyPower_Assignments[name][class] = -1
                end
            end

            ppRefreshAfterClear = true
        end
    end

    -- Do a clean refresh (event-driven: rebuild roster snapshot, UI, symbols, and re-sync)
    PallyPower_Refresh()

    -- If this wasn’t triggered by a network message, broadcast CLEAR
    if not fromupdate then
        PallyPower_SendMessage("CLEAR")
    end
end

function PallyPower_ParseMessage(sender, msg)
    if sender == playerName then return end

    if msg == "REQ" then
        PallyPower_SendSelf()
    end
    if string.find(msg, "^SELF") then
        AllPallys[sender] = {}
        local _, _, numbers, assign = string.find(msg, "SELF ([0-9n]*)@?([0-9n]*)")
        for id = 0, 5 do
            local rank = string.sub(numbers, id * 2 + 1, id * 2 + 1)
            local talent = string.sub(numbers, id * 2 + 2, id * 2 + 2)
            if rank ~= "n" then
                AllPallys[sender][id] = { rank = rank, talent = talent }
            end
        end
        -- Only adopt remote assignments on first contact (no local data yet)
        if not PallyPower_Assignments[sender] or not next(PallyPower_Assignments[sender]) then
            PallyPower_Assignments[sender] = PallyPower_Assignments[sender] or {}
            if assign and assign ~= "" then
                for id = 0, 9 do
                    local tmp = string.sub(assign, id + 1, id + 1)
                    if tmp == "n" or tmp == "" then tmp = -1 end
                    PallyPower_Assignments[sender][id] = (tmp + 0)
                end
            end
        end
        uiDirty = true
    end
    if string.find(msg, "^ASSIGN") then
        local _, _, name, class, skill = string.find(msg, "^ASSIGN (.*) (.*) (.*)")
        if (name ~= sender) and (not PallyPower_CheckRaidLeader(sender)) then return end
        PallyPower_Assignments[name] = PallyPower_Assignments[name] or {}
        class = class + 0; skill = skill + 0
        PallyPower_Assignments[name][class] = skill
        uiDirty = true
    end
    if string.find(msg, "^MASSIGN") then
        local _, _, name, skill = string.find(msg, "^MASSIGN (.*) (.*)")
        if (name ~= sender) and (not PallyPower_CheckRaidLeader(sender)) then return end
        PallyPower_Assignments[name] = PallyPower_Assignments[name] or {}
        skill = skill + 0
        for class = 0, 9 do PallyPower_Assignments[name][class] = skill end
        uiDirty = true
    end
    if string.find(msg, "^SYMCOUNT ([0-9]*)") then
        local _, _, count = string.find(msg, "^SYMCOUNT ([0-9]*)")
        if AllPallys[sender] then
            AllPallys[sender]["symbols"] = count
        else
            PallyPower_RequestSend()
        end
    end
    if string.find(msg, "^CLEAR") then
        PallyPower_Clear(true, sender)
    end
end

-- =========================
--  Misc/UI wiring (unchanged)
-- =========================
function PallyPower_ShowCredits()
    GameTooltip:SetOwner(this, "ANCHOR_TOPLEFT")
    GameTooltip:SetText(PallyPower_Credits1, 1, 1, 1)
    GameTooltip:AddLine(PallyPower_Credits2)
    GameTooltip:AddLine(PallyPower_Credits3)
    GameTooltip:AddLine(PallyPower_Credits4)
    GameTooltip:AddLine(PallyPower_Credits5)
    GameTooltip:AddLine(PallyPower_Credits6, 0, 1, 0)
    GameTooltip:Show()
end

function PallyPowerFrame_MouseDown(arg1)
    if (((not PallyPowerFrame.isLocked) or (PallyPowerFrame.isLocked == 0)) and (arg1 == "LeftButton")) then
        PallyPowerFrame:StartMoving(); PallyPowerFrame.isMoving = true
    end
end
function PallyPowerFrame_MouseUp()
    if (PallyPowerFrame.isMoving) then
        PallyPowerFrame:StopMovingOrSizing(); PallyPowerFrame.isMoving = false
    end
end

function PallyPowerBuffBar_MouseDown(arg1)
    if (((not PallyPowerBuffBar.isLocked) or (PallyPowerBuffBar.isLocked == 0)) and (arg1 == "LeftButton")) then
        PallyPowerBuffBar:StartMoving(); PallyPowerBuffBar.isMoving = true
        PallyPowerBuffBar.startPosX = PallyPowerBuffBar:GetLeft()
        PallyPowerBuffBar.startPosY = PallyPowerBuffBar:GetTop()
    end
end
function PallyPowerBuffBar_MouseUp()
    if (PallyPowerBuffBar.isMoving) then
        PallyPowerBuffBar:StopMovingOrSizing(); PallyPowerBuffBar.isMoving = false
    end
    if abs(PallyPowerBuffBar.startPosX - PallyPowerBuffBar:GetLeft()) < 2 and abs(PallyPowerBuffBar.startPosY - PallyPowerBuffBar:GetTop()) < 2 then
        PallyPowerFrame:Show(); uiDirty = true
    end
end

function PallyPowerGridButton_OnLoad(btn) end
function PallyPowerGridButton_OnLeave(btn) end
function PallyPowerGridButton_OnEnter(btn) end

function PallyPowerGridButton_OnClick(btn, mouseBtn)
    local _, _, pnum, class = string.find(btn:GetName(), "PallyPowerFramePlayer(.+)Class(.+)")
    pnum = pnum + 0; class = class + 0
    local pname = GetPlayerFrameEntry(pnum).name:GetText()
    if not PallyPower_CanControl(pname) then return end

    if mouseBtn == "RightButton" then
        PallyPower_Assignments[pname][class] = -1
        uiDirty = true
        PallyPower_SendMessage("ASSIGN " .. pname .. " " .. class .. " -1")
    else
        PallyPower_PerformCycle(pname, class)
    end
end

function PallyPower_PerformCycleBackwards(name, class)
    local shift = IsShiftKeyDown()
    if shift then class = 4 end

    local cur = (PallyPower_Assignments[name][class] or 6)
    if cur == -1 then cur = 6 end
    PallyPower_Assignments[name][class] = -1

    for test = cur - 1, -1, -1 do
        cur = test
        if PallyPower_CanBuff(name, test) and (PallyPower_NeedsBuff(class, test) or shift) then break end
    end

    if shift then
        for test = 0, 9 do PallyPower_Assignments[name][test] = cur end
        PallyPower_SendMessage("MASSIGN " .. name .. " " .. cur)
    else
        PallyPower_Assignments[name][class] = cur
        PallyPower_SendMessage("ASSIGN " .. name .. " " .. class .. " " .. cur)
    end
    uiDirty = true
end

function PallyPower_PerformCycle(name, class)
    local shift = IsShiftKeyDown()
    if shift then class = 4 end

    local cur = PallyPower_Assignments[name][class] or -1
    PallyPower_Assignments[name][class] = -1
    for test = cur + 1, 6 do
        if PallyPower_CanBuff(name, test) and (PallyPower_NeedsBuff(class, test) or shift) then
            cur = test; break
        end
    end
    if cur == 6 then cur = -1 end

    if shift then
        for test = 0, 9 do PallyPower_Assignments[name][test] = cur end
        PallyPower_SendMessage("MASSIGN " .. name .. " " .. cur)
    else
        PallyPower_Assignments[name][class] = cur
        PallyPower_SendMessage("ASSIGN " .. name .. " " .. class .. " " .. cur)
    end
    uiDirty = true
end

function PallyPower_CanBuff(name, test)
    if test == 6 then return true end
    if (not AllPallys[name][test]) or (AllPallys[name][test]["rank"] == 0) then return false end
    return true
end

function PallyPower_NeedsBuff(class, test)
    if test == 6 or test == -1 then return true end
    if PP_PerUser.smartbuffs then
        if (class == 0 or class == 1) and test == 0 then return false end    -- warriors/rogues: no wisdom
        if (class == 2 or class == 6 or class == 7) and test == 1 then return false end -- casters: no might -- hunters can get might
    end
    for name, skills in PallyPower_Assignments do
        if (AllPallys[name]) and skills[class] and skills[class] == test then return false end
    end
    return true
end

function PallyPower_CheckRaidLeader(nick)
    if GetNumRaidMembers() == 0 then
        for i = 1, GetNumPartyMembers(), 1 do
            if nick == UnitName("party" .. i) and UnitIsPartyLeader("party" .. i) then return true end
        end
        return false
    end
    for i = 1, GetNumRaidMembers(), 1 do
        local name, rank = GetRaidRosterInfo(i)
        if (rank and rank >= 1 and name == nick) then return true end
    end
    return false
end

function PallyPower_CanControl(name)
    return (IsPartyLeader() or IsRaidLeader() or IsRaidOfficer() or (name == playerName))
end

function PallyPowerBuffButton_OnLoad(btn)
    this:SetBackdropColor(0,0,0,PP_PerUser.opacity)
end

function PallyPower_Refresh()
  if not PP_PerUser.quietmode then
    if ppRefreshAfterClear ~= true then
      DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080    PallyPower|r -- |cffFFFF00Refreshing...|r")
    end
  end

  -- reset lightweight state
  PP_Symbols = 0
  -- keep AllPallys / assignments (players expect those to persist)
  -- but force a rescan/rebuild of roster + buffs
  CurrentBuffs = CurrentBuffs or {}

  -- Rebuild roster and do a one-shot scan of present units
  RebuildRoster()
  for _, u in ipairs(RosterUnits) do
    if UnitExists(u) then
      ScanOneUnit(u)
    end
  end

  -- refresh symbols now
  PallyPower_ScanInventory()

  -- UI
  PallyPower_UpdateUI()
  PallyPower_SendSelf()
  PallyPower_RequestSend()

  if not PP_PerUser.quietmode then
    if ppRefreshAfterClear ~= true then
      DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080    PallyPower|r -- |cff00FF00Refresh complete!|r")
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080    PallyPower|r -- |cff00FF00Clearing complete!|r")
    end
  end
  if ppRefreshAfterClear then ppRefreshAfterClear = false end
end


function PallyPowerBuffButton_OnClick(btn, mousebtn)
    local _,class = UnitClass("player")
    if class ~= "PALADIN" then return end

    RestorSelfAutoCastTimeOut = 1
    if GetCVar("autoSelfCast") == "1" then
        RestorSelfAutoCast = true
        SetCVar("autoSelfCast", "0")
    end

    ClearTarget()
    PP_Debug("Casting " .. btn.buffID .. " on " .. btn.classID)
    CastSpell(AllPallys[playerName][btn.buffID]["id"], BOOKTYPE_SPELL)

    -- Try to land the blessing on the first eligible unit that NEEDS it
    if CurrentBuffs[btn.classID] then
        for unit, stats in CurrentBuffs[btn.classID] do
            if not stats[btn.buffID] and stats["visible"] and not UnitIsDeadOrGhost(unit) and SpellCanTargetUnit(unit) then
                SpellTargetUnit(unit)
                local castKey = btn.buffID .. btn.classID
                if not LastCast[castKey] then LastCastCount = LastCastCount + 1 end
                LastCast[castKey] = FiveMinBlessing and REGULAR_BLESSING_DURATION or GREATER_BLESSING_DURATION
                LastCastOn[btn.classID] = unit
                PallyPower_ShowFeedback(format(PallyPower_Casting, PallyPower_BlessingID[btn.buffID], PallyPower_ClassID[btn.classID], UnitName(unit)), 0, 1, 0)
                TargetLastTarget()
                uiDirty = true
                return
            end
        end
    end

    -- Fallback: if we didn't find anyone (e.g., roster desync), try self
    if SpellIsTargeting() and SpellCanTargetUnit("player") then
        SpellTargetUnit("player")
        local castKey = btn.buffID .. btn.classID
        if not LastCast[castKey] then LastCastCount = LastCastCount + 1 end
        LastCast[castKey] = FiveMinBlessing and REGULAR_BLESSING_DURATION or GREATER_BLESSING_DURATION
        LastCastOn[btn.classID] = playerName
        PallyPower_ShowFeedback(format(PallyPower_Casting, PallyPower_BlessingID[btn.buffID], PallyPower_ClassID[btn.classID], playerName), 0.0, 1.0, 0.0)
        TargetLastTarget()
        return
    end

    SpellStopTargeting()
    TargetLastTarget()
    PallyPower_ShowFeedback(format(PallyPower_CouldntFind, PallyPower_BlessingID[btn.buffID], PallyPower_ClassID[btn.classID]), 1, 0, 0)
end

function PallyPowerBuffButton_OnEnter(btn)
    local _,class = UnitClass("player")
    if class ~= "PALADIN" then return end

    GameTooltip:SetOwner(this, "ANCHOR_TOPLEFT")
    GameTooltip:SetText(PallyPower_ClassID[btn.classID] .. PallyPower_BuffFrameText .. PallyPower_BlessingID[btn.buffID], 1, 1, 1)
    GameTooltip:AddLine(PallyPower_Have .. table.concat(btn.have, ", "), 0.5, 1, 0.5)
    GameTooltip:AddLine(PallyPower_Need .. table.concat(btn.need, ", "), 1, 0.5, 0.5)
    GameTooltip:AddLine(PallyPower_NotHere .. table.concat(btn.range, ", "), 0.5, 0.5, 1)
    GameTooltip:AddLine(PallyPower_Dead .. table.concat(btn.dead, ", "), 1, 0, 0)
    GameTooltip:Show()
end

function PallyPowerBuffButton_OnLeave(btn) GameTooltip:Hide() end

-- Scaling & options (unchanged behavior)
local function really_setpoint(frame, point, relativeTo, relativePoint, xoff, yoff)
    frame:SetPoint(point, relativeTo, relativePoint, xoff, yoff)
end
function PallyPower_StartScaling(arg1)
    if arg1 == "LeftButton" then
        this:LockHighlight()
        PallyPower.FrameToScale = this:GetParent()
        PallyPower.ScalingWidth = this:GetParent():GetWidth() * PallyPower.FrameToScale:GetParent():GetEffectiveScale()
        PallyPower.ScalingHeight = this:GetParent():GetHeight() * PallyPower.FrameToScale:GetParent():GetEffectiveScale()
        PallyPower_ScalingFrame:Show()
    end
end
function PallyPower_StopScaling(arg1)
    if arg1 == "LeftButton" then
        PallyPower_ScalingFrame:Hide()
        PallyPower.FrameToScale = nil
        this:UnlockHighlight()
    end
end
function PallyPower_ScaleFrame(scale)
    local frame = PallyPower.FrameToScale
    local oldscale = frame:GetScale() or 1
    local framex = (frame:GetLeft() or PallyPowerPerOptions.XPos) * oldscale
    local framey = (frame:GetTop() or PallyPowerPerOptions.YPos) * oldscale

    frame:SetScale(scale)
    if frame:GetName() == "PallyPowerFrame" then
        really_setpoint(PallyPowerFrame, "TOPLEFT", "UIParent", "BOTTOMLEFT", framex / scale, framey / scale)
        PP_PerUser.scalemain = scale
    end
    if frame:GetName() == "PallyPowerBuffBar" then
        really_setpoint(PallyPowerBuffBar, "TOPLEFT", "UIParent", "BOTTOMLEFT", framex / scale, framey / scale)
        PP_PerUser.scalebar = scale
    end
end
function PallyPower_ScalingFrame_OnUpdate(arg1)
    if not PallyPower.ScalingTime then PallyPower.ScalingTime = 0 end
    PallyPower.ScalingTime = PallyPower.ScalingTime + arg1
    if PallyPower.ScalingTime > 0.25 then
        PallyPower.ScalingTime = 0
        local frame = PallyPower.FrameToScale
        local oldscale = frame:GetEffectiveScale()
        local framex, framey, cursorx, cursory = frame:GetLeft() * oldscale, frame:GetTop() * oldscale, GetCursorPosition()
        if PallyPower.ScalingWidth > PallyPower.ScalingHeight then
            if (cursorx - framex) > 32 then
                local newscale = (cursorx - framex) / PallyPower.ScalingWidth
                PallyPower_ScaleFrame(newscale)
            end
        else
            if (framey - cursory) > 32 then
                local newscale = (framey - cursory) / PallyPower.ScalingHeight
                PallyPower_ScaleFrame(newscale)
            end
        end
    end
end

function PallyPower_SetOption(opt, value) PP_PerUser[opt] = value end

function PallyPower_ApplyOpacity()
    local alpha = PP_PerUser.opacity or 0.5
    if PallyPowerFrame then
        PallyPowerFrame:SetBackdropColor(0, 0, 0, alpha)
    end
    if PallyPower_OptionsFrame then
        PallyPower_OptionsFrame:SetBackdropColor(0, 0, 0, alpha)
    end
    uiDirty = true
end

function PallyPower_Options()
    PallyPowerFrame:Hide(); PallyPower_OptionsFrame:Show()
end

function PallyPower_ShowFeedback(msg, r, g, b, a)
    if PP_PerUser.chatfeedback then
        DEFAULT_CHAT_FRAME:AddMessage("[PallyPower] " .. msg, r, g, b, a)
    else
        UIErrorsFrame:AddMessage(msg, r, g, b, a)
    end
end

function PallyPowerGridButton_OnMouseWheel(btn, arg1)
    local _, _, pnum, class = string.find(btn:GetName(), "PallyPowerFramePlayer(.+)Class(.+)")
    pnum = pnum + 0; class = class + 0
    local pname = GetPlayerFrameEntry(pnum).name:GetText()
    if not PallyPower_CanControl(pname) then return end

    if arg1 == -1 then
        PallyPower_PerformCycle(pname, class)
    else
        PallyPower_PerformCycleBackwards(pname, class)
    end
end

function PallyPower_BarToggle()
    if ((GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0) or (PP_IsPally == false)) then
        PallyPower_ShowFeedback(" Not in raid or not a paladin", 0.5, 1, 1, 1)
    else
        if PallyPowerBuffBar:IsVisible() then
            PallyPowerBuffBar:Hide(); PallyPower_ShowFeedback(" Bar hidden", 0.5, 1, 1, 1)
        else
            PallyPowerBuffBar:Show(); PallyPower_ShowFeedback(" Bar visible", 0.5, 1, 1, 1)
        end
    end
end

-- =========================
--  Texture/Class lookups (unchanged)
-- =========================
PallyPower_ClassTexture = {}
PallyPower_ClassTexture[0] = "Interface\\AddOns\\PallyPower\\Icons\\Warrior"
PallyPower_ClassTexture[1] = "Interface\\AddOns\\PallyPower\\Icons\\Rogue"
PallyPower_ClassTexture[2] = "Interface\\AddOns\\PallyPower\\Icons\\Priest"
PallyPower_ClassTexture[3] = "Interface\\AddOns\\PallyPower\\Icons\\Druid"
PallyPower_ClassTexture[4] = "Interface\\AddOns\\PallyPower\\Icons\\Paladin"
PallyPower_ClassTexture[5] = "Interface\\AddOns\\PallyPower\\Icons\\Hunter"
PallyPower_ClassTexture[6] = "Interface\\AddOns\\PallyPower\\Icons\\Mage"
PallyPower_ClassTexture[7] = "Interface\\AddOns\\PallyPower\\Icons\\Warlock"
PallyPower_ClassTexture[8] = "Interface\\AddOns\\PallyPower\\Icons\\Shaman"
PallyPower_ClassTexture[9] = "Interface\\AddOns\\PallyPower\\Icons\\Pet"

local EN_CLASS_TO_ID = {
  WARRIOR=0, ROGUE=1, PRIEST=2, DRUID=3, PALADIN=4,
  HUNTER=5, MAGE=6, WARLOCK=7, SHAMAN=8, PET=9
}

function PallyPower_GetClassID(class)
  if not class then return -1 end
  -- accept both localized ("Paladin") and english token ("PALADIN")
  local up = string.upper(class)
  if EN_CLASS_TO_ID[up] then return EN_CLASS_TO_ID[up] end
  for id, name in PallyPower_ClassID do
    if name == class then
      return id
    end
  end
  return -1
end

function PallyPower_GetBuffTextureID(text)
    for id, name in BuffIcon do
        if name == text then return id end
    end
    return -2
end
