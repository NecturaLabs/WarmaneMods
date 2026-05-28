-- VendorEmblems
-- Sidebar attached to the right of MerchantFrame, mirroring the Character
-- pane's Currency tab: section headers (Dungeon and Raid, Player vs Player...)
-- followed by their currency rows. Each row shows the currency name on the
-- left, the player's balance, and the currency icon on the far right.
-- Currencies the open vendor accepts are tinted gold, and hovering reveals
-- which items they buy.
-- Target: WoW 3.3.5a client (e.g. Warmane Onyxia).
--
-- Attachment strategy
-- -------------------
-- The sidebar is parented to MerchantFrame and anchored
--   TOPLEFT  ->  MerchantFrame TOPRIGHT  +  (computed X, 0)
-- which is a live relative anchor: if any mover addon repositions
-- MerchantFrame, the sidebar tracks it automatically with no extra work.
--
-- The X offset is COMPUTED at show time by scanning MerchantFrame's child
-- textures and finding the furthest-right pixel they actually draw to. The
-- offset places the sidebar's left BG edge exactly at that visible right edge
-- (with one BACKDROP_LEFT of additional overlap so our own left border ends
-- up entirely behind the merchant's right border and is masked by it -- the
-- sidebar's frame level is set one below MerchantFrame's, so within the same
-- strata our textures render below).
--
-- VendorEmblemsDB.overlap (slash command /ve offset N) overrides the auto
-- value if needed. Default = nil (auto).

local ROW_HEIGHT          = 22
local HEADER_HEIGHT       = 22
local HEADER_TOP_MARGIN   = 8       -- extra space above non-first section headers
local ICON_SIZE           = 18
local ICON_GAP            = 6       -- gap between trailing icon and adjacent text
local NAME_BALANCE_GAP    = 12

local INNER_LEFT          = 6
local INNER_RIGHT         = 6
local INNER_TOP           = 4
local INNER_BOTTOM        = 8
local BACKDROP_LEFT       = 11
local BACKDROP_RIGHT      = 12
local BACKDROP_TOP        = 12
local BACKDROP_BOTTOM     = 11
local BACKDROP_INSETS     = {
    left = BACKDROP_LEFT, right = BACKDROP_RIGHT,
    top  = BACKDROP_TOP,  bottom = BACKDROP_BOTTOM,
}
local MIN_CONTENT_WIDTH   = 130

local HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B = 1, 0.82, 0   -- WoW gold tint

local function ExtractItemID(link)
    if not link then return nil end
    local id = string.match(link, "item:(%d+)")
    return id and tonumber(id) or nil
end

local function FormatBalance(n)
    local s = tostring(n or 0)
    local neg, digits = s:match("^(%-?)(%d+)$")
    if not digits then return s end
    local formatted = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if formatted:sub(1, 1) == "," then formatted = formatted:sub(2) end
    return neg .. formatted
end

-- ---------------------------------------------------------------------------
-- Scanning
-- ---------------------------------------------------------------------------

local function ScanVendorCostMap()
    local costMap = {}
    if not MerchantFrame or not MerchantFrame:IsShown() then return costMap end
    if MerchantFrame.selectedTab ~= 1 then return costMap end

    local dedupSets = {}
    local numItems = GetMerchantNumItems() or 0
    for i = 1, numItems do
        local itemName = GetMerchantItemInfo(i)
        local numCurrencies = GetMerchantItemCostInfo(i) or 0
        if itemName and numCurrencies > 0 then
            for j = 1, numCurrencies do
                local _, _, link = GetMerchantItemCostItem(i, j)
                local currencyID = ExtractItemID(link)
                if currencyID then
                    local set = dedupSets[currencyID]
                    if not set then
                        set = {}
                        dedupSets[currencyID] = set
                        costMap[currencyID] = {}
                    end
                    if not set[itemName] then
                        set[itemName] = true
                        table.insert(costMap[currencyID], itemName)
                    end
                end
            end
        end
    end
    return costMap
end

local function ExpandAllHeaders()
    local changed
    repeat
        changed = false
        local count = GetCurrencyListSize() or 0
        for i = 1, count do
            local _, isHeader, isExpanded = GetCurrencyListInfo(i)
            if isHeader and not isExpanded then
                ExpandCurrencyList(i, 1)
                changed = true
                break
            end
        end
    until not changed
end

local function ScanCurrencies()
    ExpandAllHeaders()
    local entries = {}
    local count = GetCurrencyListSize() or 0
    for i = 1, count do
        local name, isHeader, _isExpanded, isUnused, _isWatched, balance,
              _extraCurrencyType, icon, itemID = GetCurrencyListInfo(i)
        if name and not isUnused then
            entries[#entries + 1] = {
                isHeader = isHeader,
                name     = name,
                icon     = icon,
                balance  = balance or 0,
                itemID   = itemID,
            }
        end
    end
    return entries
end

local function AnnotateUsage(entries, costMap)
    for _, entry in ipairs(entries) do
        if entry.itemID and not entry.isHeader then
            entry.usedByItems = costMap[entry.itemID]
        end
    end
end

-- ---------------------------------------------------------------------------
-- Sidebar window
-- ---------------------------------------------------------------------------

local sidebar = CreateFrame("Frame", "VendorEmblemsSidebar", MerchantFrame)
sidebar:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = BACKDROP_INSETS,
})
sidebar:Hide()

-- Find the furthest-right (or topmost) pixel actually drawn by MerchantFrame's
-- textures. May differ from MerchantFrame:GetRight()/GetTop() because Blizzard
-- frames often carry transparent padding past their visible texture.
local function ComputeMerchantVisibleEdges()
    if not MerchantFrame then return nil, nil end
    local maxR, maxT
    local nReg = MerchantFrame:GetNumRegions()
    for i = 1, nReg do
        local region = select(i, MerchantFrame:GetRegions())
        if region and region.GetObjectType
           and region:GetObjectType() == "Texture"
           and region:IsShown() then
            local r, t = region:GetRight(), region:GetTop()
            if r and (not maxR or r > maxR) then maxR = r end
            if t and (not maxT or t > maxT) then maxT = t end
        end
    end
    return maxR, maxT
end

-- Extra overlap (px) on each axis. Pulls the sidebar deeper INTO MerchantFrame
-- on the left and from the top so our entire left + top borders are masked by
-- merchant's right + top borders. Without these margins our 11/12px DialogBox
-- borders can stick out past merchant's narrower 6-10px borders, producing a
-- visible sliver that reads as a separate panel. 14 covers any standard width.
local SAFETY_OVERLAP_X    = 14
local SAFETY_OVERLAP_Y    = 14

-- Auto-computed live anchor: SetPoint relative to MerchantFrame makes the
-- sidebar follow any mover addon for free. The offsets compensate for the gap
-- between MerchantFrame:GetRight()/GetTop() (bounding box) and where the
-- texture actually ends, plus a safety overlap so the merchant's right + top
-- borders fully mask ours (we render one frame level below merchant).
--
-- Sign convention: SetPoint X<0 pulls left, Y<0 pulls down. We always want
-- both negative (deeper into merchant on both axes), so both terms subtract.
local function ComputeAutoOffsets()
    local visR, visT = ComputeMerchantVisibleEdges()
    local boundR = MerchantFrame and MerchantFrame:GetRight()
    local boundT = MerchantFrame and MerchantFrame:GetTop()
    local xGap = (visR and boundR) and (visR - boundR) or 0
    local yGap = (visT and boundT) and (visT - boundT) or 0
    local x = xGap - BACKDROP_LEFT - SAFETY_OVERLAP_X
    local y = yGap - BACKDROP_TOP  - SAFETY_OVERLAP_Y
    return x, y
end

local function ReanchorSidebar()
    local x, y = ComputeAutoOffsets()
    sidebar:ClearAllPoints()
    sidebar:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", x, y)
end
ReanchorSidebar()

local function SyncFrameLevel()
    local mLevel = MerchantFrame and MerchantFrame:GetFrameLevel()
    if mLevel and mLevel > 0 and sidebar:GetFrameLevel() ~= mLevel - 1 then
        sidebar:SetFrameLevel(mLevel - 1)
    end
end

local headerPool, currencyPool = {}, {}

local function CreateHeaderRow(index)
    local row = CreateFrame("Frame", "VendorEmblemsHeader" .. index, sidebar)
    row:SetHeight(HEADER_HEIGHT)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.text:SetPoint("LEFT",  row, "LEFT",  0, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetTextColor(HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B)

    headerPool[index] = row
    return row
end

local function CreateCurrencyRow(index)
    local row = CreateFrame("Frame", "VendorEmblemsRow" .. index, sidebar)
    row:SetHeight(ROW_HEIGHT)
    row:EnableMouse(true)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.balance = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.balance:SetPoint("RIGHT", row.icon, "LEFT", -ICON_GAP, 0)
    row.balance:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT",  row, "LEFT", 0, 0)
    row.name:SetPoint("RIGHT", row.balance, "LEFT", -NAME_BALANCE_GAP, 0)
    row.name:SetJustifyH("LEFT")

    row:SetScript("OnEnter", function(self)
        local entry = self.entry
        if not entry then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if entry.itemID then
            GameTooltip:SetHyperlink("item:" .. entry.itemID)
        else
            GameTooltip:SetText(entry.name or "Currency", 1, 1, 1)
        end
        if entry.usedByItems and #entry.usedByItems > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Used to buy here:", 0.6, 0.8, 1)
            for _, name in ipairs(entry.usedByItems) do
                GameTooltip:AddLine("  " .. name, 1, 1, 1)
            end
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    currencyPool[index] = row
    return row
end

sidebar:SetScript("OnHide", function()
    local owner = GameTooltip:GetOwner()
    if owner and owner:GetParent() == sidebar then
        GameTooltip:Hide()
    end
end)

local function HideAllRows()
    for _, row in ipairs(headerPool) do
        row:Hide()
        row:ClearAllPoints()
    end
    for _, row in ipairs(currencyPool) do
        row:Hide()
        row:ClearAllPoints()
        row.entry = nil
    end
end

local nameMeasure, balanceMeasure

local function EnsureMeasureStrings()
    if nameMeasure then return end
    nameMeasure = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameMeasure:Hide()
    balanceMeasure = UIParent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    balanceMeasure:Hide()
end

local function ComputeContentWidth(entries)
    EnsureMeasureStrings()
    local maxW = 0
    for _, entry in ipairs(entries) do
        if entry.isHeader then
            nameMeasure:SetText(entry.name or "")
            local headerW = (nameMeasure:GetStringWidth() or 0) - ICON_SIZE - ICON_GAP
            if headerW > maxW then maxW = headerW end
        else
            nameMeasure:SetText(entry.name or "")
            balanceMeasure:SetText(FormatBalance(entry.balance))
            local rowW = (nameMeasure:GetStringWidth() or 0)
                       + NAME_BALANCE_GAP
                       + (balanceMeasure:GetStringWidth() or 0)
            if rowW > maxW then maxW = rowW end
        end
    end
    return math.max(maxW, MIN_CONTENT_WIDTH)
end

local function ApplyLayout(entries)
    HideAllRows()
    if #entries == 0 then
        sidebar:Hide()
        return
    end

    local contentW = ComputeContentWidth(entries)
    local innerW   = contentW + ICON_GAP + ICON_SIZE
    local totalW   = BACKDROP_LEFT + INNER_LEFT + innerW + INNER_RIGHT + BACKDROP_RIGHT

    local rowsH = 0
    for i, entry in ipairs(entries) do
        if entry.isHeader then
            if i > 1 then rowsH = rowsH + HEADER_TOP_MARGIN end
            rowsH = rowsH + HEADER_HEIGHT
        else
            rowsH = rowsH + ROW_HEIGHT
        end
    end
    local totalH = BACKDROP_TOP + INNER_TOP + rowsH + INNER_BOTTOM + BACKDROP_BOTTOM

    sidebar:SetSize(totalW, totalH)

    local rowAreaLeft = BACKDROP_LEFT + INNER_LEFT
    local y = -(BACKDROP_TOP + INNER_TOP)
    local headerIdx, currencyIdx = 0, 0

    for i, entry in ipairs(entries) do
        if entry.isHeader then
            if i > 1 then y = y - HEADER_TOP_MARGIN end
            headerIdx = headerIdx + 1
            local row = headerPool[headerIdx] or CreateHeaderRow(headerIdx)
            row.text:SetText(entry.name or "")
            row:SetWidth(innerW)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", sidebar, "TOPLEFT", rowAreaLeft, y)
            row:Show()
            y = y - HEADER_HEIGHT
        else
            currencyIdx = currencyIdx + 1
            local row = currencyPool[currencyIdx] or CreateCurrencyRow(currencyIdx)
            row.entry = entry
            row.icon:SetTexture(entry.icon)
            row.name:SetText(entry.name or "?")
            if entry.usedByItems and #entry.usedByItems > 0 then
                row.name:SetTextColor(HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B)
            else
                row.name:SetTextColor(1, 1, 1)
            end
            row.balance:SetText(FormatBalance(entry.balance))
            row:SetWidth(innerW)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", sidebar, "TOPLEFT", rowAreaLeft, y)
            row:Show()
            y = y - ROW_HEIGHT
        end
    end

    sidebar:Show()
end

-- ---------------------------------------------------------------------------
-- Update / event wiring
-- ---------------------------------------------------------------------------

local function UpdateDisplay()
    if not MerchantFrame or not MerchantFrame:IsShown()
       or MerchantFrame.selectedTab ~= 1 then
        sidebar:Hide()
        HideAllRows()
        return
    end
    SyncFrameLevel()
    ReanchorSidebar()
    local entries = ScanCurrencies()
    if #entries == 0 then
        sidebar:Hide()
        HideAllRows()
        return
    end
    AnnotateUsage(entries, ScanVendorCostMap())
    ApplyLayout(entries)
end

local refreshScheduler = CreateFrame("Frame")
refreshScheduler.scheduled = false
refreshScheduler:Hide()
refreshScheduler:SetScript("OnUpdate", function(self)
    self.scheduled = false
    self:Hide()
    UpdateDisplay()
end)

local function ScheduleRefresh()
    if refreshScheduler.scheduled then return end
    refreshScheduler.scheduled = true
    refreshScheduler:Show()
end

local function CancelRefresh()
    refreshScheduler.scheduled = false
    refreshScheduler:Hide()
end

local dispatcher = CreateFrame("Frame")
dispatcher:RegisterEvent("MERCHANT_SHOW")
dispatcher:RegisterEvent("MERCHANT_CLOSED")
dispatcher:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
dispatcher:SetScript("OnEvent", function(_, event)
    if event == "MERCHANT_CLOSED" then
        CancelRefresh()
        sidebar:Hide()
        HideAllRows()
        return
    end
    if MerchantFrame and MerchantFrame:IsShown() and MerchantFrame.selectedTab == 1 then
        ScheduleRefresh()
    end
end)

hooksecurefunc("MerchantFrame_Update", function()
    if not MerchantFrame:IsShown() or MerchantFrame.selectedTab ~= 1 then
        CancelRefresh()
        sidebar:Hide()
        HideAllRows()
        return
    end
    ScheduleRefresh()
end)

