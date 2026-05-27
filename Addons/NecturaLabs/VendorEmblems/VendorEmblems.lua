-- VendorEmblems
-- Shows token currencies accepted by the current vendor (with player balance)
-- in the top-right empty area of the MerchantFrame.
-- Target: WoW 3.3.5a client (e.g. Warmane Onyxia).

local ICON_SIZE = 18
local SLOT_SPACING = 6
local RIGHT_EDGE_OFFSET = -44   -- from MerchantFrame TOPRIGHT, leaves clearance for the close button
local TOP_OFFSET = -40          -- below title band, above first item row
local MAX_SLOTS = 6
local BAG_UPDATE_THROTTLE = 0.2

local KIND_ITEM, KIND_HONOR, KIND_ARENA = 1, 2, 3

local HONOR_ICON_ALLIANCE = "Interface\\TargetingFrame\\UI-PVP-Alliance"
local HONOR_ICON_HORDE    = "Interface\\TargetingFrame\\UI-PVP-Horde"
local ARENA_ICON          = "Interface\\PVPFrame\\PVP-ArenaPoints-Icon"

local function GetHonorIcon()
    return (UnitFactionGroup("player") == "Alliance") and HONOR_ICON_ALLIANCE or HONOR_ICON_HORDE
end

local function ExtractItemID(link)
    if not link then return nil end
    local id = string.match(link, "item:(%d+)")
    return id and tonumber(id) or nil
end

local CURRENCY_HANDLERS = {
    [KIND_ITEM] = {
        balance = function(entry) return GetItemCount(entry.itemID) or 0 end,
        name    = function(entry) return (GetItemInfo(entry.itemID)) or "Unknown" end,
    },
    [KIND_HONOR] = {
        balance = function() return GetHonorCurrency() or 0 end,
        name    = function() return "Honor Points" end,
    },
    [KIND_ARENA] = {
        balance = function() return GetArenaCurrency() or 0 end,
        name    = function() return "Arena Points" end,
    },
}

local function GetCurrencyBalance(entry)
    local h = CURRENCY_HANDLERS[entry.kind]
    return h and h.balance(entry) or 0
end

local function GetCurrencyName(entry)
    local h = CURRENCY_HANDLERS[entry.kind]
    return h and h.name(entry) or "Currency"
end

local function FormatBalance(n)
    if n >= 10000 then
        return string.format("%.1fk", n / 1000)
    end
    return tostring(n)
end

local slots = {}

local function CreateSlot(index)
    local slot = CreateFrame("Frame", "VendorEmblemsSlot" .. index, MerchantFrame)
    slot:SetSize(ICON_SIZE, ICON_SIZE + 12)
    slot:EnableMouse(true)

    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetSize(ICON_SIZE, ICON_SIZE)
    slot.icon:SetPoint("TOP", slot, "TOP", 0, 0)
    slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    slot.count = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slot.count:SetPoint("TOP", slot.icon, "BOTTOM", 0, -1)
    slot.count:SetTextColor(1, 1, 1)

    slot:SetScript("OnEnter", function(self)
        local entry = self.entry
        if not entry then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if entry.kind == KIND_ITEM and entry.itemLink then
            GameTooltip:SetHyperlink(entry.itemLink)
        else
            GameTooltip:SetText(GetCurrencyName(entry), 1, 1, 1)
        end
        if entry.usedByItems and #entry.usedByItems > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Used to buy:", 0.6, 0.8, 1)
            for _, name in ipairs(entry.usedByItems) do
                GameTooltip:AddLine("  " .. name, 1, 1, 1)
            end
        end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

    slots[index] = slot
    return slot
end

local function HideAllSlots()
    for _, slot in ipairs(slots) do slot:Hide() end
end

local function AddUsage(entry, itemName)
    if not itemName then return end
    if entry.nameSet[itemName] then return end
    entry.nameSet[itemName] = true
    table.insert(entry.usedByItems, itemName)
end

local lastScanEntries = nil

local function ScanMerchantCurrencies()
    local entries, seen = {}, {}
    local honorEntry, arenaEntry

    local numItems = GetMerchantNumItems() or 0
    for i = 1, numItems do
        local itemName = GetMerchantItemInfo(i)
        local honorPoints, arenaPoints, itemCount = GetMerchantItemCostInfo(i)

        if honorPoints and honorPoints > 0 then
            if not honorEntry then
                honorEntry = {
                    kind = KIND_HONOR,
                    texture = GetHonorIcon(),
                    usedByItems = {},
                    nameSet = {},
                }
                table.insert(entries, honorEntry)
            end
            AddUsage(honorEntry, itemName)
        end

        if arenaPoints and arenaPoints > 0 then
            if not arenaEntry then
                arenaEntry = {
                    kind = KIND_ARENA,
                    texture = ARENA_ICON,
                    usedByItems = {},
                    nameSet = {},
                }
                table.insert(entries, arenaEntry)
            end
            AddUsage(arenaEntry, itemName)
        end

        if itemCount and itemCount > 0 then
            for j = 1, itemCount do
                local texture, _, link = GetMerchantItemCostItem(i, j)
                local itemID = ExtractItemID(link)
                if texture and itemID then
                    local entry = seen[itemID]
                    if not entry then
                        entry = {
                            kind = KIND_ITEM,
                            texture = texture,
                            itemID = itemID,
                            itemLink = link,
                            usedByItems = {},
                            nameSet = {},
                        }
                        seen[itemID] = entry
                        table.insert(entries, entry)
                    end
                    AddUsage(entry, itemName)
                end
            end
        end
    end

    return entries
end

local function UpdateDisplay()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        HideAllSlots()
        lastScanEntries = nil
        return
    end

    -- Only show on Merchant tab (1), not Buyback (2).
    if MerchantFrame.selectedTab ~= 1 then
        HideAllSlots()
        lastScanEntries = nil
        return
    end

    local entries = ScanMerchantCurrencies()
    lastScanEntries = entries
    HideAllSlots()
    if #entries == 0 then return end

    local n = math.min(#entries, MAX_SLOTS)
    local stride = ICON_SIZE + SLOT_SPACING

    for i = 1, n do
        local entry = entries[i]
        local slot = slots[i] or CreateSlot(i)
        slot.entry = entry
        slot.icon:SetTexture(entry.texture)
        slot.count:SetText(FormatBalance(GetCurrencyBalance(entry)))

        slot:ClearAllPoints()
        local xOffset = RIGHT_EDGE_OFFSET - (n - i) * stride
        slot:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", xOffset, TOP_OFFSET)
        slot:Show()
    end
end

-- BAG_UPDATE only changes player inventory balances, not the merchant's accepted
-- currencies. Refresh balance text only, without re-scanning the merchant inventory.
local function RefreshBalances()
    if not MerchantFrame or not MerchantFrame:IsShown() then return end
    if not lastScanEntries then return end
    local n = math.min(#lastScanEntries, MAX_SLOTS)
    for i = 1, n do
        local slot = slots[i]
        if slot and slot:IsShown() then
            slot.count:SetText(FormatBalance(GetCurrencyBalance(lastScanEntries[i])))
        end
    end
end

-- BAG_UPDATE fires several times in quick succession during purchases/loot; coalesce.
local throttleFrame = CreateFrame("Frame")
throttleFrame.pending = false
throttleFrame.elapsed = 0
throttleFrame:Hide()
throttleFrame:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = self.elapsed + elapsed
    if self.elapsed >= BAG_UPDATE_THROTTLE then
        self.elapsed = 0
        self.pending = false
        self:Hide()
        RefreshBalances()
    end
end)

local function ScheduleBalanceRefresh()
    if throttleFrame.pending then return end
    throttleFrame.pending = true
    throttleFrame.elapsed = 0
    throttleFrame:Show()
end

local function CancelBalanceRefresh()
    throttleFrame.pending = false
    throttleFrame.elapsed = 0
    throttleFrame:Hide()
end

local dispatcher = CreateFrame("Frame")
dispatcher:RegisterEvent("MERCHANT_CLOSED")
dispatcher:RegisterEvent("BAG_UPDATE")
dispatcher:SetScript("OnEvent", function(_, event)
    if event == "MERCHANT_CLOSED" then
        CancelBalanceRefresh()
        HideAllSlots()
        lastScanEntries = nil
    elseif event == "BAG_UPDATE" then
        if MerchantFrame and MerchantFrame:IsShown() then
            ScheduleBalanceRefresh()
        end
    end
end)

-- Hook MerchantFrame_Update to catch MERCHANT_SHOW, MERCHANT_UPDATE, tab switches,
-- and page changes in one place (they all funnel through this function in 3.3.5).
hooksecurefunc("MerchantFrame_Update", UpdateDisplay)
