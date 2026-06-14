local LT = _G.LootTracker

local FRAME_WIDTH_MIN   = 320
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
local HOURGLASS_TEX     = "Interface\\Icons\\INV_Misc_PocketWatch_01"
local READYCHECK_TEX    = "Interface\\RaidFrame\\ReadyCheck-Ready"  -- green check for distributed items

local STICKY_PANEL_ROW_H    = 18
local STICKY_PANEL_HEADER_H = 20
local STICKY_PANEL_GAP_BOT  = 4
-- Cap on the panel's VISIBLE rows. The panel renders every eligible item into a
-- scrollable body; this only bounds how many show at once. GetActiveTradeTimers
-- sorts soonest-expiring first, so the visible window is always the 5 items
-- closest to expiry and the rest are reachable by scrolling. Outer height when
-- full: 20 + 5*18 + 4 = 114px, well within the space above the main viewport.
local STICKY_PANEL_MAX_ROWS = 5

-- Custom session-picker popup geometry. 3.3.5's native UIDropDownMenu has no
-- scroll support, so the session selector uses a capped, scrollable popup that
-- shows at most SESSION_PICKER_MAX_ROWS sessions and scrolls for the rest.
local SESSION_PICKER_ROW_H    = 18
local SESSION_PICKER_MAX_ROWS = 5
local SESSION_PICKER_PAD      = 6    -- inner padding inside the popup backdrop
local SESSION_PICKER_SBAR_W   = 18   -- scrollbar gutter reserved on overflow

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

-- WoW substitutes "..." for a unit/player name it hasn't resolved yet (a
-- cross-realm or just-joined raid member, an out-of-range looter — the same
-- case the roll-row equipped-lookup retry below already accounts for). That
-- placeholder is captured verbatim from loot/roll chat messages and stored, so
-- normalize it to a readable label at every name-display site. Doing it on the
-- display side (rather than at capture) heals already-stored data too, with no
-- migration. nil/empty get the same treatment.
local function DisplayName(name)
    if not name or name == "" or name == "..." then
        return UNKNOWN or "Unknown"
    end
    return name
end

local function FormatSessionLabel(s)
    return string.format("%s (%s) — %s",
        s.instanceName or "?",
        s.difficulty   or "?",
        date("%m-%d %H:%M", s.startedAt or 0))
end

local Refresh              -- forward declared; assigned below, captured by closures defined later
local ShowItemContextMenu  -- forward declared; assigned below, captured by row OnClick handlers

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

-- Track the dropdown's logical width so the custom session picker can match it.
-- Use SetDropdownWidth everywhere instead of calling UIDropDownMenu_SetWidth
-- directly, so currentDropdownWidth always reflects the live value.
local currentDropdownWidth = FRAME_WIDTH_MIN - 60
local function SetDropdownWidth(w)
    currentDropdownWidth = w
    UIDropDownMenu_SetWidth(dropdown, w)
end
SetDropdownWidth(FRAME_WIDTH_MIN - 60)

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

-- ---------------------------------------------------------------------------
-- Sticky "Trade Window" panel (above the scroll viewport, Bosses tab only)
-- ---------------------------------------------------------------------------

local tradePanel = CreateFrame("Frame", "LootTrackerTradePanel", frame)
tradePanel:SetPoint("TOPLEFT", PAD, -94)
tradePanel:SetPoint("TOPRIGHT", -28, -94)
tradePanel:Hide()

local tradePanelBg = tradePanel:CreateTexture(nil, "BACKGROUND")
tradePanelBg:SetAllPoints()
tradePanelBg:SetTexture(0.10, 0.10, 0.18, 0.55)

local tradePanelHeader = CreateFrame("Button", nil, tradePanel)
tradePanelHeader:SetHeight(STICKY_PANEL_HEADER_H)
tradePanelHeader:SetPoint("TOPLEFT", 0, 0)
tradePanelHeader:SetPoint("TOPRIGHT", 0, 0)
tradePanelHeader:RegisterForClicks("LeftButtonUp")

local tradePanelHourglass = tradePanelHeader:CreateTexture(nil, "ARTWORK")
tradePanelHourglass:SetSize(14, 14)
tradePanelHourglass:SetPoint("LEFT", 4, 0)
tradePanelHourglass:SetTexture(HOURGLASS_TEX)
tradePanelHourglass:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local tradePanelTitle = tradePanelHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
tradePanelTitle:SetPoint("LEFT", tradePanelHourglass, "RIGHT", 6, 0)

local tradePanelCaret = tradePanelHeader:CreateTexture(nil, "ARTWORK")
tradePanelCaret:SetSize(14, 14)
tradePanelCaret:SetPoint("RIGHT", -4, 0)

-- Scrollable body for the trade rows. The panel renders ALL eligible items
-- into tradeContent and clamps the visible viewport (tradeScroll) to at most
-- STICKY_PANEL_MAX_ROWS tall; when more items exist the rest are reachable by
-- scrolling instead of being truncated. The scrollbar is hidden when the full
-- list already fits. Mirrors the main list's UIPanelScrollFrameTemplate.
local tradeScroll = CreateFrame("ScrollFrame", "LootTrackerTradeScroll", tradePanel, "UIPanelScrollFrameTemplate")
tradeScroll:Hide()
-- UIPanelScrollFrameTemplate names its scrollbar "$parentScrollBar". Derive the
-- global from the frame's own name rather than hardcoding the literal, so the
-- lookup can't silently break if the scroll frame is ever renamed.
local tradeScrollBar = _G[tradeScroll:GetName() .. "ScrollBar"]

local tradeContent = CreateFrame("Frame", "LootTrackerTradeContent", tradeScroll)
tradeContent:SetSize(1, 1)
tradeScroll:SetScrollChild(tradeContent)

tradeScroll:EnableMouseWheel(true)
tradeScroll:SetScript("OnMouseWheel", function(self, delta)
    local cur = self:GetVerticalScroll() or 0
    local max = self:GetVerticalScrollRange() or 0
    local new = cur - delta * STICKY_PANEL_ROW_H * 2
    if new < 0 then new = 0 elseif new > max then new = max end
    self:SetVerticalScroll(new)
end)

-- Indexed by render slot (1..N), unlike bossHeaderPool / itemRowPool / rollRowPool
-- which use Acquire(pool, factory) with an inUse flag. Trade rows are rendered
-- in a single deterministic pass each Refresh, so slot identity == pool index.
local tradeRowPool = {}

local function MakeTradeRow()
    local r = CreateFrame("Button", nil, tradeContent)
    r:SetHeight(STICKY_PANEL_ROW_H)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(1, 1, 1, 0.06)
    hl:SetBlendMode("ADD")

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(12, 12)
    r.icon:SetPoint("LEFT", 6, 0)
    r.icon:SetTexture(HOURGLASS_TEX)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    r.timer = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.timer:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
    r.timer:SetWidth(64)
    r.timer:SetJustifyH("LEFT")

    r.nameText = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.nameText:SetPoint("LEFT", r.timer, "RIGHT", 4, 0)
    r.nameText:SetPoint("RIGHT", -4, 0)
    r.nameText:SetJustifyH("LEFT")

    r:SetScript("OnEnter", function(self)
        if not self.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.itemLink)
        if self.remainingSec and self.droppedAt then
            local mins = math.floor(self.remainingSec / 60)
            local secs = math.floor(self.remainingSec % 60)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(string.format(
                "Trade window: %dm %02ds remaining", mins, secs), 1, 1, 1)
            GameTooltip:AddLine(string.format(
                "Expires at %s", date("%I:%M:%S %p", self.droppedAt + 7200)),
                0.7, 0.7, 0.7)
        end
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
        end
    end)

    r:SetScript("OnClick", function(self, button)
        if button == "RightButton" and self.item and ShowItemContextMenu then
            ShowItemContextMenu(self.item)
        end
    end)

    r:Hide()
    return r
end

local function AcquireTradeRow(i)
    local r = tradeRowPool[i]
    if not r then
        r = MakeTradeRow()
        tradeRowPool[i] = r
    end
    return r
end

local function ReleaseTradeRowsFrom(i)
    for j = i, #tradeRowPool do
        local r = tradeRowPool[j]
        if r then
            r:Hide()
            r:ClearAllPoints()
            r.itemLink = nil
            r.item = nil
        end
    end
end

tradePanelHeader:SetScript("OnClick", function()
    LootTrackerDB = LootTrackerDB or {}
    LootTrackerDB.tradeTimers = LootTrackerDB.tradeTimers or {}
    LootTrackerDB.tradeTimers.panelCollapsed = not LootTrackerDB.tradeTimers.panelCollapsed
    if Refresh then Refresh() end
end)

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
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")

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

    -- "Distributed" marker: a green checkmark badge overlaid on the lower-left
    -- corner of the item icon. Hidden by default; shown by RenderItemRowAt when
    -- item.distributed and the display mode keeps the item in the list.
    r.check = r:CreateTexture(nil, "OVERLAY")
    r.check:SetSize(16, 16)
    r.check:SetPoint("CENTER", r.icon, "BOTTOMLEFT", 2, 2)
    r.check:SetTexture(READYCHECK_TEX)
    r.check:Hide()

    r.nameText = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.nameText:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.nameText:SetPoint("RIGHT", -4, 0)
    r.nameText:SetJustifyH("LEFT")

    r.timerFrame = CreateFrame("Frame", nil, r)
    r.timerFrame:SetSize(72, ROW_ITEM)
    r.timerFrame:SetPoint("RIGHT", -4, 0)
    r.timerFrame:EnableMouse(true)
    r.timerFrame:Hide()

    r.timerIcon = r.timerFrame:CreateTexture(nil, "ARTWORK")
    r.timerIcon:SetSize(12, 12)
    r.timerIcon:SetPoint("LEFT", 0, 0)
    r.timerIcon:SetTexture(HOURGLASS_TEX)
    r.timerIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    r.timerText = r.timerFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.timerText:SetPoint("LEFT", r.timerIcon, "RIGHT", 4, 0)
    r.timerText:SetPoint("RIGHT", 0, 0)
    r.timerText:SetJustifyH("LEFT")

    r.timerFrame:SetScript("OnEnter", function(self)
        local item = r.item
        if not item then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(item.itemLink or "?", 1, 1, 1)
        local remaining = LT:GetTradeRemaining(item)
        if remaining then
            local mins = math.floor(remaining / 60)
            local secs = math.floor(remaining % 60)
            GameTooltip:AddLine(string.format(
                "Trade window: %dm %02ds remaining", mins, secs), 1, 1, 1)
            GameTooltip:AddLine(string.format(
                "Expires at %s", date("%I:%M:%S %p", item.droppedAt + 7200)),
                0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    r.timerFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

    r:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if self.item and ShowItemContextMenu then ShowItemContextMenu(self.item) end
            return
        end
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
            if r.timerFrame then
                if r.timerFrame.pulseStarted then
                    r.timerFrame:SetScript("OnUpdate", nil)
                    r.timerFrame.pulseStarted = false
                end
                r.timerFrame:Hide()
            end
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
        local anyPending, anyResolved = false, false
        for widget, itemId in pairs(iconQueue) do
            local tex = FetchIcon(itemId)
            if tex then
                widget:SetTexture(tex)
                iconQueue[widget] = nil
                anyResolved = true
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
        -- An icon resolving means that item's info just landed in the client
        -- cache, so any aggregate row still showing the "[...]" cold-cache
        -- placeholder name (see ResolveAggregateLink) can now resolve to the
        -- real name. Re-render to heal those labels automatically — Refresh
        -- mutates iconQueue (ReleaseAll clears it, re-render re-queues), so it
        -- MUST run after the loop above, never mid-iteration. Refresh no-ops
        -- when the frame is hidden, so this is cheap when nobody's looking.
        if anyResolved and Refresh then Refresh() end
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

-- ---------------------------------------------------------------------------
-- Custom session picker
--
-- Replaces the native UIDropDownMenu list, which in 3.3.5 has no scroll support
-- and grows unbounded with many sessions. This popup expands downward from the
-- dropdown button, shows at most SESSION_PICKER_MAX_ROWS sessions at once, and
-- scrolls (scrollbar + mousewheel) through the rest. Sessions are listed newest
-- first, matching the old dropdown ordering.
-- ---------------------------------------------------------------------------

local sessionPickerRowPool = {}

-- Full-screen transparent catcher: a click anywhere outside the popup closes it
-- (the native dropdown got this behavior for free). Parented to `frame` so it
-- also vanishes when the main window is hidden.
local pickerCloser = CreateFrame("Button", nil, frame)
pickerCloser:SetFrameStrata("FULLSCREEN_DIALOG")
pickerCloser:SetAllPoints(UIParent)
pickerCloser:EnableMouse(true)
pickerCloser:Hide()

local sessionPicker = CreateFrame("Frame", "LootTrackerSessionPicker", frame)
sessionPicker:SetFrameStrata("FULLSCREEN_DIALOG")
sessionPicker:SetFrameLevel(pickerCloser:GetFrameLevel() + 10)
sessionPicker:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
sessionPicker:SetBackdropColor(0, 0, 0, 1)
sessionPicker:Hide()

local sessionScroll = CreateFrame("ScrollFrame", "LootTrackerSessionScroll", sessionPicker, "UIPanelScrollFrameTemplate")
local sessionScrollBar = _G[sessionScroll:GetName() .. "ScrollBar"]
local sessionContent = CreateFrame("Frame", nil, sessionScroll)
sessionContent:SetSize(1, 1)
sessionScroll:SetScrollChild(sessionContent)
sessionScroll:EnableMouseWheel(true)
sessionScroll:SetScript("OnMouseWheel", function(self, delta)
    local cur = self:GetVerticalScroll() or 0
    local max = self:GetVerticalScrollRange() or 0
    local new = cur - delta * SESSION_PICKER_ROW_H
    if new < 0 then new = 0 elseif new > max then new = max end
    self:SetVerticalScroll(new)
end)

local function HideSessionPicker()
    sessionPicker:Hide()
    pickerCloser:Hide()
end
pickerCloser:SetScript("OnClick", HideSessionPicker)

local function MakeSessionRow()
    local r = CreateFrame("Button", nil, sessionContent)
    r:SetHeight(SESSION_PICKER_ROW_H)
    r:RegisterForClicks("LeftButtonUp")

    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(1, 1, 1, 0.10)
    hl:SetBlendMode("ADD")

    r.check = r:CreateTexture(nil, "ARTWORK")
    r.check:SetSize(12, 12)
    r.check:SetPoint("LEFT", 4, 0)
    r.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")

    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.text:SetPoint("LEFT", r.check, "RIGHT", 4, 0)
    r.text:SetPoint("RIGHT", -4, 0)
    r.text:SetJustifyH("LEFT")

    r:SetScript("OnClick", function(self)
        if not self.sessionId then return end
        currentDisplaySessionId = self.sessionId
        UpdateDropdownText()
        HideSessionPicker()
        Refresh()
    end)
    r:Hide()
    return r
end

local function AcquireSessionRow(i)
    local r = sessionPickerRowPool[i]
    if not r then
        r = MakeSessionRow()
        sessionPickerRowPool[i] = r
    end
    return r
end

-- Lay out the popup over the current session list. Sizes the viewport to at
-- most SESSION_PICKER_MAX_ROWS rows and anchors the popup below the dropdown.
local function RenderSessionPicker()
    local sessions = LT:GetSessions()
    local shown = GetDisplaySession()
    local n = #sessions
    if n == 0 then HideSessionPicker() return end

    local y, idx = 0, 0
    for i = n, 1, -1 do          -- newest first
        idx = idx + 1
        local s = sessions[i]
        local r = AcquireSessionRow(idx)
        r:SetPoint("TOPLEFT", 0, -y)
        r:SetPoint("TOPRIGHT", 0, -y)
        if shown and shown.id == s.id then r.check:Show() else r.check:Hide() end
        r.text:SetText(FormatSessionLabel(s))
        r.sessionId = s.id
        r:Show()
        y = y + SESSION_PICKER_ROW_H
    end
    for j = idx + 1, #sessionPickerRowPool do
        local r = sessionPickerRowPool[j]
        if r then r:Hide(); r:ClearAllPoints(); r.sessionId = nil end
    end

    local fullH     = y
    local viewportH = math.min(fullH, SESSION_PICKER_MAX_ROWS * SESSION_PICKER_ROW_H)
    local overflow  = fullH > viewportH + 0.5
    local width     = math.max(currentDropdownWidth + 24, 160)
    local rightInset = overflow and SESSION_PICKER_SBAR_W or 0

    sessionScroll:ClearAllPoints()
    sessionScroll:SetPoint("TOPLEFT", SESSION_PICKER_PAD, -SESSION_PICKER_PAD)
    sessionScroll:SetSize(math.max(width - rightInset, 1), viewportH)
    sessionContent:SetSize(math.max(width - rightInset, 1), math.max(fullH, 1))

    if sessionScrollBar then
        if overflow then sessionScrollBar:Show() else sessionScrollBar:Hide() end
    end
    if not overflow then sessionScroll:SetVerticalScroll(0) end

    sessionPicker:SetSize(width + SESSION_PICKER_PAD * 2, viewportH + SESSION_PICKER_PAD * 2)
    sessionPicker:ClearAllPoints()
    -- Expand downward from the dropdown's text region.
    sessionPicker:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 16, 6)
end

local function ToggleSessionPicker()
    if sessionPicker:IsShown() then
        HideSessionPicker()
        return
    end
    if #LT:GetSessions() == 0 then return end
    RenderSessionPicker()
    pickerCloser:Show()
    -- Re-assert ordering on every open so the popup (and its rows) always sit
    -- above the click-catcher, independent of any later frame-level changes.
    sessionPicker:SetFrameLevel(pickerCloser:GetFrameLevel() + 10)
    sessionPicker:Show()
end

-- Hijack the native dropdown button: open our scrollable picker instead of the
-- (unscrollable) UIDropDownMenu list. The widget itself is kept only for its
-- label display (UIDropDownMenu_SetText) and width.
local dropdownButton = _G["LootTrackerSessionDropdownButton"]
if dropdownButton then
    dropdownButton:SetScript("OnClick", function() ToggleSessionPicker() end)
end

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
        { text = "Trade timers", isNotRadio = true, keepShownOnClick = true,
          checked = function()
              return LootTrackerDB and LootTrackerDB.tradeTimers
                  and LootTrackerDB.tradeTimers.enabled
          end,
          func = function()
              LootTrackerDB = LootTrackerDB or {}
              LootTrackerDB.tradeTimers = LootTrackerDB.tradeTimers or {}
              LootTrackerDB.tradeTimers.enabled = not LootTrackerDB.tradeTimers.enabled
              if Refresh then Refresh() end
          end },
        { text = "Mute trade alerts", isNotRadio = true, keepShownOnClick = true,
          checked = function()
              return LootTrackerDB and LootTrackerDB.tradeTimers
                  and not LootTrackerDB.tradeTimers.alerts
          end,
          func = function()
              LootTrackerDB = LootTrackerDB or {}
              LootTrackerDB.tradeTimers = LootTrackerDB.tradeTimers or {}
              LootTrackerDB.tradeTimers.alerts = not LootTrackerDB.tradeTimers.alerts
          end },
        { text = "Distributed items", notCheckable = true, hasArrow = true,
          menuList = {
              { text = "Show with checkmark",
                checked = function()
                    return (LootTrackerDB and LootTrackerDB.distributedMode or "check") == "check"
                end,
                func = function()
                    LootTrackerDB = LootTrackerDB or {}
                    LootTrackerDB.distributedMode = "check"
                    if Refresh then Refresh() end
                    CloseDropDownMenus()
                end },
              { text = "Remove from list",
                checked = function()
                    return LootTrackerDB and LootTrackerDB.distributedMode == "remove"
                end,
                func = function()
                    LootTrackerDB = LootTrackerDB or {}
                    LootTrackerDB.distributedMode = "remove"
                    if Refresh then Refresh() end
                    CloseDropDownMenus()
                end },
          } },
        { text = "", notCheckable = true, disabled = true },
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

-- Right-click context menu shared by Bosses-list item rows and Trade Window
-- rows. A single dropdown frame is reused for every row (EasyMenu rebuilds the
-- entries from the clicked item each time). Toggling distributed flips the flag
-- on the real item table (persisted) and refreshes; the rest of the pipeline
-- (Trade Window filter, alert ticker, list rendering) reacts to the new state.
local itemContextMenuFrame = CreateFrame("Frame", "LootTrackerItemContextMenu", UIParent, "UIDropDownMenuTemplate")

-- Assigned (not declared) — forward-declared near the top so row OnClick
-- closures defined earlier can call it.
ShowItemContextMenu = function(item)
    if not item then return end
    local name = (item.itemLink and item.itemLink:match("%[(.-)%]")) or "Item"
    local menu = {
        { text = name, isTitle = true, notCheckable = true },
        { text = item.distributed and "Unmark distributed" or "Mark as distributed",
          notCheckable = true,
          func = function()
              item.distributed = (not item.distributed) or nil
              -- Unmarking turns a static "distributed" row back into a live
              -- countdown, which needs the per-second ticker running. It may have
              -- self-stopped (e.g. this was the only in-window item and it was
              -- distributed, so nothing kept it alive). Restart it; harmless when
              -- already running — TickTradeTimers re-hides it if nothing is live.
              if LT.StartTradeTimerTicker then LT:StartTradeTimerTicker() end
              if Refresh then Refresh() end
          end },
        { text = CANCEL or "Cancel", notCheckable = true, func = function() end },
    }
    EasyMenu(menu, itemContextMenuFrame, "cursor", 0, 0, "MENU")
end

-- ---------------------------------------------------------------------------
-- Layout + viewport-aware render
-- ---------------------------------------------------------------------------

local function ComputeLayout(session)
    local removeMode = LootTrackerDB and LootTrackerDB.distributedMode == "remove"
    local entries = {}
    local y = PAD
    for _, boss in ipairs(session.bosses) do
        entries[#entries + 1] = { y = y, h = ROW_BOSS_HEADER, kind = "boss", data = boss }
        y = y + ROW_BOSS_HEADER + 2
        if not boss.collapsed then
            for _, item in ipairs(boss.items) do
                if not (removeMode and item.distributed) then
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

    -- Reset distributed visuals (rows are pooled). The distributed branch below
    -- re-applies them when needed.
    row.icon:SetDesaturated(false)
    row.check:Hide()

    if item.distributed then
        -- Settled item: green check on the icon, the timer slot reads a dim
        -- "distributed" instead of a countdown, and no last-minute pulse runs.
        -- (In remove-mode ComputeLayout omits the row entirely, so this only
        -- paints in check-mode — but it's safe regardless of mode.)
        row.check:Show()
        row.icon:SetDesaturated(true)
        if row.timerFrame.pulseStarted then
            row.timerFrame:SetScript("OnUpdate", nil)
            row.timerFrame.pulseStarted = false
        end
        row.timerIcon:Hide()
        row.timerText:SetText("|cff888888distributed|r")
        row.timerFrame:SetAlpha(1)
        row.timerFrame:Show()
        row.nameText:ClearAllPoints()
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.nameText:SetPoint("RIGHT", row.timerFrame, "LEFT", -4, 0)
        row:Show()
        return
    end

    -- Non-distributed rows always show the hourglass icon (a previously
    -- distributed render may have hidden it before the row was pooled).
    row.timerIcon:Show()

    local status = LT:GetTradeTimerStatus(item)
    local timersEnabled = LootTrackerDB and LootTrackerDB.tradeTimers
        and LootTrackerDB.tradeTimers.enabled
    if status and timersEnabled then
        row.timerText:SetText(string.format("|cff%s%s|r", status.color, status.text))
        row.timerFrame:SetAlpha(1)
        row.timerFrame:Show()
        row.nameText:ClearAllPoints()
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.nameText:SetPoint("RIGHT", row.timerFrame, "LEFT", -4, 0)

        -- Last-minute pulse: alpha-modulate the badge so the player sees the
        -- final 60s visually, not just numerically. Started lazily; stopped
        -- once the remaining time climbs back above (never naturally) or the
        -- row is released to its pool (see ReleaseAll).
        if status.remainingSec <= 60 then
            if not row.timerFrame.pulseStarted then
                -- Phase the pulse off GetTime() rather than accumulated dt so it
                -- stays continuous across the per-second Refresh teardown/rebuild
                -- (ReleaseAll clears this script every refresh) instead of
                -- restarting the sine wave each tick.
                row.timerFrame:SetScript("OnUpdate", function(self)
                    self:SetAlpha(0.4 + 0.6 * (math.sin(GetTime() * 4) * 0.5 + 0.5))
                end)
                row.timerFrame.pulseStarted = true
            end
        elseif row.timerFrame.pulseStarted then
            row.timerFrame:SetScript("OnUpdate", nil)
            row.timerFrame:SetAlpha(1)
            row.timerFrame.pulseStarted = false
        end
    else
        if row.timerFrame.pulseStarted then
            row.timerFrame:SetScript("OnUpdate", nil)
            row.timerFrame.pulseStarted = false
        end
        row.timerFrame:Hide()
        row.nameText:ClearAllPoints()
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.nameText:SetPoint("RIGHT", -4, 0)
    end

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
        -- Passes have no numeric roll; the dice icon already conveys "Pass".
        -- Leave the value column blank — the prior "0" placeholder added visual
        -- noise that read like a real roll of zero.
        rr.rollText:SetText("")
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
        ClassColorString(roll.class), DisplayName(roll.player)))

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

-- Resolve the best hyperlink for an aggregated entry. Emblems and other
-- currencies are routinely looted before their tooltip is ever shown, so the
-- link captured from the loot message can still carry 3.3.5's cold-cache
-- placeholder name ("[...]") — which renders as a bare "...". GetItemInfo(itemId)
-- returns a fully-resolved link once the client has the item cached. SetItemIcon
-- (called just before this) kicks off that caching via a tooltip scan, but the
-- fill is asynchronous (the icon ticker exists precisely because it can take a
-- few frames) — so for a truly cold item GetItemInfo still returns nil this
-- frame and we fall back to the stored placeholder link for this paint. The
-- icon ticker re-renders the moment that item's icon (and thus its cached info)
-- lands, at which point this resolves to the real name and we persist the
-- upgrade back onto the entry so it sticks for tooltips and all future renders.
-- Net effect: a cold currency shows the "..." placeholder for at most a fraction
-- of a second after the tab opens, then heals itself with no user action.
local function ResolveAggregateLink(entry, itemId)
    local _, freshLink = GetItemInfo(itemId)
    if freshLink then
        entry.itemLink = freshLink
        return freshLink
    end
    return entry.itemLink
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
        SetItemIcon(row.icon, rec.itemId)
        -- Aggregate rows never carry distributed state; clear the marker the
        -- shared item-row pool may have left behind from a Bosses-tab render.
        row.check:Hide()
        row.icon:SetDesaturated(false)
        row.timerIcon:Show()
        local itemLink = ResolveAggregateLink(rec.entry, rec.itemId)
        row.itemLink = itemLink
        row.expand:Hide()
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", 4, 0)
        if row.timerFrame then
            if row.timerFrame.pulseStarted then
                row.timerFrame:SetScript("OnUpdate", nil)
                row.timerFrame.pulseStarted = false
            end
            row.timerFrame:Hide()
        end

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
            rText = rText .. "|c" .. ClassColorString(class) .. DisplayName(r.name) .. "|r x" .. r.count
        end
        local recipientPart = (rText ~= "") and ("  (" .. rText .. ")") or ""

        local label = (itemLink or "?")
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
        SetDropdownWidth(math.max(FRAME_WIDTH_MIN - 60, 150))
    end
end

-- Render the sticky trade-window panel and return its outer height so the
-- caller can offset the scroll viewport's top edge. Returns 0 when hidden.
local function RenderTradePanel(session)
    local timers = session and LT:GetActiveTradeTimers(session) or {}
    local enabled = LootTrackerDB and LootTrackerDB.tradeTimers
        and LootTrackerDB.tradeTimers.enabled
    if not enabled or activeTab ~= TAB_BOSSES or #timers == 0 then
        tradePanel:Hide()
        tradeScroll:Hide()
        ReleaseTradeRowsFrom(1)
        return 0
    end

    local collapsed = LootTrackerDB.tradeTimers.panelCollapsed
    tradePanelCaret:SetTexture(collapsed and PLUS_TEX or MINUS_TEX)

    -- Re-check each timer's status ONCE here, before the collapsed/expanded
    -- split. GetActiveTradeTimers already filtered by remaining time, but a
    -- sub-second tick can push an item past expiry between that scan and now;
    -- doing the recheck up front means the header count, the rendered rows, and
    -- the collapsed-state count are all derived from the same `eligible` list
    -- and can never disagree. Each entry caches its status so the render loop
    -- below doesn't call GetTradeTimerStatus a second time.
    local eligible = {}
    for _, info in ipairs(timers) do
        local status = LT:GetTradeTimerStatus(info.item)
        if status then
            eligible[#eligible + 1] = { item = info.item, status = status }
        end
    end
    local count = #eligible

    if count == 0 then
        -- Every item in `timers` flipped past expiry between the initial scan
        -- and this recheck (extreme edge case). Hide the panel entirely rather
        -- than show an empty body or a misleading header count.
        tradePanel:Hide()
        tradeScroll:Hide()
        ReleaseTradeRowsFrom(1)
        return 0
    end

    tradePanelTitle:SetText(string.format(
        "|cffffd200Trade Window (%d %s)|r",
        count, (count == 1) and "item" or "items"))

    if collapsed then
        ReleaseTradeRowsFrom(1)
        tradeScroll:Hide()
        tradePanel:SetHeight(STICKY_PANEL_HEADER_H)
        tradePanel:Show()
        return STICKY_PANEL_HEADER_H + STICKY_PANEL_GAP_BOT
    end

    -- Render ALL eligible items into the scrollable content (no truncation).
    -- Rows are parented to tradeContent and anchored from y=0 (the header sits
    -- above the scroll viewport, not inside it).
    local y = 0
    for i, e in ipairs(eligible) do
        local r = AcquireTradeRow(i)
        r:SetPoint("TOPLEFT", 0, -y)
        r:SetPoint("TOPRIGHT", 0, -y)
        r.item         = e.item
        r.itemLink     = e.item.itemLink
        r.droppedAt    = e.item.droppedAt
        r.remainingSec = e.status.remainingSec
        if e.item.distributed then
            -- Shown only in "check" mode (remove-mode filters these out in
            -- GetActiveTradeTimers). Swap the hourglass for a green check and
            -- the countdown for a dim "distributed" label.
            r.icon:SetTexture(READYCHECK_TEX)
            r.icon:SetTexCoord(0, 1, 0, 1)
            r.timer:SetText("|cff888888distributed|r")
        else
            -- Restore the hourglass on pooled rows reused from a distributed one.
            r.icon:SetTexture(HOURGLASS_TEX)
            r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            r.timer:SetText(string.format("|cff%s%s|r", e.status.color, e.status.text))
        end
        r.nameText:SetText(e.item.itemLink or "?")
        r:Show()
        y = y + STICKY_PANEL_ROW_H
    end
    ReleaseTradeRowsFrom(count + 1)

    -- Clamp the visible viewport to STICKY_PANEL_MAX_ROWS; the rest scrolls.
    local fullH     = y
    local viewportH = math.min(fullH, STICKY_PANEL_MAX_ROWS * STICKY_PANEL_ROW_H)
    local overflow  = fullH > viewportH + 0.5

    -- Reserve the scrollbar gutter only when the list overflows, so a short
    -- list uses the full panel width.
    local rightInset = overflow and -22 or 0
    tradeScroll:ClearAllPoints()
    tradeScroll:SetPoint("TOPLEFT", 0, -STICKY_PANEL_HEADER_H)
    tradeScroll:SetPoint("TOPRIGHT", rightInset, -STICKY_PANEL_HEADER_H)
    tradeScroll:SetHeight(viewportH)

    -- Resolve content width with the same three-level fallback the main list
    -- uses (anchoring is deferred, so GetWidth can lag one frame after SetPoint).
    local w = tradeScroll:GetWidth()
    if not w or w < 1 then w = (tradePanel:GetWidth() or 0) + rightInset end
    if not w or w < 1 then w = frame:GetWidth() - PAD - 28 + rightInset end
    tradeContent:SetWidth(math.max(w, 1))
    tradeContent:SetHeight(math.max(fullH, 1))

    if tradeScrollBar then
        if overflow then tradeScrollBar:Show() else tradeScrollBar:Hide() end
    end
    if not overflow then tradeScroll:SetVerticalScroll(0) end
    tradeScroll:Show()

    tradePanel:SetHeight(STICKY_PANEL_HEADER_H + viewportH)
    tradePanel:Show()
    return STICKY_PANEL_HEADER_H + viewportH + STICKY_PANEL_GAP_BOT
end

-- Re-anchor the scroll viewport based on the sticky panel's current height.
-- The panel itself is anchored once at construction time and only changes
-- its height; here we only need to push the scroll's TOPLEFT down by the
-- panel's current outer height so the two don't overlap.
local function PositionScroll(stickyH)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", PAD, -94 - stickyH)
    scroll:SetPoint("BOTTOMRIGHT", -28, PAD + 2)
end

Refresh = function(reason)
    if not frame:IsShown() then return end

    -- "scroll" and "timer" reuse the cached layout: neither changes item
    -- geometry (scrolling moves the viewport; a timer tick only updates badge
    -- text + drops expired trade rows). Forcing ComputeLayout/ComputeAutoWidth
    -- on every 1s tick would be wasted work — the visible rows still re-render
    -- below from layoutCache, so inline timer badges update either way.
    if reason ~= "scroll" and reason ~= "timer" then layoutDirty = true end

    ReleaseAll()
    local session = GetDisplaySession()

    local stickyH = RenderTradePanel(session)
    PositionScroll(stickyH)

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
            SetDropdownWidth(math.max(target - 60, 150))
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
-- Timer ticks fire every second once any trade window is live. They only
-- affect countdown text and expired-row removal, not the session list or item
-- geometry, so refresh with the layout-preserving "timer" reason and skip the
-- dropdown rebuild OnDataChanged would otherwise do each second.
LT:On("TradeTimerTick",    function() Refresh("timer") end)

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
    elseif cmd == "mute" then
        LootTrackerDB = LootTrackerDB or {}
        LootTrackerDB.tradeTimers = LootTrackerDB.tradeTimers or {}
        LootTrackerDB.tradeTimers.alerts = not LootTrackerDB.tradeTimers.alerts
        local state = LootTrackerDB.tradeTimers.alerts and "unmuted" or "muted"
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd200LootTracker|r: trade alerts " .. state)
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
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd200LootTracker|r: /lt [toggle|show|hide|reset|mock|mute|debug|logclear]")
    end
end
