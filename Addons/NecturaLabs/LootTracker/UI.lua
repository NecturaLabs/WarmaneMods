local LT = _G.LootTracker

local FRAME_WIDTH_MIN   = 300
local FRAME_WIDTH_MAX   = 640
local FRAME_HEIGHT      = 500
local PAD               = 10
local ROW_BOSS_HEADER   = 22
local ROW_ITEM          = 28
local ROW_ROLL          = 18
local ICON_SIZE         = 22
local CLASS_TEX         = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
local DICE_TEX          = "Interface\\Buttons\\UI-GroupLoot-Dice-Up"
local COIN_TEX          = "Interface\\Buttons\\UI-GroupLoot-Coin-Up"
local DE_TEX            = "Interface\\Buttons\\UI-GroupLoot-DE-Up"
local PASS_TEX          = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
local UNKNOWN_ICON      = "Interface\\Icons\\INV_Misc_QuestionMark"
local PLUS_TEX          = "Interface\\Buttons\\UI-PlusButton-Up"
local MINUS_TEX         = "Interface\\Buttons\\UI-MinusButton-Up"

local ROLL_TYPE_TEX = {
    Need       = DICE_TEX,
    Greed      = COIN_TEX,
    Disenchant = DE_TEX,
    Pass       = PASS_TEX,
}

local CLASS_COORDS = CLASS_ICON_TCOORDS or {
    WARRIOR     = { 0,        0.25,     0,    0.25 },
    MAGE        = { 0.25,     0.49609,  0,    0.25 },
    ROGUE       = { 0.49609,  0.7421,   0,    0.25 },
    DRUID       = { 0.7421,   0.98828,  0,    0.25 },
    HUNTER      = { 0,        0.25,     0.25, 0.5  },
    SHAMAN      = { 0.25,     0.49609,  0.25, 0.5  },
    PRIEST      = { 0.49609,  0.7421,   0.25, 0.5  },
    WARLOCK     = { 0.7421,   0.98828,  0.25, 0.5  },
    PALADIN     = { 0,        0.25,     0.5,  0.75 },
    DEATHKNIGHT = { 0.25,     0.49609,  0.5,  0.75 },
}

local function ClassColorString(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and c.colorStr or "ffffffff"
end

local function FormatSessionLabel(s)
    return string.format("%s (%s) — %s",
        s.instanceName or "?",
        s.difficulty   or "?",
        date("%m-%d %H:%M", s.startedAt or 0))
end

local Refresh              -- forward declared; assigned below, captured by closures defined later

local TAB_BOSSES, TAB_CURRENCIES, TAB_MATERIALS = "bosses", "currencies", "materials"
local activeTab = TAB_BOSSES

-- ---------------------------------------------------------------------------
-- Main frame
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "LootTrackerMainFrame", UIParent)
frame:SetSize(FRAME_WIDTH_MIN, FRAME_HEIGHT)
frame:SetPoint("CENTER")
frame:SetFrameStrata("DIALOG")
frame:SetToplevel(true)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    LootTrackerDB = LootTrackerDB or {}
    local point, _, relPoint, x, y = self:GetPoint()
    LootTrackerDB.framePoint = { point, "UIParent", relPoint, x, y }
end)
frame:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:Hide()

frame:SetScript("OnShow", function() if Refresh then Refresh() end end)

local header = frame:CreateTexture(nil, "ARTWORK")
header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
header:SetWidth(230)
header:SetHeight(56)
header:SetPoint("TOP", 0, 12)

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", header, "TOP", 0, -14)
title:SetText("Loot Tracker")

local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -3, -3)

local cogBtn = CreateFrame("Button", "LootTrackerCogButton", frame)
cogBtn:SetSize(24, 24)
cogBtn:SetPoint("TOPLEFT", 7, -7)
cogBtn:SetNormalTexture("Interface\\Icons\\Trade_Engineering")
cogBtn:SetHighlightTexture("Interface\\Icons\\Trade_Engineering", "ADD")
local cogNormal = cogBtn:GetNormalTexture()
if cogNormal then cogNormal:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
local cogHighlight = cogBtn:GetHighlightTexture()
if cogHighlight then
    cogHighlight:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    cogHighlight:SetAlpha(0.6)
end
cogBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Options", 1, 1, 1)
    GameTooltip:Show()
end)
cogBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local cogMenuFrame = CreateFrame("Frame", "LootTrackerCogMenu", UIParent, "UIDropDownMenuTemplate")

local dropdown = CreateFrame("Frame", "LootTrackerSessionDropdown", frame, "UIDropDownMenuTemplate")
dropdown:SetPoint("TOPLEFT", PAD - 16, -34)
UIDropDownMenu_SetWidth(dropdown, FRAME_WIDTH_MIN - 60)

-- Tab strip between the session dropdown and the scroll area. Switches which
-- view of the current session is shown (bosses / currencies / materials).
-- Buttons are parented to `frame` so they don't scroll with content.
local function UpdateTabVisuals() end  -- forward decl; assigned below

local function MakeTabButton(label, tabKey, anchorTo)
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(90, 22)
    if anchorTo then
        b:SetPoint("LEFT", anchorTo, "RIGHT", 4, 0)
    else
        b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -68)
    end
    b:SetText(label)
    b:SetScript("OnClick", function()
        if activeTab == tabKey then return end
        activeTab = tabKey
        UpdateTabVisuals()
        if Refresh then Refresh() end
    end)
    return b
end

local tabBosses     = MakeTabButton("Bosses",     TAB_BOSSES,     nil)
local tabCurrencies = MakeTabButton("Currencies", TAB_CURRENCIES, tabBosses)
local tabMaterials  = MakeTabButton("Materials",  TAB_MATERIALS,  tabCurrencies)

UpdateTabVisuals = function()
    -- The active tab is shown depressed (disabled visual); clicks on it are
    -- already a no-op in the OnClick guard above.
    if activeTab == TAB_BOSSES then tabBosses:Disable() else tabBosses:Enable() end
    if activeTab == TAB_CURRENCIES then tabCurrencies:Disable() else tabCurrencies:Enable() end
    if activeTab == TAB_MATERIALS then tabMaterials:Disable() else tabMaterials:Enable() end
end
UpdateTabVisuals()

local scroll = CreateFrame("ScrollFrame", "LootTrackerScroll", frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", PAD, -94)
scroll:SetPoint("BOTTOMRIGHT", -28, PAD + 2)

local content = CreateFrame("Frame", "LootTrackerContent", scroll)
content:SetSize(scroll:GetWidth(), 1)
scroll:SetScrollChild(content)
-- Frame is not user-resizable; the only path that ever changes scroll's size
-- is Refresh itself, which now syncs content width inline. This handler stays
-- as a safety net for any future external resize trigger (e.g. UI scale).
scroll:SetScript("OnSizeChanged", function(self, w, h)
    content:SetWidth(w)
end)

local emptyLabel = content:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
emptyLabel:SetPoint("TOP", 0, -PAD)
emptyLabel:SetText("No loot tracked yet.\nKill a boss in a dungeon or raid.")
emptyLabel:SetJustifyH("CENTER")

-- ---------------------------------------------------------------------------
-- Row pools
-- ---------------------------------------------------------------------------

local bossHeaderPool, itemRowPool, rollRowPool = {}, {}, {}
local iconQueue = {}     -- widget -> itemId, polled by shared ticker
local scanner, iconTicker

local function MakeBossHeader()
    local r = CreateFrame("Button", nil, content)
    r:SetHeight(ROW_BOSS_HEADER)
    r:RegisterForClicks("LeftButtonUp")

    local bg = r:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0.15, 0.15, 0.25, 0.55)

    local highlight = r:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture(1, 1, 1, 0.08)
    highlight:SetBlendMode("ADD")

    r.expand = r:CreateTexture(nil, "ARTWORK")
    r.expand:SetSize(14, 14)
    r.expand:SetPoint("LEFT", 4, 0)

    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.text:SetPoint("LEFT", r.expand, "RIGHT", 4, 0)

    r.time = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.time:SetPoint("RIGHT", -6, 0)

    r:SetScript("OnClick", function(self)
        if not self.boss then return end
        self.boss.collapsed = not self.boss.collapsed or nil
        Refresh()
    end)
    r:Hide()
    return r
end

local function MakeItemRow()
    local r = CreateFrame("Button", nil, content)
    r:SetHeight(ROW_ITEM)
    r:RegisterForClicks("LeftButtonUp")

    local highlight = r:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.4)

    r.expand = r:CreateTexture(nil, "ARTWORK")
    r.expand:SetSize(16, 16)
    r.expand:SetPoint("LEFT", 4, 0)

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ICON_SIZE, ICON_SIZE)
    r.icon:SetPoint("LEFT", 24, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    r.nameText = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.nameText:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.nameText:SetPoint("RIGHT", -4, 0)
    r.nameText:SetJustifyH("LEFT")

    r:Hide()

    r:SetScript("OnEnter", function(self)
        if not self.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.itemLink)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)

    r:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        if not self.itemLink then return end
        if IsModifiedClick("CHATLINK") then
            local activeEdit = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
            if activeEdit then
                activeEdit:Insert(self.itemLink)
            else
                ChatFrame_OpenChat(self.itemLink)
            end
            self.linkHandled = true
        end
    end)

    r:SetScript("OnClick", function(self)
        if self.linkHandled then
            self.linkHandled = false
            return
        end
        if not self.item then return end
        self.item.expanded = not self.item.expanded
        Refresh()
    end)
    return r
end

local function MakeRollRow()
    local r = CreateFrame("Frame", nil, content)
    r:SetHeight(ROW_ROLL)

    r.dice = r:CreateTexture(nil, "ARTWORK")
    r.dice:SetSize(14, 14)
    r.dice:SetPoint("LEFT", 38, 0)
    r.dice:SetTexture(DICE_TEX)

    r.rollText = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.rollText:SetPoint("LEFT", r.dice, "RIGHT", 4, 0)
    r.rollText:SetWidth(34)
    r.rollText:SetJustifyH("LEFT")

    r.classIcon = r:CreateTexture(nil, "ARTWORK")
    r.classIcon:SetSize(14, 14)
    r.classIcon:SetPoint("LEFT", r.rollText, "RIGHT", 2, 0)
    r.classIcon:SetTexture(CLASS_TEX)

    r.equipped = CreateFrame("Button", nil, r)
    r.equipped:SetSize(16, 16)
    r.equipped:SetPoint("RIGHT", -4, 0)
    r.equippedTex = r.equipped:CreateTexture(nil, "ARTWORK")
    r.equippedTex:SetAllPoints()
    r.equippedTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.equipped:SetScript("OnEnter", function(self)
        if not self.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(self.itemLink)
        GameTooltip:Show()
    end)
    r.equipped:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.equipped:Hide()

    r.nameText = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.nameText:SetPoint("LEFT", r.classIcon, "RIGHT", 4, 0)
    r.nameText:SetJustifyH("LEFT")
    r:Hide()
    return r
end

local function Acquire(pool, factory)
    for _, r in ipairs(pool) do
        if not r.inUse then
            r.inUse = true
            return r
        end
    end
    local r = factory()
    r.inUse = true
    table.insert(pool, r)
    return r
end

local function ReleaseAll()
    for _, r in ipairs(itemRowPool) do
        if r.inUse then
            iconQueue[r.icon] = nil
            r.inUse = false
            r:Hide()
            r:ClearAllPoints()
            r.item, r.itemLink = nil, nil
        end
    end
    for _, r in ipairs(rollRowPool) do
        if r.inUse then
            if r.equippedTex then iconQueue[r.equippedTex] = nil end
            r.inUse = false
            r:Hide()
            r:ClearAllPoints()
        end
    end
    for _, r in ipairs(bossHeaderPool) do
        if r.inUse then
            r.inUse = false
            r.boss = nil
            r:Hide()
            r:ClearAllPoints()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Shared icon-cache ticker
-- ---------------------------------------------------------------------------

local function FetchIcon(itemId)
    return (GetItemIcon and GetItemIcon(itemId))
        or (select(10, GetItemInfo(itemId)))
end

local function EnsureIconTicker()
    if iconTicker then return end
    iconTicker = CreateFrame("Frame")
    local elapsed, attempts = 0, 0
    iconTicker:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < 0.3 then return end
        elapsed = 0
        attempts = attempts + 1
        local anyPending = false
        for widget, itemId in pairs(iconQueue) do
            local tex = FetchIcon(itemId)
            if tex then
                widget:SetTexture(tex)
                iconQueue[widget] = nil
            else
                anyPending = true
            end
        end
        if not anyPending then
            self:Hide()
            attempts = 0
        elseif attempts > 40 then
            for w in pairs(iconQueue) do iconQueue[w] = nil end
            self:Hide()
            attempts = 0
        end
    end)
end

local function SetItemIcon(widget, itemId)
    iconQueue[widget] = nil  -- drop any stale pending entry from a previous owner
    if not itemId then widget:SetTexture(UNKNOWN_ICON) return end
    local tex = FetchIcon(itemId)
    if tex then widget:SetTexture(tex) return end

    widget:SetTexture(UNKNOWN_ICON)
    if not scanner then
        scanner = CreateFrame("GameTooltip", "LootTrackerScannerTip", nil, "GameTooltipTemplate")
        scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    scanner:ClearLines()
    scanner:SetHyperlink("item:" .. itemId)

    EnsureIconTicker()
    iconQueue[widget] = itemId
    iconTicker:Show()
end

-- ---------------------------------------------------------------------------
-- Session selection
-- ---------------------------------------------------------------------------

local currentDisplaySessionId = nil

local function GetDisplaySession()
    local sessions = LT:GetSessions()
    if currentDisplaySessionId then
        for _, s in ipairs(sessions) do
            if s.id == currentDisplaySessionId then return s end
        end
    end
    return LT.currentSession or sessions[#sessions]
end

local function UpdateDropdownText()
    local s = GetDisplaySession()
    UIDropDownMenu_SetText(dropdown, s and FormatSessionLabel(s) or "No sessions yet")
end

local function InitDropdown(_, level)
    local sessions = LT:GetSessions()
    local shown = GetDisplaySession()
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        local info = UIDropDownMenu_CreateInfo()
        info.text  = FormatSessionLabel(s)
        info.value = s.id
        info.checked = (shown and shown.id == s.id)
        info.func = function(self)
            currentDisplaySessionId = self.value
            UpdateDropdownText()
            Refresh()
        end
        UIDropDownMenu_AddButton(info, level)
    end
end
UIDropDownMenu_Initialize(dropdown, InitDropdown)

StaticPopupDialogs["LOOTTRACKER_DELETE_ALL_CONFIRM"] = {
    text = "Delete all loot history?\nThis wipes every saved session.",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        LT:Reset()
        currentDisplaySessionId = nil
        UpdateDropdownText()
        if Refresh then Refresh() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["LOOTTRACKER_DELETE_SESSION_CONFIRM"] = {
    text = "Delete this session?\n%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, sessionId)
        LT:DeleteSession(sessionId)
        if currentDisplaySessionId == sessionId then
            currentDisplaySessionId = nil
        end
        UpdateDropdownText()
        if Refresh then Refresh() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function BuildCogMenu()
    local current = GetDisplaySession()
    return {
        { text = "Loot Tracker", isTitle = true, notCheckable = true },
        { text = "Generate mock data", notCheckable = true,
          func = function()
              LT:GenerateMockData()
              if not frame:IsShown() then frame:Show() else Refresh() end
          end },
        { text = "", notCheckable = true, disabled = true },
        { text = "Delete current session...", notCheckable = true,
          disabled = (current == nil),
          func = function()
              local s = GetDisplaySession()
              if not s then return end
              StaticPopup_Show("LOOTTRACKER_DELETE_SESSION_CONFIRM",
                  FormatSessionLabel(s), nil, s.id)
          end },
        { text = "Delete all sessions...", notCheckable = true,
          func = function() StaticPopup_Show("LOOTTRACKER_DELETE_ALL_CONFIRM") end },
        { text = "", notCheckable = true, disabled = true },
        { text = "Close window", notCheckable = true,
          func = function() frame:Hide() end },
        { text = "Cancel", notCheckable = true,
          func = function() end },
    }
end

cogBtn:SetScript("OnClick", function(self)
    EasyMenu(BuildCogMenu(), cogMenuFrame, self, 0, 0, "MENU")
end)

-- ---------------------------------------------------------------------------
-- Layout + viewport-aware render
-- ---------------------------------------------------------------------------

local function ComputeLayout(session)
    local entries = {}
    local y = PAD
    for _, boss in ipairs(session.bosses) do
        entries[#entries + 1] = { y = y, h = ROW_BOSS_HEADER, kind = "boss", data = boss }
        y = y + ROW_BOSS_HEADER + 2
        if not boss.collapsed then
            for _, item in ipairs(boss.items) do
                entries[#entries + 1] = { y = y, h = ROW_ITEM, kind = "item", data = item }
                y = y + ROW_ITEM
                if item.expanded then
                    if #item.rolls == 0 then
                        entries[#entries + 1] = { y = y, h = ROW_ROLL, kind = "empty", data = item }
                        y = y + ROW_ROLL
                    else
                        for _, roll in ipairs(item.rolls) do
                            entries[#entries + 1] = { y = y, h = ROW_ROLL, kind = "roll",
                                data = roll, parentItem = item }
                            y = y + ROW_ROLL
                        end
                    end
                end
            end
        end
        y = y + 4
    end
    return entries, y + PAD
end

local layoutCache, layoutTotalH
local layoutDirty = true

local measureFS
local function MeasureItemLabel(item)
    if not measureFS then
        measureFS = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        measureFS:Hide()
    end
    local label = item.itemLink or "?"
    if item.count and item.count > 1 then
        label = label .. "  |cffaaaaaax" .. item.count .. "|r"
    end
    measureFS:SetText(label)
    return measureFS:GetStringWidth() or 0
end

-- Item row internals: 4 (left pad) + 16 (expand) + 4 (gap) + 22 (icon) + 6 (gap)
--                     + nameWidth + 4 (right pad) = 56 + nameWidth
-- Scroll chrome: 10 (left pad) + 28 (scrollbar gutter) = 38
-- So frame width needed = nameWidth + 56 + 38 = nameWidth + 94
local ROW_NAME_CHROME = 94

local function ComputeAutoWidth(session)
    local maxW = 0
    for _, boss in ipairs(session.bosses) do
        for _, item in ipairs(boss.items) do
            local w = MeasureItemLabel(item)
            if w > maxW then maxW = w end
        end
    end
    return math.min(math.max(maxW + ROW_NAME_CHROME, FRAME_WIDTH_MIN), FRAME_WIDTH_MAX)
end

local function RenderBossHeaderAt(boss, width, y)
    local hdr = Acquire(bossHeaderPool, MakeBossHeader)
    hdr:SetWidth(width)
    hdr:SetPoint("TOPLEFT", 0, -y)
    hdr.boss = boss
    hdr.text:SetText("|cffffd200" .. (boss.name or "?") .. "|r")
    hdr.time:SetText("|cff888888[" .. date("%I:%M %p", boss.killedAt or 0) .. "]|r")
    hdr.expand:SetTexture(boss.collapsed and PLUS_TEX or MINUS_TEX)
    hdr:Show()
end

local function RenderItemRowAt(item, width, y)
    local row = Acquire(itemRowPool, MakeItemRow)
    row:SetWidth(width)
    row:SetPoint("TOPLEFT", 0, -y)
    row.item = item
    row.itemLink = item.itemLink
    local label = item.itemLink or "?"
    if item.count and item.count > 1 then
        label = label .. "  |cffaaaaaax" .. item.count .. "|r"
    end
    row.nameText:SetText(label)
    SetItemIcon(row.icon, item.itemId)
    -- Restore the expand caret + standard icon anchor in case this row was
    -- previously rendered as an aggregate-tab row (which hides expand and
    -- moves the icon flush left).
    row.expand:Show()
    row.expand:SetTexture(item.expanded and MINUS_TEX or PLUS_TEX)
    row.icon:ClearAllPoints()
    row.icon:SetPoint("LEFT", 24, 0)
    row:Show()
end

local function RenderEmptyRollRowAt(width, y)
    local rr = Acquire(rollRowPool, MakeRollRow)
    rr:SetWidth(width)
    rr:SetPoint("TOPLEFT", 0, -y)
    rr.rollText:SetText("--")
    rr.dice:SetTexture(DICE_TEX)
    rr.dice:SetTexCoord(0, 1, 0, 1)
    rr.classIcon:SetTexture(nil)
    rr.nameText:SetText("|cff888888no rolls yet|r")
    rr.equipped:Hide()
    rr.equipped.itemLink = nil
    rr.nameText:ClearAllPoints()
    rr.nameText:SetPoint("LEFT", rr.classIcon, "RIGHT", 4, 0)
    rr.nameText:SetPoint("RIGHT", -4, 0)
    rr:Show()
end

local function RenderRollRowAt(roll, width, y, parentItem)
    local rr = Acquire(rollRowPool, MakeRollRow)
    rr:SetWidth(width)
    rr:SetPoint("TOPLEFT", 0, -y)

    -- Lazy-retry the equipped-slot lookup. At roll time the inspect cache
    -- may not yet have the player's gear (cross-realm name, just-joined
    -- raid member, etc.) so equippedLink was stored as nil. Try again now;
    -- if the cache has populated since, cache the result on the roll. If it
    -- still hasn't, kick off a throttled NotifyInspect — INSPECT_TALENT_READY
    -- will refresh the UI and the next render will pick up the link.
    if not roll.equippedLink and parentItem and parentItem.itemLink and roll.player then
        roll.equippedLink = LT:GetEquippedForCompare(roll.player, parentItem.itemLink)
        if not roll.equippedLink then
            LT:RequestInspect(roll.player)
        end
    end

    rr.dice:SetTexture(ROLL_TYPE_TEX[roll.rollType] or DICE_TEX)
    rr.dice:SetTexCoord(0, 1, 0, 1)

    if roll.rollType == "Pass" then
        rr.rollText:SetText("|cff8888880|r")
    elseif roll.value == nil then
        -- Intent-only entry: the player selected Need/Greed/Disenchant but
        -- the server never broadcast the numeric roll (3.3.5 suppresses
        -- losing-type rolls — e.g. when any Need rolls, the Greeders'
        -- values are dropped). The dice icon already conveys the rolltype;
        -- leave the value column blank rather than fake a number.
        rr.rollText:SetText("")
    else
        rr.rollText:SetText(tostring(roll.value))
    end

    local coords = roll.class and CLASS_COORDS[roll.class]
    if coords then
        rr.classIcon:SetTexture(CLASS_TEX)
        rr.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        rr.classIcon:SetTexture(nil)
    end
    rr.nameText:SetText(string.format("|c%s%s|r",
        ClassColorString(roll.class), roll.player or "?"))

    rr.nameText:ClearAllPoints()
    rr.nameText:SetPoint("LEFT", rr.classIcon, "RIGHT", 4, 0)
    if roll.equippedLink then
        rr.equipped:Show()
        rr.equipped.itemLink = roll.equippedLink
        local itemId = tonumber(roll.equippedLink:match("|Hitem:(%d+):"))
        if itemId then
            SetItemIcon(rr.equippedTex, itemId)
        else
            rr.equippedTex:SetTexture(UNKNOWN_ICON)
        end
        rr.nameText:SetPoint("RIGHT", rr.equipped, "LEFT", -4, 0)
    else
        rr.equipped:Hide()
        rr.equipped.itemLink = nil
        rr.nameText:SetPoint("RIGHT", -4, 0)
    end
    rr:Show()
end

-- Tabs 10 and 11 wire in real Currencies / Materials renderers. For now,
-- a placeholder empty-state covers those branches so the tab strip is
-- usable from this task onwards.
local placeholderTabLabel
local function ShowPlaceholderTabLabel(text)
    if not placeholderTabLabel then
        placeholderTabLabel = content:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
        placeholderTabLabel:SetPoint("TOP", 0, -PAD)
        placeholderTabLabel:SetJustifyH("CENTER")
    end
    placeholderTabLabel:SetText(text)
    placeholderTabLabel:Show()
end
local function HidePlaceholderTabLabel()
    if placeholderTabLabel then placeholderTabLabel:Hide() end
end

-- Resolve the current usable content width. Three-level fallback covers
-- the WoW timing quirk where `content`/`scroll` may not have a populated
-- width yet during the first layout pass after a frame resize.
local function GetContentWidth()
    local w = content:GetWidth()
    if not w or w < 1 then w = scroll:GetWidth() end
    if not w or w < 1 then w = frame:GetWidth() - 38 end
    return w
end

-- Render one row per aggregated item in `bucket` (session.currencies or
-- session.materials). The row reuses the existing item-row pool/widget but
-- with `row.item = nil`, which makes its OnClick a no-op (no expand/collapse).
-- Tooltips and shift-clicking still work because itemLink is populated.
-- Returns the total content height in pixels for the caller to apply.
local function RenderAggregateTab(bucket, emptyText)
    if not bucket or not next(bucket) then
        ShowPlaceholderTabLabel(emptyText)
        return 120
    end
    HidePlaceholderTabLabel()

    -- Stable ordering: descending count, then ascending itemId for ties.
    local ordered = {}
    for itemId, entry in pairs(bucket) do
        ordered[#ordered + 1] = { itemId = itemId, entry = entry }
    end
    table.sort(ordered, function(a, b)
        if a.entry.count ~= b.entry.count then
            return a.entry.count > b.entry.count
        end
        return a.itemId < b.itemId
    end)

    local width = GetContentWidth()

    local y = PAD
    for _, rec in ipairs(ordered) do
        local row = Acquire(itemRowPool, MakeItemRow)
        row:SetWidth(width)
        row:SetPoint("TOPLEFT", 0, -y)
        row.item     = nil
        row.itemLink = rec.entry.itemLink
        SetItemIcon(row.icon, rec.itemId)
        row.expand:Hide()
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", 4, 0)

        -- Sort recipients by descending count for the parenthetical breakdown.
        local rNames = {}
        for name, count in pairs(rec.entry.recipients) do
            rNames[#rNames + 1] = { name = name, count = count }
        end
        table.sort(rNames, function(a, b) return a.count > b.count end)
        local rText = ""
        for i, r in ipairs(rNames) do
            if i > 1 then rText = rText .. ", " end
            local class = LT:GetPlayerClass(r.name)
            rText = rText .. "|c" .. ClassColorString(class) .. r.name .. "|r x" .. r.count
        end
        local recipientPart = (rText ~= "") and ("  (" .. rText .. ")") or ""

        local label = (rec.entry.itemLink or "?")
            .. "  |cffaaaaaax" .. rec.entry.count .. "|r"
            .. recipientPart
        row.nameText:SetText(label)
        row:Show()

        y = y + ROW_ITEM
    end

    return y + PAD
end

-- Reset the frame to its minimum width when leaving the Bosses tab.
-- The Bosses tab can widen the frame via ComputeAutoWidth to fit long
-- item names; that width is sticky when switching to Currencies/Materials,
-- which use simpler row layouts and don't need it.
local function ResetFrameWidthToMin()
    if math.abs(frame:GetWidth() - FRAME_WIDTH_MIN) > 0.5 then
        frame:SetWidth(FRAME_WIDTH_MIN)
        content:SetWidth(FRAME_WIDTH_MIN - PAD - 28)
        UIDropDownMenu_SetWidth(dropdown, math.max(FRAME_WIDTH_MIN - 60, 150))
    end
end

Refresh = function(reason)
    if not frame:IsShown() then return end

    if reason ~= "scroll" then layoutDirty = true end

    ReleaseAll()
    local session = GetDisplaySession()
    if not session then
        HidePlaceholderTabLabel()
        emptyLabel:Show()
        content:SetHeight(120)
        layoutDirty = true
        return
    end

    if activeTab == TAB_BOSSES then
        HidePlaceholderTabLabel()
        if #session.bosses == 0 then
            emptyLabel:Show()
            content:SetHeight(120)
            layoutDirty = true
            return
        end
        emptyLabel:Hide()

        if layoutDirty then
            layoutCache, layoutTotalH = ComputeLayout(session)
            layoutDirty = false
            local target = ComputeAutoWidth(session)
            if math.abs(frame:GetWidth() - target) > 0.5 then
                frame:SetWidth(target)
                -- Sync content width inline. scroll's OnSizeChanged fires deferred,
                -- so without this, the first row-render below would use stale width.
                content:SetWidth(target - PAD - 28)
            end
            UIDropDownMenu_SetWidth(dropdown, math.max(target - 60, 150))
        end
        content:SetHeight(math.max(layoutTotalH, 1))

        local width = GetContentWidth()

        local scrollY   = scroll:GetVerticalScroll() or 0
        local viewportH = scroll:GetHeight()
        if not viewportH or viewportH < 1 then viewportH = FRAME_HEIGHT - 70 end
        local buffer = 80
        local topY    = scrollY - buffer
        local botY    = scrollY + viewportH + buffer

        for _, e in ipairs(layoutCache) do
            if e.y + e.h >= topY and e.y <= botY then
                if e.kind == "boss"  then RenderBossHeaderAt(e.data, width, e.y)
                elseif e.kind == "item"  then RenderItemRowAt(e.data, width, e.y)
                elseif e.kind == "empty" then RenderEmptyRollRowAt(width, e.y)
                elseif e.kind == "roll"  then RenderRollRowAt(e.data, width, e.y, e.parentItem)
                end
            end
        end
    elseif activeTab == TAB_CURRENCIES then
        emptyLabel:Hide()
        ResetFrameWidthToMin()
        local h = RenderAggregateTab(session.currencies, "No currencies this session.")
        content:SetHeight(math.max(h, 1))
        layoutDirty = true
    elseif activeTab == TAB_MATERIALS then
        emptyLabel:Hide()
        ResetFrameWidthToMin()
        local h = RenderAggregateTab(session.materials, "No materials this session.")
        content:SetHeight(math.max(h, 1))
        layoutDirty = true
    end
end

scroll:HookScript("OnVerticalScroll", function(self, offset)
    if Refresh then Refresh("scroll") end
end)

-- ---------------------------------------------------------------------------
-- Event hookup
-- ---------------------------------------------------------------------------

LT:On("AddonLoaded", function()
    LootTrackerDB = LootTrackerDB or {}
    if LootTrackerDB.framePoint then
        frame:ClearAllPoints()
        frame:SetPoint(unpack(LootTrackerDB.framePoint))
    end
    UpdateDropdownText()
    Refresh()
end)

local function OnDataChanged()
    UpdateDropdownText()
    Refresh()
end
LT:On("SessionChanged",    OnDataChanged)
LT:On("BossKilled",        OnDataChanged)
LT:On("ItemReceived",      OnDataChanged)
LT:On("RollAdded",         OnDataChanged)
LT:On("CurrencyReceived",  OnDataChanged)
LT:On("MaterialReceived",  OnDataChanged)

-- INSPECT_TALENT_READY can fire several times per second in raids (other
-- addons doing their own inspects also trigger it). Debounce so we don't
-- thrash the UI — coalesce multiple events within ~300ms into one refresh.
-- The frame is created once at file scope; WoW frames are not GC'd, so we
-- Show/Hide a single frame instead of allocating one per debounce burst.
local inspectDebounceFrame = CreateFrame("Frame")
inspectDebounceFrame:Hide()
local inspectDebounceElapsed = 0
inspectDebounceFrame:SetScript("OnUpdate", function(self, dt)
    inspectDebounceElapsed = inspectDebounceElapsed + dt
    if inspectDebounceElapsed < 0.3 then return end
    self:Hide()
    OnDataChanged()
end)
LT:On("InspectReady", function()
    inspectDebounceElapsed = 0
    inspectDebounceFrame:Show()
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_LOOTTRACKER1 = "/loottracker"
SLASH_LOOTTRACKER2 = "/lt"
SlashCmdList["LOOTTRACKER"] = function(msg)
    local cmd = ((msg or ""):match("^%s*(%S*)") or ""):lower()
    if cmd == "" or cmd == "toggle" then
        if frame:IsShown() then frame:Hide() else frame:Show() end
    elseif cmd == "show" then
        frame:Show()
    elseif cmd == "hide" then
        frame:Hide()
    elseif cmd == "reset" then
        LT:Reset()
    elseif cmd == "mock" then
        LT:GenerateMockData()
        if not frame:IsShown() then frame:Show() else Refresh() end
    elseif cmd == "debug" then
        LT.debug = not LT.debug
        if LT.debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd200LootTracker|r: debug ON — "
                .. "raw CHAT_MSG_LOOT text echoed here AND appended to "
                .. "LootTrackerDB.debugLog. /reload to flush to disk, then:")
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd200LootTracker|r:   "
                .. "WTF\\Account\\<Account>\\<Server>\\<Char>\\SavedVariables\\LootTracker.lua")
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd200LootTracker|r: "
                .. "/lt logclear to wipe the saved log.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd200LootTracker|r: debug OFF")
        end
    elseif cmd == "logclear" then
        if LT.debugLog then
            local n = #LT.debugLog
            for i = n, 1, -1 do LT.debugLog[i] = nil end
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd200LootTracker|r: cleared "
                .. n .. " debug log lines.")
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd200LootTracker|r: /lt [toggle|show|hide|reset|mock|debug|logclear]")
    end
end
