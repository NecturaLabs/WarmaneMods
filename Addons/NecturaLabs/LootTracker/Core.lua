-- Create or reuse the addon's shared table. `or {}` keeps load order robust
-- (UI.lua reads this same global; nothing else creates it).
local LT = _G.LootTracker or {}
_G.LootTracker = LT

local SESSION_REENTRY_SECONDS     = 1800
local TRASH_BOSS_NAME             = "Trash"

local TRADE_WINDOW_SECONDS        = 7200   -- WotLK 3.3.5 BoP trade window
local TRADE_TIMER_TICK_SECONDS    = 1      -- per-second panel refresh + real-time expiry cleanup
-- Thresholds (seconds remaining) at which a chat alert is emitted.
-- Order matters: higher thresholds fire first as time ticks down.
local TRADE_ALERT_THRESHOLDS = {
    { key = "30m",     atOrBelow = 1800, label = "30m left to trade" },
    { key = "10m",     atOrBelow =  600, label = "10m left to trade" },
    { key = "1m",      atOrBelow =   60, label = "1m left to trade"  },
    { key = "expired", atOrBelow =    0, label = "trade window expired" },
}

LT.classCache       = {}
LT.currentSession   = nil
LT.activeGroupRolls   = {}  -- [rollID] = { session, bossIndex, itemIndex, itemId, itemLink, startedAt, expiresAt }
LT.manualRoll         = nil  -- master-loot: { itemId, itemLink, expiresAt } — item currently being /roll'd on
LT.resetInstanceNames = {}  -- [instanceName:lower()] = true; consumed on the next entry into that instance
LT.listeners          = {}

local GROUP_ROLL_GRACE_SECONDS = 30  -- keep rollID entries around this long after CANCEL for late chat
-- Master-loot manual rolls: how long an /rw-announced item collects /roll
-- results before the window expires (a fresh announcement also supersedes it).
local MANUAL_ROLL_WINDOW_SECONDS = 120

-- ---------------------------------------------------------------------------
-- AtlasLoot source data (formerly AtlasLootSource.lua)
-- ---------------------------------------------------------------------------
-- Boss loot tables are read live from the AtlasLoot addon via the shipped
-- npcId->key bridge (Data/NPCBridge.lua). Kept inside Core.lua (not a separate
-- file) so these methods always load on /reload: a newly-added .toc file only
-- loads at the login screen, which previously left GetInstanceBosses/etc. nil.

-- The AtlasLoot LoadOnDemand data modules we force-load to populate AtlasLoot_Data.
local ATLASLOOT_DATA_MODULES = {
    "AtlasLoot_OriginalWoW",
    "AtlasLoot_BurningCrusade",
    "AtlasLoot_WrathoftheLichKing",
    "AtlasLoot_WorldEvents",   -- instance holiday bosses (Ahune, Coren Direbrew, Headless Horseman)
}

local atlasLootReady = false   -- AtlasLoot core present AND data modules loaded
local alertedMissing = false

-- True when AtlasLoot core is installed (its boss-name table exists). This loads
-- at AtlasLoot startup, independent of the LoadOnDemand data modules.
local function atlasLootCorePresent()
    return _G.AtlasLoot_TableNames ~= nil
end

-- Force-load the LoadOnDemand AtlasLoot data modules so AtlasLoot_Data is filled.
-- Idempotent; LoadAddOn is a no-op for an already-loaded addon. Returns true if
-- AtlasLoot_Data ended up populated, false (with a one-time alert) if AtlasLoot
-- isn't installed.
function LT:EnsureAtlasLootLoaded()
    if atlasLootReady then return true end
    if not atlasLootCorePresent() then
        if not alertedMissing then
            alertedMissing = true
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4040LootTracker|r: AtlasLoot not "
                .. "detected. Boss-drop attribution is disabled - drops will be "
                .. "tracked under kills only. Install/enable AtlasLoot for accurate "
                .. "per-boss attribution.")
        end
        return false
    end
    if LoadAddOn then
        for _, name in ipairs(ATLASLOOT_DATA_MODULES) do
            LoadAddOn(name)
        end
    end
    atlasLootReady = (_G.AtlasLoot_Data ~= nil)
    return atlasLootReady
end

-- True if AtlasLoot is usable for attribution right now.
function LT:HasAtlasLoot()
    return self:EnsureAtlasLootLoaded()
end

-- npcId -> { itemId = true, ... } from the boss's AtlasLoot loot table. Cached
-- per npcId ONLY once AtlasLoot's data is loaded; when it isn't loaded yet we
-- return an UNcached {} so the lookup heals automatically when AtlasLoot's
-- LoadOnDemand data arrives (caching the empty set would poison the npcId for
-- the whole session and silently degrade every drop to Trash). Never nil.
local lootSetCache = {}
function LT:GetBossLootSet(npcId)
    if not npcId then return {} end
    local cached = lootSetCache[npcId]
    if cached then return cached end
    local entry = _G.LootTracker_NPCBridge and _G.LootTracker_NPCBridge[npcId]
    if not entry then return {} end
    if entry.items then
        -- Explicit item list (the handful of bosses whose AtlasLoot loot sits
        -- behind a localization-token header or header-less in a dedicated key,
        -- which the section match below can't isolate). Independent of AtlasLoot.
        local set = {}
        for _, id in ipairs(entry.items) do set[id] = true end
        lootSetCache[npcId] = set
        return set
    end
    if not self:EnsureAtlasLootLoaded() then return {} end  -- NOT cached: heals when AtlasLoot loads
    local set = {}
    -- Per-boss WotLK keys ship a single `key` whose whole table IS that boss's
    -- loot. The low-dungeon supplement ships a `keys` LIST (a classic dungeon's
    -- loot is split across AtlasLoot wing-tables, "TheDeadmines1"/"TheDeadmines2")
    -- PLUS a `boss` header name. Those wing-tables interleave every boss's loot
    -- under "=q6=<boss name>" header rows (id field == 0), so we restrict the set
    -- to THIS boss's section — keeping attribution CONFIDENT per boss instead of
    -- uncertain over the whole dungeon (every boss otherwise shares one union set
    -- and any multi-boss clear marks every drop "(?)"). A boss whose name matches
    -- no header (a green-only boss with no loot section, or a localization-token
    -- header) yields an empty set — safe: its drops route to Trash as before.
    local keys = entry.keys or { entry.key }
    local bossName = entry.boss
    for _, key in ipairs(keys) do
        local rows = _G.AtlasLoot_Data and _G.AtlasLoot_Data[key]
        if rows then
            local inSection = (bossName == nil)   -- whole table when no boss filter
            for _, row in ipairs(rows) do
                local id = row[2]
                if id == 0 then
                    -- Boss-header row: enter the section only while it names THIS
                    -- boss. WotLK single-key entries have no `boss` and take all.
                    if bossName then
                        local hdr = row[4]
                        if type(hdr) == "string" then
                            inSection = (hdr:gsub("=q%d+=", "") == bossName)
                        else
                            inSection = false
                        end
                    end
                elseif inSection and type(id) == "number" and id > 0 then
                    set[id] = true   -- numbers only (skip "sNNNN" spellIDs / id 0)
                end
            end
        end
    end
    lootSetCache[npcId] = set   -- cache only now that AtlasLoot is loaded
    return set
end

-- npcId -> { key, instance, name }. name prefers AtlasLoot's boss display name;
-- callers may override with the live kill's creature name.
function LT:GetBossInfo(npcId)
    local entry = _G.LootTracker_NPCBridge and _G.LootTracker_NPCBridge[npcId]
    if not entry then return nil end
    local key = entry.key or (entry.keys and entry.keys[1])  -- supplement uses a key list
    local name
    local tn = key and _G.AtlasLoot_TableNames and _G.AtlasLoot_TableNames[key]
    if tn then name = tn[1] end
    return { key = key, instance = entry.instance, name = name }
end

-- List of npcIds whose bridge instance matches `instanceName`. Built lazily and
-- cached per instance name. Used to find "all possible sources of this item in
-- this instance" for the inference branch of ResolveItemSource.
local instanceBossCache = {}
function LT:GetInstanceBosses(instanceName)
    if not instanceName then return {} end
    local cached = instanceBossCache[instanceName]
    if cached then return cached end
    local list = {}
    instanceBossCache[instanceName] = list
    if _G.LootTracker_NPCBridge then
        for npcId, entry in pairs(_G.LootTracker_NPCBridge) do
            if entry.instance == instanceName then
                list[#list + 1] = npcId
            end
        end
    end
    return list
end

-- Forward declaration: FindGroupRollContext is defined later (in the group-loot
-- section) but is also called by OnLootReceived (defined earlier in the file).
-- Without this, the local would not yet exist at OnLootReceived's definition
-- and the closure would bind to a global nil instead.
local FindGroupRollContext

-- Single source of truth for "wipe everything tied to the current run." Four
-- sites need this (zone exit, zone re-enter into new session, DeleteSession
-- of the current one, Reset) and previously each site enumerated the fields
-- inline — easy to forget one when a new field is added (as happened when
-- activeGroupRolls was introduced).
local function ClearTransientState(self)
    self.activeGroupRolls = {}
    self.manualRoll       = nil
end

-- WoW link color hex -> item quality
local QUALITY_FROM_COLOR = {
    ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2,
    ["0070dd"] = 3, ["a335ee"] = 4, ["ff8000"] = 5, ["e6cc80"] = 7,
}

-- Locale-safe pattern building: turns "%s rolls %d (%d-%d)" into a Lua pattern.
local function BuildPattern(fmt)
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%s", "(.+)")
    p = p:gsub("%%%%d", "(%%d+)")
    return "^" .. p .. "$"
end

-- Like BuildPattern but UNanchored and number-only: turns a coin format
-- ("%d Gold" / GOLD_AMOUNT) into "(%d+) Gold" so the denomination's count can
-- be pulled out of a larger CHAT_MSG_MONEY line ("You loot 1 Gold, 2 Silver,
-- 3 Copper"). No ^/$ anchors because the token sits mid-string.
local function BuildAmountPattern(fmt)
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%d", "(%%d+)")
    return p
end

local LOOT_SELF_SINGLE   = BuildPattern(LOOT_ITEM_SELF           or "You receive loot: %s.")
local LOOT_SELF_MULTI    = BuildPattern(LOOT_ITEM_SELF_MULTIPLE  or "You receive loot: %sx%d.")
local LOOT_OTHER_SINGLE  = BuildPattern(LOOT_ITEM                or "%s receives loot: %s.")
local LOOT_OTHER_MULTI   = BuildPattern(LOOT_ITEM_MULTIPLE       or "%s receives loot: %sx%d.")
-- Items PUSHED to you rather than looted: the random-dungeon completion-bonus
-- emblems, quest rewards, mail, crafting. Same "You receive ..." shape but "item"
-- not "loot", so the patterns above miss them ("You receive item: [Emblem]x2.").
-- ParseLoot tags these `pushed` so OnLootReceived records currencies/materials and
-- never boss-attributes them.
local LOOT_PUSHED_SINGLE = BuildPattern(LOOT_ITEM_PUSHED_SELF          or "You receive item: %s.")
local LOOT_PUSHED_MULTI  = BuildPattern(LOOT_ITEM_PUSHED_SELF_MULTIPLE or "You receive item: %sx%d.")
-- The "rolled N for [Item] [Type]" patterns CANNOT come from BuildPattern of
-- LOOT_ROLL_ROLLED_*: Warmane (and likely other private servers) redefines
-- those globals to the "Detailed Loot Information" format ("Type Roll - N for
-- [Item] by Player"), which has a different capture order — %d before %s.
-- BuildPattern would generate a pattern that matches, but capture positions
-- would not match the (name, value, link) assumption downstream, returning
-- garbage (name=N, value=nil, link=playerName). Hardcoded standard-format
-- patterns here; the detailed-format variant is handled explicitly in step 2
-- of ParseGroupLootRoll.
local GROUP_ROLL_NEED    = "^(.-) rolled (%d+) for (.+) %[Need%]$"
local GROUP_ROLL_GREED   = "^(.-) rolled (%d+) for (.+) %[Greed%]$"
local GROUP_ROLL_DE      = "^(.-) rolled (%d+) for (.+) %[Disenchant%]$"
local GROUP_PASS         = BuildPattern(LOOT_ROLL_PASSED         or "%s passed on: %s")
local GROUP_PASS_AUTO    = BuildPattern(LOOT_ROLL_PASSED_AUTO    or "%s automatically passed on: %s because they cannot loot that item")
-- The trailing period in the *_WON fallbacks is intentional: WoW 3.3.5a enUS
-- globals are "You won: %s." and "%s won: %s." (period). Omitting it would
-- cause BuildPattern's $ anchor to reject real messages when the global is
-- ever clobbered (Warmane modifications, locale swap, etc.). LOOT_ROLL_ALL_PASSED
-- has no period in the real string.
local WON_SELF           = BuildPattern(LOOT_ROLL_YOU_WON        or "You won: %s.")
local WON_OTHER          = BuildPattern(LOOT_ROLL_WON            or "%s won: %s.")
local WON_NOBODY         = BuildPattern(LOOT_ROLL_ALL_PASSED     or "Everyone passed on: %s")
local INSTANCE_RESET     = BuildPattern(INSTANCE_RESET_SUCCESS   or "%s has been reset.")
-- Master-loot manual rolls: the loot master raid-warns an item, players /roll,
-- and the server broadcasts RANDOM_ROLL_RESULT ("%s rolls %d (%d-%d)") via
-- CHAT_MSG_SYSTEM. Unlike the group-loot roll messages above, this carries NO
-- item link — the roll is anchored to the most recently announced item (see
-- OnManualRollAnnounce). Captures: (name, value, minRoll, maxRoll).
local RANDOM_ROLL        = BuildPattern(RANDOM_ROLL_RESULT       or "%s rolls %d (%d-%d)")

-- Coin tokens inside a CHAT_MSG_MONEY line. Derived from the client's own
-- GOLD_AMOUNT/SILVER_AMOUNT/COPPER_AMOUNT so they stay correct if a locale
-- (or server) reorders or relabels them. Matched as substrings of the larger
-- "You loot ..."/"You receive ... as your share." message; any subset may be
-- present (a pure-copper drop carries no Gold/Silver token).
local MONEY_GOLD         = BuildAmountPattern(GOLD_AMOUNT   or "%d Gold")
local MONEY_SILVER       = BuildAmountPattern(SILVER_AMOUNT or "%d Silver")
local MONEY_COPPER       = BuildAmountPattern(COPPER_AMOUNT or "%d Copper")
-- Coin wrappers counted toward the per-session total: solo loot ("You loot
-- <amount>"), the grouped split ("You receive <amount> as your share."), and the
-- dungeon/BG completion reward ("Received <amount>" — which some servers deliver
-- via CHAT_MSG_SYSTEM rather than CHAT_MSG_MONEY). %s is the formatted coin amount,
-- captured for ParseMoney to split into coins.
--
-- Mail, vendor sell-back and quest-turn-in coin use other wrappers and aren't
-- matched. Even if one slipped through, money is session-gated (OnMoneyReceived
-- needs currentSession), so coin received outside an instance is never counted.
local MONEY_LOOT_SELF    = BuildPattern(YOU_LOOT_MONEY   or "You loot %s")
local MONEY_LOOT_SHARE   = BuildPattern(LOOT_MONEY_SPLIT or "You receive %s as your share.")
local MONEY_REWARD       = BuildPattern("Received %s")   -- random-dungeon / BG completion coin reward

local ITEM_LINK_FULL    = "(|c%x+|Hitem:%d+:.-|h%[.-%]|h|r)"

-- Normalize the "type" word that appears in chat-message variants. Keys are
-- lowercase so the lookup site (which lowercases its input) handles any
-- casing the server emits. "de" is a common shorthand for disenchant in
-- the "<Type> Roll - N" format.
local CANONICAL_ROLL_TYPE = {
    need       = "Need",
    greed      = "Greed",
    disenchant = "Disenchant",
    de         = "Disenchant",
}

-- ---------------------------------------------------------------------------
-- Listeners
-- ---------------------------------------------------------------------------

function LT:On(event, fn)
    self.listeners[event] = self.listeners[event] or {}
    table.insert(self.listeners[event], fn)
end

function LT:Fire(event, ...)
    local list = self.listeners[event]
    if not list then return end
    for _, fn in ipairs(list) do fn(...) end
end

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

-- Extract the npcId from a 3.3.5a creature GUID.
--
-- Layout: 0xF13<variable-width high/instance bits><npcId: 6 hex><spawn: 6 hex>.
-- Warmane does NOT zero-pad the high part to a fixed width — instanced (raid /
-- WotLK dungeon) creatures carry extra bits while classic-world creatures do
-- not — so the npcId sits at DIFFERENT string offsets for different kills. A
-- fixed offset (the old `^0x[fF]13.%x%x%x%x(%x%x%x%x)`) happened to land right
-- for WotLK content but read shifted, wrong ids for classic content (it returned
-- 13824 for Ragefire Trogg, whose real id is 11318; 64768 for Oggleflint vs the
-- real 11517). A wrong id never matches the bridge, so those kills' drops fall to
-- Trash. Anchor on the RIGHT instead: the npcId is the 6 hex digits immediately
-- before the 6-hex spawn counter, regardless of how wide the high part is.
--
-- The 6-hex widths are the STABLE part of the layout: a 3.3.5a creature GUID's
-- low 24 bits are the spawn counter and the next 24 are the entry/npcId, so both
-- fields are exactly 6 hex. (Only the high type/instance bits vary in width.) A
-- wrong extraction still fails SAFE — an unmatched id routes to Trash, never a
-- wrong boss.
local function GetNPCID(guid)
    if not guid or not guid:match("^0x[fF]13") then return nil end
    local entry = guid:match("(%x%x%x%x%x%x)%x%x%x%x%x%x$")
    return entry and tonumber(entry, 16) or nil
end

local function StripRealm(name)
    if not name then return nil end
    return (name:gsub("%-.*$", ""))
end

local function Now() return time() end

local function GetItemIDFromLink(link)
    return tonumber(link and link:match("|Hitem:(%d+):"))
end

local function GetItemQualityFromLink(link)
    local color = link and link:match("|cff(%x%x%x%x%x%x)")
    return color and QUALITY_FROM_COLOR[color:lower()]
end

-- Bind-on-Equip detection. WotLK 3.3.5's GetItemInfo returns no bind field, so
-- bind type is read by scanning a hidden tooltip for the localized
-- ITEM_BIND_ON_EQUIP line. The result is cached per itemId forever (an item's
-- bind type is immutable). Returns true (BoE) / false (not BoE) / nil (the item
-- isn't in the client cache yet — the caller should retry on a later render;
-- the UI's icon ticker re-renders when an item's info lands, which heals both
-- the BoE badge and the trade-window BoE filter automatically).
local boeCache = {}
local boeScanner
function LT:GetItemBoE(itemId)
    if not itemId then return nil end
    local cached = boeCache[itemId]
    if cached ~= nil then return cached end
    -- GetItemInfo is non-nil only once the item's static data (including bind
    -- type) is cached. Until then the tooltip scan would see an incomplete
    -- tooltip and wrongly report "not BoE"; gate on it and heal later.
    if not GetItemInfo(itemId) then return nil end
    if not boeScanner then
        boeScanner = CreateFrame("GameTooltip", "LootTrackerBoEScanner", nil, "GameTooltipTemplate")
        boeScanner:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    boeScanner:ClearLines()
    boeScanner:SetHyperlink("item:" .. itemId)
    local boe = false
    -- The bind line sits near the top of the tooltip (line 2-5). Stop at the
    -- first bind marker found; absence of any marker means non-binding (false).
    local n = math.min(boeScanner:NumLines() or 0, 5)
    for i = 2, n do
        local fs = _G["LootTrackerBoEScannerTextLeft" .. i]
        local text = fs and fs:GetText()
        if text == ITEM_BIND_ON_EQUIP then
            boe = true
            break
        elseif text == ITEM_BIND_ON_PICKUP or text == ITEM_BIND_ON_USE
            or text == ITEM_BIND_QUEST or text == ITEM_SOULBOUND then
            break
        end
    end
    boeCache[itemId] = boe
    return boe
end

-- True when this loot recipient is the local player. ParseLoot sets recipient
-- to UnitName("player") verbatim for "You receive loot:" lines, so this compares
-- that value to itself — exact, and free of realm-suffix concerns (3.3.5 returns
-- the bare name). Distinguishes personal loot from group members' loot.
local function IsLocalPlayer(recipient)
    return recipient == UnitName("player")
end

local function FindItemInBoss(boss, itemId)
    for i, item in ipairs(boss.items) do
        if item.itemId == itemId then return i, item end
    end
end

-- An item entry may already exist as a placeholder created by OnGroupLootRoll
-- when players rolled before the winner received it. Those placeholders carry
-- rolls but no recipient. FindItemPlaceholder locates such an entry so the first
-- actual receive fills its recipient instead of spawning a duplicate row. A true
-- re-drop (every matching entry already has a recipient) returns nil.
local function FindItemPlaceholder(boss, itemId)
    for _, item in ipairs(boss.items) do
        if item.itemId == itemId and not item.recipient then return item end
    end
end

-- Attribute one received copy to `boss`. Per-copy model: fill a waiting
-- placeholder if one exists, otherwise ALWAYS create a fresh entry — a true
-- re-drop of the same item is never merged into a count. Each physical copy
-- keeps its own droppedAt (trade-window deadline) and rolls list, matching what
-- OnStartLootRoll already does for group loot. Returns the entry.
local function ClaimOrCreateItem(boss, itemId, itemLink, recipient, count, quality)
    local existing = FindItemPlaceholder(boss, itemId)
    if existing then
        existing.recipient = recipient
        existing.count     = count or existing.count or 1
        if itemLink and not existing.itemLink then existing.itemLink = itemLink end
        if quality  and not existing.quality  then existing.quality  = quality  end
        return existing
    end
    existing = {
        itemId    = itemId,
        itemLink  = itemLink,
        recipient = recipient,
        count     = count or 1,
        quality   = quality,
        droppedAt = Now(),
        rolls     = {},
    }
    table.insert(boss.items, existing)
    return existing
end

local function FindBossByGuid(session, guid)
    if not session or not guid then return end
    for i, boss in ipairs(session.bosses) do
        if boss.guid == guid then return i, boss end
    end
end

local EQUIP_SLOT_MAP = {
    INVTYPE_HEAD           = { 1 },
    INVTYPE_NECK           = { 2 },
    INVTYPE_SHOULDER       = { 3 },
    INVTYPE_BODY           = { 4 },
    INVTYPE_CHEST          = { 5 },
    INVTYPE_ROBE           = { 5 },
    INVTYPE_WAIST          = { 6 },
    INVTYPE_LEGS           = { 7 },
    INVTYPE_FEET           = { 8 },
    INVTYPE_WRIST          = { 9 },
    INVTYPE_HAND           = { 10 },
    INVTYPE_FINGER         = { 11, 12 },
    INVTYPE_TRINKET        = { 13, 14 },
    INVTYPE_CLOAK          = { 15 },
    INVTYPE_WEAPON         = { 16, 17 },
    INVTYPE_2HWEAPON       = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND  = { 17 },
    INVTYPE_HOLDABLE       = { 17 },
    INVTYPE_SHIELD         = { 17 },
    INVTYPE_RANGED         = { 18 },
    INVTYPE_RANGEDRIGHT    = { 18 },
    INVTYPE_THROWN         = { 18 },
    INVTYPE_RELIC          = { 18 },
    INVTYPE_TABARD         = { 19 },
}

local function FindUnitByName(name)
    if not name then return end
    if UnitName("player") == name then return "player" end
    local nR = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    if nR > 0 then
        for i = 1, nR do
            if UnitName("raid" .. i) == name then return "raid" .. i end
        end
        return
    end
    local nP = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    for i = 1, nP do
        if UnitName("party" .. i) == name then return "party" .. i end
    end
end

local function GetEquippedForCompare(playerName, droppedItemLink)
    if not droppedItemLink then return end
    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(droppedItemLink)
    if not equipLoc or equipLoc == "" then return end
    local slots = EQUIP_SLOT_MAP[equipLoc]
    if not slots then return end
    local unit = FindUnitByName(playerName)
    if not unit then return end
    for _, slot in ipairs(slots) do
        local link = GetInventoryItemLink(unit, slot)
        if link then return link end
    end
end

-- Exposed on LT so the UI can lazy-retry at render time. Group/raid member
-- equipped slots aren't always cached when the roll fires (cross-realm names,
-- members who haven't been inspected yet) — caching here at roll time would
-- snapshot a nil. By exposing this, the UI can re-attempt the lookup later
-- when the inspect cache has populated.
function LT:GetEquippedForCompare(playerName, droppedItemLink)
    return GetEquippedForCompare(playerName, droppedItemLink)
end

-- Throttled NotifyInspect queue. WoW only services one inspect at a time
-- (and the global inspect cooldown is ~1.5s in 3.3.5) — calling NotifyInspect
-- aggressively for every roller in a raid would silently fail for most of
-- them. We queue distinct player names, fire them at INSPECT_INTERVAL each,
-- and on INSPECT_TALENT_READY broadcast a refresh so the UI re-queries the
-- equipped slot.
local INSPECT_INTERVAL = 1.6
local inspectQueue, inspectQueued = {}, {}
local inspectTicker

local function ProcessInspectQueue()
    while #inspectQueue > 0 do
        local playerName = table.remove(inspectQueue, 1)
        inspectQueued[playerName] = nil
        if UnitName("player") ~= playerName then
            local unit = FindUnitByName(playerName)
            if unit and UnitIsVisible and UnitIsVisible(unit)
                and CheckInteractDistance and CheckInteractDistance(unit, 1)
            then
                NotifyInspect(unit)
                return  -- one at a time; ticker will reschedule
            end
        end
    end
    if inspectTicker then inspectTicker:Hide() end
end

function LT:RequestInspect(playerName)
    if not playerName then return end
    if UnitName("player") == playerName then return end
    if inspectQueued[playerName] then return end
    inspectQueued[playerName] = true
    table.insert(inspectQueue, playerName)

    if not inspectTicker then
        inspectTicker = CreateFrame("Frame")
        local elapsed = 0
        inspectTicker:SetScript("OnUpdate", function(self, dt)
            elapsed = elapsed + dt
            if elapsed < INSPECT_INTERVAL then return end
            elapsed = 0
            ProcessInspectQueue()
        end)
    end
    inspectTicker:Show()
end

-- ---------------------------------------------------------------------------
-- Class cache (group roster -> class file name)
-- ---------------------------------------------------------------------------

function LT:GetPlayerClass(name)
    if not name then return nil end
    return self.classCache[StripRealm(name)]
end

function LT:RefreshClassCache()
    local cache = self.classCache
    local me = UnitName("player")
    if me then
        local _, fileName = UnitClass("player")
        if fileName then cache[me] = fileName end
    end

    local numRaid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if numRaid > 0 then
        for i = 1, numRaid do
            local n, _, _, _, _, fileName = GetRaidRosterInfo(i)
            if n and fileName then cache[StripRealm(n)] = fileName end
        end
        return
    end

    local numParty = GetNumPartyMembers and GetNumPartyMembers() or 0
    for i = 1, numParty do
        local unit = "party" .. i
        local n = UnitName(unit)
        local _, fileName = UnitClass(unit)
        -- Key by StripRealm(n) to match the raid path above and GetPlayerClass's
        -- lookup, so classCache is uniformly keyed by bare name. UnitName is
        -- already bare on 3.3.5, but this keeps the invariant explicit and safe
        -- if a cross-realm unit (LFD) ever yields a realm-suffixed name.
        if n and fileName then cache[StripRealm(n)] = fileName end
    end
end

-- ---------------------------------------------------------------------------
-- SavedVariables / sessions
-- ---------------------------------------------------------------------------

local DEBUG_LOG_MAX_LINES = 1000  -- ring buffer cap on persisted debug output

local function EnsureDB()
    LootTrackerDB = LootTrackerDB or {}
    LootTrackerDB.sessions          = LootTrackerDB.sessions or {}
    LootTrackerDB.nextSessionId     = LootTrackerDB.nextSessionId or 1
    -- Persisted across /reload and logout: a reset message followed by
    -- alt-F4 then login within the 1800s rejoin window would otherwise
    -- re-trigger the rejoin-old-session bug. The set is self-cleaning —
    -- each entry into an instance consumes its flag.
    LootTrackerDB.resetInstanceNames = LootTrackerDB.resetInstanceNames or {}
    LT.resetInstanceNames = LootTrackerDB.resetInstanceNames
    -- Persisted debug ring buffer. Written when LT.debug is on; flushed
    -- to disk on /reload or logout. Lets the user share the log without
    -- copy-pasting from chat.
    LootTrackerDB.debugLog = LootTrackerDB.debugLog or {}
    LT.debugLog = LootTrackerDB.debugLog
    -- Legacy purge: one-off diagnostics that older builds persisted here (the
    -- /ltdiag AtlasLoot snapshot and the kill-GUID harvest probe). Both are gone;
    -- drop anything a prior build left so it doesn't linger in SavedVariables.
    LootTrackerDB.diag = nil
    LootTrackerDB.killProbe = nil
    LootTrackerDB.tradeTimers = LootTrackerDB.tradeTimers or {}
    if LootTrackerDB.tradeTimers.enabled        == nil then LootTrackerDB.tradeTimers.enabled        = true  end
    if LootTrackerDB.tradeTimers.alerts         == nil then LootTrackerDB.tradeTimers.alerts         = true  end
    if LootTrackerDB.tradeTimers.panelCollapsed == nil then LootTrackerDB.tradeTimers.panelCollapsed = false end
    -- BoE drops have no real soulbound-trade restriction, so some players don't
    -- want them cluttering the trade-window urgency panel. Default ON (show
    -- them); the cog menu toggles it.
    if LootTrackerDB.tradeTimers.showBoE        == nil then LootTrackerDB.tradeTimers.showBoE        = true  end
    -- Minimum item quality for expiration chat announcements (2=Uncommon,
    -- 3=Rare, 4=Epic, 5=Legendary). Items below this tier still appear in the
    -- panel and list; only the chat alerts are suppressed. Default Rare+.
    if LootTrackerDB.tradeTimers.alertMinQuality == nil then LootTrackerDB.tradeTimers.alertMinQuality = 3 end
    -- "Trade window only" focus mode: under the Bosses tab, hide the per-boss
    -- drop list and show only the items with a live trade window, as a flat
    -- expandable list. Default off.
    if LootTrackerDB.tradeTimers.panelOnly == nil then LootTrackerDB.tradeTimers.panelOnly = false end
    -- How a right-click "mark as distributed" item is shown: "check" keeps it
    -- in the Bosses list with a checkmark + "distributed" label; "remove" omits
    -- it from the list. Either way it leaves the Trade Window panel and alerts.
    if LootTrackerDB.distributedMode == nil then LootTrackerDB.distributedMode = "check" end
    -- How duplicate copies of the same item are displayed: "separate" renders
    -- one row per physical copy (each with its own trade timer and rolls);
    -- "combined" collapses same-itemId copies into one "xN" row. Purely a
    -- display choice — storage is always per-copy (see ClaimOrCreateItem).
    if LootTrackerDB.duplicateMode == nil then LootTrackerDB.duplicateMode = "separate" end
    -- Minimap launcher button. `angle` is the position in degrees around the
    -- minimap edge (persisted on drag); `hide` removes the button for users who
    -- launch via /lt or another bar.
    LootTrackerDB.minimap = LootTrackerDB.minimap or {}
    if LootTrackerDB.minimap.hide  == nil then LootTrackerDB.minimap.hide  = false end
    if LootTrackerDB.minimap.angle == nil then LootTrackerDB.minimap.angle = 200   end
end

local function LogDebug(msg)
    if not LT.debug then return end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd200LT|r " .. msg)
    local log = LT.debugLog
    if not log then return end
    log[#log + 1] = date("%H:%M:%S ") .. msg
    while #log > DEBUG_LOG_MAX_LINES do
        table.remove(log, 1)
    end
end

local function NewSession(instanceName, instanceType, difficulty)
    EnsureDB()
    local id = LootTrackerDB.nextSessionId
    LootTrackerDB.nextSessionId = id + 1
    local s = {
        id           = id,
        instanceName = instanceName,
        instanceType = instanceType,
        difficulty   = difficulty,
        startedAt    = Now(),
        endedAt      = nil,
        bosses       = {},
    }
    table.insert(LootTrackerDB.sessions, s)
    return s
end

local function FindRecentMatchingSession(instanceName, difficulty)
    EnsureDB()
    local now = Now()
    for i = #LootTrackerDB.sessions, 1, -1 do
        local s = LootTrackerDB.sessions[i]
        if s.instanceName == instanceName
            and s.difficulty == difficulty
            and now - (s.endedAt or s.startedAt) < SESSION_REENTRY_SECONDS
        then
            return s
        end
    end
end

function LT:OnZoneChanged()
    local inInstance, instanceType = IsInInstance()
    if not inInstance or (instanceType ~= "party" and instanceType ~= "raid") then
        if self.currentSession then
            self.currentSession.endedAt = Now()
            self.currentSession = nil
            ClearTransientState(self)
            self:Fire("SessionChanged")
        end
        return
    end

    local instanceName, _, difficultyIndex, difficultyName = GetInstanceInfo()
    -- 3.3.5 GetInstanceInfo() returns a useful difficultyName for raids
    -- ("10 Player", "25 Player (Heroic)", ...) but an empty string for 5-mans.
    -- For 5-mans, difficultyIndex is 1 = Normal, 2 = Heroic.
    if instanceType == "party" then
        difficultyName = (difficultyIndex == 2) and "Heroic" or "Normal"
    elseif not difficultyName or difficultyName == "" then
        difficultyName = "Difficulty " .. tostring(difficultyIndex or "?")
    end

    -- An instance reset between exit and re-entry means the game world is
    -- fresh — bosses respawned, lockout gone. Treat this as a hard session
    -- boundary even when name+difficulty match a recent session. The flag
    -- is set from the INSTANCE_RESET_SUCCESS system message and consumed
    -- here (single-shot per reset → re-entry).
    local resetKey = instanceName and instanceName:lower()
    local wasReset = resetKey and self.resetInstanceNames[resetKey]
    if wasReset then self.resetInstanceNames[resetKey] = nil end

    -- Sub-zone transition inside the same active session: preserve all state.
    -- Skipped after a reset — the player walked through the entrance fresh,
    -- so even an unchanged name+difficulty should start a new session.
    if not wasReset
        and self.currentSession
        and self.currentSession.instanceName == instanceName
        and self.currentSession.difficulty == difficultyName
    then
        self.currentSession.endedAt = nil
        return
    end

    if self.currentSession then
        self.currentSession.endedAt = Now()
    end

    local existing = (not wasReset) and FindRecentMatchingSession(instanceName, difficultyName)
    if existing then
        existing.endedAt = nil
        self.currentSession = existing
    else
        self.currentSession = NewSession(instanceName, instanceType, difficultyName)
    end
    ClearTransientState(self)
    self:Fire("SessionChanged")
end

-- ---------------------------------------------------------------------------
-- Boss-kill registration + data-determined attribution
-- ---------------------------------------------------------------------------

-- Register (or return) the boss entry for this npcId in the current session.
-- name: prefer the live kill's creature name; fall back to AtlasLoot's name.
-- Dedups by npcId within the session; refreshes recency (killedAt) on a repeat.
function LT:RegisterBossKill(npcId, name, guid, killTime)
    local session = self.currentSession
    if not session then return nil end
    for _, b in ipairs(session.bosses) do
        if b.npcId == npcId then
            b.killedAt = killTime or b.killedAt or Now()  -- refresh recency
            return b
        end
    end
    if not name then
        local info = self:GetBossInfo(npcId)
        name = info and info.name or "Unknown"
    end
    local entry = {
        npcId = npcId, name = name, guid = guid,
        killedAt = killTime or Now(), items = {},
    }
    table.insert(session.bosses, entry)
    self:Fire("BossKilled", session, entry)
    return entry
end

-- Returns the most-recently-killed boss among a list (highest killedAt).
local function mostRecent(bosses)
    local best
    for _, b in ipairs(bosses) do
        if not best or (b.killedAt or 0) > (best.killedAt or 0) then best = b end
    end
    return best
end

-- PURE attribution rule. No WoW API calls — everything comes from ctx, so this
-- is unit-tested by /lttest. Returns one of:
--   { kind = "boss",      npcId = N }                 -- confident
--   { kind = "boss",      npcId = N, uncertain = true } -- best-effort, flagged
--   { kind = "uncertain" }                            -- can't responsibly pick
--   { kind = "trash" }                                -- not boss loot in this instance
--
-- The `uncertain` flag is computed and persisted but no longer RENDERED (the UI
-- "(?)" marker was removed by user request). It is intentionally retained — it is
-- the rule's honest output and re-surfacing it later needs no data migration — so
-- don't "clean up" the now-undisplayed field.
--
-- ctx fields:
--   killedBosses : array of { npcId, killedAt } registered (killed) this session
--   instanceBosses : array of npcId — every bridge boss in the current instance
--   hasLoot(npcId, itemId) -> boolean — itemId in that boss's AtlasLoot loot set
-- itemId is assumed already classified as rare+ gear (currencies/materials/sub-rare
-- handled by the caller before this point).
function LT.ResolveItemSource(itemId, ctx)
    -- 1. Bosses we actually killed that can drop this item.
    local killed = {}
    for _, b in ipairs(ctx.killedBosses) do
        if ctx.hasLoot(b.npcId, itemId) then killed[#killed + 1] = b end
    end
    if #killed == 1 then
        return { kind = "boss", npcId = killed[1].npcId }            -- deterministic
    elseif #killed > 1 then
        -- Shared item, several of its bosses killed: anchor to the most recent
        -- kill (you loot right after killing) but flag uncertain — never a
        -- silent wrong pick.
        return { kind = "boss", npcId = mostRecent(killed).npcId, uncertain = true }
    end
    -- 2. None of the killed bosses drop it. Infer from the instance's bridge:
    --    if exactly one boss in THIS instance can drop it, the item itself proves
    --    the source even if we missed the kill.
    local possible = {}
    for _, npcId in ipairs(ctx.instanceBosses) do
        if ctx.hasLoot(npcId, itemId) then possible[#possible + 1] = npcId end
    end
    if #possible == 1 then
        return { kind = "boss", npcId = possible[1] }               -- deterministic by elimination
    elseif #possible > 1 then
        return { kind = "uncertain" }                               -- several possible, none killed
    end
    -- 3. Not in any bridge boss's loot for this instance.
    return { kind = "trash" }
end

-- In-game self-test for the pure attribution rule. Invoked by /lttest (wired in
-- the slash section near the end of this file). Builds ctx literals — no game
-- state needed — and asserts each branch of ResolveItemSource.
function LT:RunSelfTest()
    local fails = 0
    local function check(label, cond)
        if cond then
            DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40PASS|r " .. label)
        else
            fails = fails + 1
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4040FAIL|r " .. label)
        end
    end
    local function ctx(killed, instanceBosses, lootMap)
        return {
            killedBosses = killed,
            instanceBosses = instanceBosses,
            hasLoot = function(npcId, itemId)
                local s = lootMap[npcId]; return s and s[itemId] or false
            end,
        }
    end
    -- unique killed boss -> confident boss
    local r = LT.ResolveItemSource(100, ctx(
        {{npcId=1, killedAt=10}}, {1, 2}, {[1]={[100]=true}, [2]={}}))
    check("unique killed -> boss 1", r.kind=="boss" and r.npcId==1 and not r.uncertain)
    -- two killed bosses share item -> most recent, uncertain
    r = LT.ResolveItemSource(100, ctx(
        {{npcId=1, killedAt=10}, {npcId=2, killedAt=20}}, {1,2},
        {[1]={[100]=true}, [2]={[100]=true}}))
    check("two killed share -> most recent + uncertain",
        r.kind=="boss" and r.npcId==2 and r.uncertain==true)
    -- none killed, one possible in instance -> infer boss
    r = LT.ResolveItemSource(100, ctx(
        {}, {1, 2}, {[1]={[100]=true}, [2]={}}))
    check("none killed, one possible -> inferred boss 1", r.kind=="boss" and r.npcId==1)
    -- none killed, several possible -> uncertain
    r = LT.ResolveItemSource(100, ctx(
        {}, {1, 2}, {[1]={[100]=true}, [2]={[100]=true}}))
    check("none killed, several possible -> uncertain", r.kind=="uncertain")
    -- not in any instance boss loot -> trash
    r = LT.ResolveItemSource(999, ctx(
        {{npcId=1, killedAt=10}}, {1, 2}, {[1]={[100]=true}, [2]={}}))
    check("unknown item -> trash", r.kind=="trash")
    -- Trash entry (npcId=nil) in killedBosses is ignored, not matched. In
    -- production the npcId=nil guard lives in BuildAttributionCtx.hasLoot (the
    -- Trash boss has no loot set); the test's hasLoot mirrors it via
    -- lootMap[nil] == nil. The real boss 2 must still be picked.
    r = LT.ResolveItemSource(100, ctx(
        {{npcId=nil, killedAt=30}, {npcId=2, killedAt=20}}, {1, 2},
        {[2]={[100]=true}}))
    check("nil-npcId trash entry ignored -> boss 2",
        r.kind=="boss" and r.npcId==2 and not r.uncertain)
    DEFAULT_CHAT_FRAME:AddMessage(fails==0
        and "|cff40ff40LootTracker self-test: ALL PASS|r"
        or  ("|cffff4040LootTracker self-test: " .. fails .. " FAILED|r"))
end

-- ---------------------------------------------------------------------------
-- Trash entry + item classification
-- ---------------------------------------------------------------------------

-- Lazily create (or return) the single per-session "Trash" entry. All
-- uncertain / non-boss sources in a session route here, regardless of drop
-- quality. The sentinel guid encodes the session id so a stale Trash entry
-- from a previous session can't be matched accidentally by FindBossByGuid.
local function GetOrCreateTrashBoss(session)
    if not session then return nil end
    local guid = "trash:" .. tostring(session.id)
    local _, existing = FindBossByGuid(session, guid)
    if existing then return existing end
    local entry = {
        npcId    = nil,
        name     = TRASH_BOSS_NAME,
        guid     = guid,
        killedAt = Now(),
        items    = {},
    }
    table.insert(session.bosses, entry)
    return entry
end

-- Item-class classification. Materials = any item whose itemType is
-- "Trade Goods" — the WoW category that covers cloth, leather, metal/ore,
-- herbs, raw gems, elementals, parts, and enchanting mats (dust/essence/
-- shard/crystal) across all expansions without a hardcoded list. "Trade
-- Goods" is the enUS itemType string, consistent with this addon's
-- assumption of an enUS client (see the "Enchanting"-era note in git
-- history). Returns false on cold cache (GetItemInfo nil); the caller
-- routes uncategorised items normally.
local function IsMaterial(itemLink)
    if not itemLink then return false end
    local _, _, _, _, _, itemType = GetItemInfo(itemLink)
    return itemType == "Trade Goods"
end

local function IsCurrency(itemId)
    if not (itemId and LootTracker_Currencies) then return false end
    return LootTracker_Currencies[itemId] == 1
end

-- Per-session aggregate write for currencies/materials. Both tables share
-- the same shape so one helper covers both.
local function RecordAggregate(bucket, itemId, itemLink, recipient, count)
    bucket[itemId] = bucket[itemId] or {
        itemLink   = itemLink,
        count      = 0,
        recipients = {},
    }
    local entry = bucket[itemId]
    entry.count = entry.count + (count or 1)
    if recipient then
        entry.recipients[recipient] = (entry.recipients[recipient] or 0) + (count or 1)
    end
    return entry
end

local function RecordCurrency(session, itemId, itemLink, recipient, count)
    session.currencies = session.currencies or {}
    return RecordAggregate(session.currencies, itemId, itemLink, recipient, count)
end

local function RecordMaterial(session, itemId, itemLink, recipient, count)
    session.materials = session.materials or {}
    return RecordAggregate(session.materials, itemId, itemLink, recipient, count)
end

-- ---------------------------------------------------------------------------
-- Loot received
-- ---------------------------------------------------------------------------

-- Synthesize a 100-Need roll for the recipient when no real rolls reached
-- the item. Three scenarios:
--   1. Solo play: no group, no rolls — every drop would otherwise render
--      as "no rolls yet".
--   2. Master loot: the loot master assigns directly, no rolls in chat.
--      The recipient is the de-facto winner.
--   3. Group-loot auto-distribution (Wintergrasp / Vault of Archavon /
--      class-restricted PvP gear): only one player is eligible based on
--      class/spec, the server skips START_LOOT_ROLL entirely and just
--      delivers the item. Logs show "X receives loot" with no preceding
--      roll or won messages. Gated to recipient == local player so non-
--      looter clients don't fabricate rolls for items they have no
--      visibility into (e.g. cross-class rolls they weren't eligible for).
--
-- If any real rolls already populated item.rolls, we leave them alone —
-- the synthetic only fires for genuinely roll-less drops.
local function MaybeAddSyntheticRoll(self, item, recipient)
    if not recipient then return end
    item.rolls = item.rolls or {}
    if #item.rolls > 0 then return end

    local isMasterLoot = GetLootMethod and GetLootMethod() == "master"
    if not isMasterLoot then
        -- Non-master gate: recipient must be the local player. This covers
        -- solo (always passes) and group-loot auto-distribution where the
        -- player got an item with no rolls fired. Skips the case where a
        -- non-looter sees "X receives loot" for items they weren't eligible
        -- for — those genuinely had no roll messages broadcast to this
        -- client, but the rolls did happen; faking 100 Need would be wrong.
        if not IsLocalPlayer(recipient) then return end
    end

    item.rolledBy = item.rolledBy or {}
    if item.rolledBy[recipient] then return end
    item.rolledBy[recipient] = true
    table.insert(item.rolls, {
        player       = recipient,
        class        = self:GetPlayerClass(recipient),
        value        = 100,
        minRoll      = 1,
        maxRoll      = 100,
        rollType     = "Need",
        time         = Now(),
        equippedLink = GetEquippedForCompare(recipient, item.itemLink),
    })
end

-- The bridge groups bosses by AtlasLoot's instance name, which can diverge from
-- GetInstanceInfo()'s name ("Battle for Mount Hyjal" vs "Hyjal Summit",
-- "Tempest Keep" vs "The Eye", world bosses, ...). The inference branch needs the
-- bridge's OWN name for the current instance. Any boss we actually killed this
-- session pins it deterministically (npcId -> bridge entry -> instance); only when
-- no bridged boss has been killed do we fall back to GetInstanceInfo's name.
-- Invariant: every bridged boss in a session shares one instance (one physical
-- instance => one bridge instance, per the npcId pinning), so the first match wins.
local function CurrentBridgeInstance(session)
    local bridge = _G.LootTracker_NPCBridge
    if bridge then
        for _, b in ipairs(session.bosses) do
            local entry = b.npcId and bridge[b.npcId]
            if entry then return entry.instance end
        end
    end
    return session.instanceName
end

-- Build the ResolveItemSource ctx from current session/kill state.
local function BuildAttributionCtx(self)
    local session = self.currentSession
    return {
        killedBosses = session.bosses,   -- each has npcId + killedAt; Trash entries have npcId=nil and are skipped by hasLoot
        instanceBosses = self:GetInstanceBosses(CurrentBridgeInstance(session)),
        hasLoot = function(npcId, itemId)
            if not npcId then return false end
            return self:GetBossLootSet(npcId)[itemId] == true
        end,
    }
end

-- Resolve an item to a boss entry (creating/registering as needed) or the Trash
-- entry, honoring the ResolveItemSource decision. Returns (bossEntry, uncertain).
local function ResolveLootTarget(self, itemId)
    local session = self.currentSession
    local decision = LT.ResolveItemSource(itemId, BuildAttributionCtx(self))
    if decision.kind == "boss" then
        -- Find the already-registered boss, or register it (inferred source we
        -- never saw die). Name from AtlasLoot since there was no kill event.
        for _, b in ipairs(session.bosses) do
            if b.npcId == decision.npcId then return b, decision.uncertain end
        end
        local info = self:GetBossInfo(decision.npcId)
        local b = self:RegisterBossKill(decision.npcId, info and info.name, nil, Now())
        return b, decision.uncertain
    elseif decision.kind == "uncertain" then
        return GetOrCreateTrashBoss(session), true   -- flagged, routed to Trash
    else
        return GetOrCreateTrashBoss(session), false  -- trash
    end
end

-- Minimal one-shot timer: invoke fn() once after `delay` seconds. WoW frames are
-- never garbage-collected, so we keep a SINGLE shared frame plus a pending list
-- instead of creating a frame per call. Sub-second accurate (driven by OnUpdate
-- dt, not the 1s-resolution wall clock). Due callbacks fire AFTER the scan so a
-- callback that re-arms via After() can't corrupt the in-progress iteration.
local afterFrame
local afterQueue = {}
local function After(delay, fn)
    afterQueue[#afterQueue + 1] = { remaining = delay, fn = fn }
    if not afterFrame then
        afterFrame = CreateFrame("Frame")
        -- Script is set ONCE here (not per call). When the queue drains the frame
        -- is Hidden, which pauses OnUpdate; the Show() below re-arms it.
        afterFrame:SetScript("OnUpdate", function(frame, dt)
            local due
            local i = 1
            while i <= #afterQueue do
                local e = afterQueue[i]
                e.remaining = e.remaining - dt
                if e.remaining <= 0 then
                    table.remove(afterQueue, i)
                    due = due or {}
                    due[#due + 1] = e.fn
                else
                    i = i + 1
                end
            end
            if #afterQueue == 0 then frame:Hide() end
            -- Fire due callbacks AFTER the scan so a callback that re-arms via
            -- After() (re-Show + append) can't corrupt the in-progress iteration.
            if due then for _, f in ipairs(due) do f() end end
        end)
    end
    afterFrame:Show()
end

-- A cold item cache (GetItemInfo returns nil for a never-seen item) makes
-- IsMaterial misread the item's type, so crafting mats like Frozen Orb land
-- under a boss instead of the Materials tab. 3.3.5 has no GET_ITEM_INFO_RECEIVED,
-- so we retry on a short timer (asking GetItemInfo also requests the data),
-- bounded so an unresolvable link can't loop forever.
local ITEM_INFO_RETRY_SECONDS = 0.4
local ITEM_INFO_MAX_RETRIES   = 6

function LT:OnLootReceived(recipient, itemLink, count, pushed, attempt)
    if not self.currentSession then return end
    local itemId = GetItemIDFromLink(itemLink)
    if not itemId then return end

    -- Defer until the item cache is warm so material classification is reliable
    -- (see ITEM_INFO_* above). The GetItemInfo call also kicks off the fetch.
    if not GetItemInfo(itemLink) and (attempt or 0) < ITEM_INFO_MAX_RETRIES then
        After(ITEM_INFO_RETRY_SECONDS, function()
            self:OnLootReceived(recipient, itemLink, count, pushed, (attempt or 0) + 1)
        end)
        return
    end

    -- Master-loot manual rolls: assignment of the announced item ends its
    -- roll. Close the window now so a later unrelated /roll within the 120s
    -- timeout can't be mis-recorded as a Need roll on an already-resolved
    -- item. The item's existing roll entry (built during the rolling phase)
    -- and recipient fill-in below are unaffected.
    -- (Skip for PUSHED items — an LFG/quest/mail item is never a master-loot
    -- assignment, so it must not close an active manual-roll window early.)
    if not pushed and self.manualRoll and self.manualRoll.itemId == itemId then
        self.manualRoll = nil
    end

    local quality = GetItemQualityFromLink(itemLink)

    -- Classification gate: currencies and materials never enter boss.items.
    -- They aggregate per-session into their own buckets so the Bosses tab
    -- stays focused on rolled gear. Runs BEFORE the grey/white quality drop
    -- below so materials and currencies are logged at EVERY tier — many
    -- crafting mats are white/common (and the odd one grey), and a server's
    -- emblems / marks can be any quality; the tier gate must never silently
    -- swallow them. Also runs BEFORE the rollID/snapshot/DB walks — those
    -- paths assume boss attribution and would otherwise create placeholder
    -- boss entries for emblems / dust / shards.
    --
    -- Recipient scope differs by class. ParseLoot sets recipient to
    -- UnitName("player") for your own "You receive loot:" line and to the other
    -- player's name for "X receives loot:", so IsLocalPlayer cleanly tells them
    -- apart. CURRENCIES are recorded for yourself only — emblems/marks aren't
    -- reliably broadcast for other players (and looted gold can't be split per
    -- player on 3.3.5), so the Currencies tab tracks just what YOU earned.
    -- MATERIALS are broadcast via "X receives loot:" for everyone in loot range,
    -- so they're recorded for the whole group and grouped per player in the UI.
    -- Either way a classified item returns here and never reaches the boss walks.
    if IsCurrency(itemId) then
        if IsLocalPlayer(recipient) then
            local entry = RecordCurrency(self.currentSession, itemId, itemLink, recipient, count)
            self:Fire("CurrencyReceived", self.currentSession, entry)
        end
        return
    end
    if IsMaterial(itemLink) then
        local entry = RecordMaterial(self.currentSession, itemId, itemLink, recipient, count)
        self:Fire("MaterialReceived", self.currentSession, entry)
        return
    end

    -- Items PUSHED to you (the random-dungeon emblem bonus, a quest reward, mail,
    -- crafting) are recorded above when they're currency/material, but they are NOT
    -- boss loot — stop here so a pushed gear item can never be mis-attributed to
    -- the current boss.
    if pushed then return end

    -- Drop grey/white drops entirely — the addon tracks rolled loot, and
    -- vendor trash would just pollute the items list and force extra UI
    -- filtering downstream. Unknown-quality items pass through (we can't
    -- distinguish "junk" from "parse failure"); the DB walk below also
    -- only succeeds when the item is in a boss's loot table, which never
    -- includes vendor trash, so the practical effect is the same. Materials
    -- and currencies were already classified and returned above, so they are
    -- unaffected by this tier gate.
    if quality and quality < 2 then return end

    -- Short-circuit: if START_LOOT_ROLL recently created an item entry for
    -- this itemId (active rollID context), reuse it. Runs BEFORE the sub-rare
    -- gate so per-drop ctx-bound entries are honored for both rare+ AND
    -- sub-rare rolled drops — without this ordering, the sub-rare gate's
    -- FindItemInBoss would find the first matching entry on a second drop,
    -- filling the wrong entry's recipient and leaving the new per-drop entry
    -- (created by OnStartLootRoll) with no recipient.
    local ctxID, ctx = FindGroupRollContext(self, itemId)
    if ctx then
        local boss = ctx.session.bosses[ctx.bossIndex]
        local item = boss and boss.items[ctx.itemIndex]
        if item then
            -- Each OnStartLootRoll creates a fresh entry, so item.recipient
            -- is nil here. The guard remains in case a previous drop's ctx was
            -- somehow re-bound (shouldn't happen with per-drop entries, but
            -- cheap insurance) — we never clobber an already-set recipient.
            if not item.recipient then
                item.recipient = recipient
                item.count     = count or item.count or 1
            end
            MaybeAddSyntheticRoll(self, item, recipient)
            self:Fire("ItemReceived", ctx.session, boss, item)
            -- Drop the rollID — this drop is fully accounted for. Without
            -- this, a re-drop of the same itemId within the grace window
            -- would re-bind to this stale ctx and double-count via the
            -- next OnLootReceived. The natural terminal signal for a roll's
            -- lifecycle is its "X receives loot" message.
            self.activeGroupRolls[ctxID] = nil
            return
        end
    end

    -- Sub-rare drops (uncommon greens) route to the per-session Trash bucket.
    -- Bosses tab is rare+ only — without this gate, a green BoE listed in a
    -- DB-known boss's loot table would attribute to the boss via the DB walk
    -- below. Runs AFTER currency/material classification and the ctx short-
    -- circuit — anything reaching here is a non-rolled sub-rare (solo autoloot,
    -- master-loot direct assignment, or addon-loaded-mid-receive).
    if quality and quality < 3 then
        local trash = GetOrCreateTrashBoss(self.currentSession)
        if not trash then return end
        local existing = ClaimOrCreateItem(trash, itemId, itemLink, recipient, count, quality)
        MaybeAddSyntheticRoll(self, existing, recipient)
        self:Fire("ItemReceived", self.currentSession, trash, existing)
        return
    end

    -- Data-determined attribution: deterministic kills + bridge + instance.
    local active, uncertain = ResolveLootTarget(self, itemId)
    if not active then return end
    local existing = ClaimOrCreateItem(active, itemId, itemLink, recipient, count, quality)
    if uncertain then existing.uncertain = true end
    MaybeAddSyntheticRoll(self, existing, recipient)
    self:Fire("ItemReceived", self.currentSession, active, existing)
end

-- Looted money (CHAT_MSG_MONEY). Aggregated per session as a single copper
-- total surfaced at the top of the Currencies tab. Money is always personal —
-- the client only ever emits your own loot/your-share line, never another
-- player's — so there's no recipient map and no personal-loot gate. Gated to an
-- active session, like every other tracker, so world/quest money isn't counted.
function LT:OnMoneyReceived(copper)
    if not self.currentSession then return end
    if not copper or copper <= 0 then return end
    local session = self.currentSession
    session.money = (session.money or 0) + copper
    self:Fire("MoneyReceived", session, session.money)
end

-- Create a fresh per-copy item entry on the resolved boss (or the per-session
-- Trash bucket for sub-rare) and register an activeGroupRolls context keyed by
-- `rollID`, so the subsequent roll messages and the eventual receive bind to
-- THIS copy. Shared by the two callers that both mean "one more copy of this
-- item is up for rolling": OnStartLootRoll (numeric rollID, group loot) and
-- OnManualRollAnnounce (synthetic "manual:N" rollID, master loot).
--
-- A fresh entry per call is the whole point: the same itemId can drop multiple
-- times, and reusing one entry (as the old manual-roll path did via
-- FindItemInBoss) collapses the copies into one and lets the rolledBy guard in
-- OnGroupLootRoll swallow every repeat roller. Returns rollID on success, nil if
-- the item couldn't be placed.
local function OpenRollEntry(self, rollID, itemLink, itemId, count, quality, durSec)
    local session = self.currentSession
    if not session then return nil end

    local boss, bossIndex, uncertain
    if quality < 3 then
        -- Sub-rare → per-session Trash bucket (Bosses tab is rare+ only) so later
        -- roll/won/receive messages for this rollID attribute to a Trash entry
        -- rather than promoting a green onto the boss. Trash is keyed by a
        -- deterministic guid, so FindBossByGuid avoids a reverse scan; the `or`
        -- fallback makes the post-insert invariant explicit (GetOrCreateTrashBoss
        -- just inserted at the end, or found the existing entry).
        boss = GetOrCreateTrashBoss(session)
        if boss then
            bossIndex = FindBossByGuid(session, "trash:" .. tostring(session.id))
                or #session.bosses
        end
    else
        -- Data-determined resolution: same model as OnLootReceived so a roll and
        -- its eventual receive land on the same boss. uncertain is stamped on the
        -- entry now — the winning receive hits the FindGroupRollContext short-
        -- circuit and never re-resolves, so this is the only chance to mark it.
        boss, uncertain = ResolveLootTarget(self, itemId)
        if not boss then return nil end
        for i, b in ipairs(session.bosses) do if b == boss then bossIndex = i break end end
    end
    if not boss or not bossIndex then return nil end

    local item = {
        itemId    = itemId,
        itemLink  = itemLink,
        count     = count or 1,
        quality   = quality,
        droppedAt = Now(),
        rolls     = {},
    }
    if uncertain then item.uncertain = true end
    table.insert(boss.items, item)
    local itemIndex = #boss.items
    self:Fire("ItemReceived", session, boss, item)

    self.activeGroupRolls[rollID] = {
        session   = session,
        bossIndex = bossIndex,
        itemIndex = itemIndex,
        itemId    = itemId,
        itemLink  = itemLink,
        startedAt = Now(),
        expiresAt = Now() + (durSec or 90) + GROUP_ROLL_GRACE_SECONDS,
    }
    return rollID
end

-- START_LOOT_ROLL fires on EVERY client eligible to roll on a group-loot item —
-- not just the looter. This is the only signal a non-looter ever gets that an
-- item is up for rolling (LOOT_OPENED only fires for the player whose corpse
-- window is open). The rollID gives a deterministic item identity via
-- GetLootRollItemInfo / GetLootRollItemLink, so subsequent CHAT_MSG_LOOT roll
-- messages map straight to the right boss + item entry.
function LT:OnStartLootRoll(rollID, duration)
    if not self.currentSession then return end

    local itemLink = GetLootRollItemLink and GetLootRollItemLink(rollID)
    if not itemLink then return end
    local itemId = GetItemIDFromLink(itemLink)
    if not itemId then return end

    -- Bail if quality is missing (stale rollID or transient API miss): a nil
    -- quality would bypass the rare+ gate and leak greys into the boss list.
    -- The chat-message fallback in OnGroupLootRoll still catches genuine rolls.
    local _, _, count, quality = GetLootRollItemInfo(rollID)
    if not quality or quality < 2 then return end

    -- WoW 3.3.5 passes `duration` in milliseconds.
    OpenRollEntry(self, rollID, itemLink, itemId, count, quality, (duration or 90000) / 1000)
end

-- CANCEL_LOOT_ROLL fires when the roll ends (someone won, everyone passed,
-- or the timer expired). Late chat messages ("X rolled Y for [Item]", or
-- the final "X won: [Item]") can still arrive *after* this, so shrink the
-- expiry instead of removing the entry immediately. math.min guards against
-- the case where CANCEL fires near the natural-expiry boundary — without it,
-- a late CANCEL would *extend* the window past the original expiresAt and
-- widen the same-itemId cross-attribution risk in FindGroupRollContext.
function LT:OnCancelLootRoll(rollID)
    local entry = self.activeGroupRolls[rollID]
    if entry then
        entry.expiresAt = math.min(entry.expiresAt, Now() + GROUP_ROLL_GRACE_SECONDS)
    end
end

-- Find the most recent unexpired rollID context whose item matches `itemId`.
-- Prunes any expired entries in the same pass — activeGroupRolls is otherwise
-- unbounded across long sessions. Returns (rollID, entry) or nil. Assigned
-- (not declared) — see forward declaration above.
FindGroupRollContext = function(self, itemId)
    local now = Now()
    local bestID, bestEntry
    for rollID, entry in pairs(self.activeGroupRolls) do
        if now > entry.expiresAt then
            self.activeGroupRolls[rollID] = nil
        elseif entry.itemId == itemId then
            if not bestEntry or entry.startedAt > bestEntry.startedAt then
                bestEntry = entry
                bestID    = rollID
            end
        end
    end
    return bestID, bestEntry
end

function LT:OnGroupLootRoll(playerName, value, itemLink, rollType)
    if not self.currentSession then return end

    -- "You passed on: [Item]" → playerName captured as "You". Resolve to the
    -- actual character name so rolledBy dedup, class lookup, and the inspect
    -- ticker (GetEquippedForCompare → FindUnitByName) all key off the right
    -- identity. Without this, the saved data stores literal "You" entries
    -- with no class and no equippedLink.
    if playerName == "You" then
        playerName = UnitName("player") or playerName
    end

    local itemId = GetItemIDFromLink(itemLink)
    if not itemId then return end
    -- Same quality gate as OnLootReceived — don't track grey/white rolls
    -- (only relevant if the player has lowered their loot threshold below
    -- "Uncommon"; default behavior never group-loots greys/whites anyway).
    local rollQuality = GetItemQualityFromLink(itemLink)
    if rollQuality and rollQuality < 2 then return end

    local session, boss, item

    -- Fast path: START_LOOT_ROLL gave us an exact rollID→boss/item context.
    -- This bypasses re-resolution entirely for the common case. It is NOT
    -- fully deterministic when two contexts share the same itemId with
    -- overlapping roll windows — CHAT_MSG_LOOT carries no rollID, so all roll
    -- messages for that itemId route to the most-recently-started context.
    -- This happens for (a) two bosses dropping the same item, and (b) a
    -- single boss dropping the same itemId twice with overlapping windows
    -- (per-drop entries from OnStartLootRoll): drop 1's late roll messages
    -- route to drop 2's entry. Inherent limit of the chat surface.
    local ctxID, ctx = FindGroupRollContext(self, itemId)
    if ctx then
        session = ctx.session
        boss = session.bosses[ctx.bossIndex]
        item = boss and boss.items[ctx.itemIndex]
        -- Item could have been deleted out from under us by /lt reset between
        -- roll messages. Drop the stale context; fallback re-resolves session
        -- and boss, so no need to nil them here.
        if not item then
            self.activeGroupRolls[ctxID] = nil
        end
    end

    -- Fallback: no START_LOOT_ROLL was seen for this item. Happens when the
    -- addon loaded mid-roll, the event was missed, or for "X passed on:"
    -- messages whose roll context was already pruned.
    if not item then
        local uncertain
        if rollQuality and rollQuality < 3 then
            -- Sub-rare → Trash (Bosses tab is rare+ only). Third leg of
            -- the same gate that runs in OnLootReceived and OnStartLootRoll
            -- — covers the case where this is the first roll message we
            -- ever see for this item (addon loaded mid-roll, or a "passed
            -- on" message whose START_LOOT_ROLL context was already pruned).
            session = self.currentSession
            boss = GetOrCreateTrashBoss(session)
            if not boss then return end
        else
            session = self.currentSession
            boss, uncertain = ResolveLootTarget(self, itemId)
            if not boss then return end
        end

        local _, existing = FindItemInBoss(boss, itemId)
        if not existing then
            existing = {
                itemId    = itemId,
                itemLink  = itemLink,
                count     = 1,
                quality   = rollQuality,
                droppedAt = Now(),
                rolls     = {},
            }
            -- Stamp uncertainty only on a freshly-created entry. The winning
            -- receive hits the ctx short-circuit and never re-resolves, so
            -- this is the only chance to mark a shared item routed to its
            -- most-recent sharing boss.
            if uncertain then existing.uncertain = true end
            table.insert(boss.items, existing)
            self:Fire("ItemReceived", session, boss, existing)
        end
        item = existing
    end

    if not item.rolledBy then
        item.rolledBy = {}
        for _, r in ipairs(item.rolls) do item.rolledBy[r.player] = true end
    end

    if item.rolledBy[playerName] then
        -- Existing entry. Allowed transitions while no numeric value has
        -- landed yet (r.value == nil):
        --   * Intent → other intent (Need → Greed, Greed → Need, etc.)
        --   * Intent → Pass (player changed their mind before rolling)
        --   * Pass → intent (rare but harmless; e.g., re-opened loot dialog)
        --   * Intent → numeric (the normal roll-resolution upgrade)
        -- Once r.value is numeric, it's locked: don't downgrade to nil, and
        -- don't overwrite with a second numeric (first broadcast wins on the
        -- rare case of duplicates).
        for _, r in ipairs(item.rolls) do
            if r.player == playerName then
                if r.value ~= nil then return end  -- locked
                r.value    = value
                r.rollType = rollType
                r.time     = Now()
                if value ~= nil then
                    table.sort(item.rolls,
                        function(a, b) return (a.value or 0) > (b.value or 0) end)
                end
                self:Fire("RollAdded", session, boss, item)
                return
            end
        end
        return
    end

    item.rolledBy[playerName] = true
    table.insert(item.rolls, {
        player       = playerName,
        class        = self:GetPlayerClass(playerName),
        value        = value,
        rollType     = rollType,
        time         = Now(),
        equippedLink = GetEquippedForCompare(playerName, item.itemLink),
    })
    table.sort(item.rolls, function(a, b) return (a.value or 0) > (b.value or 0) end)
    self:Fire("RollAdded", session, boss, item)
end

-- ---------------------------------------------------------------------------
-- Master-loot manual rolls
-- ---------------------------------------------------------------------------
--
-- Under master loot the automatic group-loot roll system is disabled: there is
-- no START_LOOT_ROLL and no "X rolled N for [Item]" CHAT_MSG_LOOT messages.
-- Instead the loot master raid-warns an item ("/rw [Item] roll") and players
-- type /roll, which the server broadcasts as a link-less RANDOM_ROLL_RESULT
-- system message. We anchor those rolls to the most recently announced item.

-- Open the manual-roll window AND a per-copy entry from a raid-warning item link.
-- Gated to master loot so normal group-loot raids — where START_LOOT_ROLL already
-- tracks rolls — don't spawn phantom entries from incidental item links in a
-- warning. Only the FIRST link in the warning is used.
--
-- Master loot has no rollID, so each announce is treated as "one more copy of
-- this item is up": it opens its own entry + context (synthetic rollID) via
-- OpenRollEntry. This is what makes two copies of the same item raid-warned in
-- turn both get logged, instead of the old FindItemInBoss path collapsing them
-- into one. The re-warn guard below keeps a reminder from spawning a phantom.
function LT:OnManualRollAnnounce(itemLink)
    if not self.currentSession then return end
    if not (GetLootMethod and GetLootMethod() == "master") then return end
    local itemId = GetItemIDFromLink(itemLink)
    if not itemId then return end

    -- A re-warn while a MASTER-LOOT copy of this item is still open (being rolled,
    -- not yet received) is a reminder, not a new drop — keep the window on that
    -- copy instead of spawning a phantom. A genuinely new copy is detected when
    -- the previous one's context is gone (its receive dropped it, or it expired).
    -- We key the suppression on a *manual* context only: manual rollIDs are
    -- strings ("manual:N"), group-loot rollIDs are numbers. A stray leftover
    -- group-loot context for the same itemId (numeric; e.g. a loot-method change
    -- mid-pull) must NOT block a real new master-loot copy.
    local openID = FindGroupRollContext(self, itemId)
    if type(openID) ~= "string" then
        -- Quality from the link color — GetItemInfo is unreliable on a cold
        -- cache; if unparseable, skip eager creation and let the first /roll
        -- create the entry lazily via OnGroupLootRoll's fallback.
        local quality = GetItemQualityFromLink(itemLink)
        if quality then
            self.manualRollSeq = (self.manualRollSeq or 0) + 1
            OpenRollEntry(self, "manual:" .. self.manualRollSeq, itemLink, itemId,
                1, quality, MANUAL_ROLL_WINDOW_SECONDS)
        end
    end

    self.manualRoll = {
        itemId    = itemId,
        itemLink  = itemLink,
        expiresAt = Now() + MANUAL_ROLL_WINDOW_SECONDS,
    }
end

-- Attach a manual /roll result to the active roll window. Only standard 1-100
-- rolls count — off-spec (/roll 1-50) and tiebreak (/roll 101-200) ranges are
-- ignored so they don't pollute the main roll list. Delegates to OnGroupLootRoll
-- with the announced item link so all boss-resolution, dedup, and sort logic is
-- shared; rollType "Need" is what a master-loot roll effectively is (and renders
-- as the dice icon). The 3.3.5 RANDOM_ROLL_RESULT message uses the roller's real
-- name even for the local player, so no "You" remap is needed here.
function LT:OnManualRoll(playerName, value, minRoll, maxRoll)
    local mr = self.manualRoll
    if not mr then return end
    if Now() > mr.expiresAt then
        self.manualRoll = nil
        return
    end
    if not (playerName and value) then return end
    if minRoll ~= 1 or maxRoll ~= 100 then return end
    self:OnGroupLootRoll(playerName, value, mr.itemLink, "Need")
end

-- Fires when CHAT_MSG_LOOT emits "You won: [Item]" or "<Player> won: [Item]"
-- at the end of a group-loot roll. Only the looter sees their own OnLootReceived
-- for the item — for everyone else, this is the only signal of who got it. Sets
-- item.recipient via the rollID context map so non-looter clients can show the
-- winner alongside the rolls.
--
-- For "Everyone passed on: [Item]" (no winner), pass recipient = nil and the
-- context entry is dropped without touching item.recipient (item stays in the
-- list with rolls visible but no recipient — accurate).
function LT:OnGroupLootWon(recipient, itemLink)
    if not self.currentSession then return end
    local itemId = GetItemIDFromLink(itemLink)
    if not itemId then return end

    local ctxID, ctx = FindGroupRollContext(self, itemId)
    if not ctx then return end

    local session = ctx.session
    local boss = session.bosses[ctx.bossIndex]
    local item = boss and boss.items[ctx.itemIndex]
    if not item then
        self.activeGroupRolls[ctxID] = nil
        return
    end

    -- Looter's OnLootReceived would have already set recipient (it fires
    -- via LOOT_ITEM_SELF before the won-announcement). Don't overwrite, but
    -- DO set it on non-looter clients (where this is the only signal).
    -- "Everyone passed on: [Item]" passes recipient = nil; leave the entry
    -- as-is (rolls visible, no recipient — accurate).
    if recipient and not item.recipient then
        item.recipient = recipient
        self:Fire("ItemReceived", session, boss, item)
    end

    -- Do NOT drop activeGroupRolls[ctxID] here. The matching "X receives loot"
    -- CHAT_MSG_LOOT fires within milliseconds AFTER this won message, and
    -- OnLootReceived needs the context to bind the receive to the same boss
    -- the START_LOOT_ROLL anchored to. Natural expiry via the CANCEL_LOOT_ROLL
    -- grace handles cleanup.
end

-- ---------------------------------------------------------------------------
-- Trade-window helpers
-- ---------------------------------------------------------------------------

-- Returns seconds remaining in the 2h trade window, or nil if past it / no
-- droppedAt. Pure function — used by the ticker, the sticky panel, and the
-- inline badge so all three agree on remaining time.
-- Monotonic-elapsed guard so a trade timer can NEVER renew, reset, or jump back
-- up — it only ever counts down, and once it runs out it stays out.
--
-- The window is anchored on droppedAt (an absolute time() / wall-clock stamp,
-- written once). The raw remaining is TRADE_WINDOW_SECONDS - (Now() - droppedAt).
-- That is exact while the clock advances normally, but if the system clock moves
-- BACKWARD across a relog / game restart / crash recovery (NTP correction at
-- boot, DST/TZ glitch, VM or Wine clock jump, a corrupt/imported stamp) the raw
-- elapsed shrinks and the countdown would creep upward — a forbidden "reset".
--
-- item.maxElapsed is the high-water mark of elapsed seconds: ratcheted up every
-- tick (TickTradeTimers) and persisted in SavedVariables, so it survives reload,
-- logout, and crash. We compute remaining from max(rawElapsed, maxElapsed), which
-- guarantees elapsed never decreases and therefore remaining never increases, for
-- ANY cause of an apparent backward jump (the >window clock-skew case AND a
-- smaller-than-window drift alike). A future-dated stamp yields a negative raw
-- elapsed; the `or 0` floor keeps remaining capped at the true window.
--
-- One-directional by design: a spurious FORWARD clock jump sampled by the ticker
-- would ratchet elapsed too high and could expire an item early. That requires a
-- within-session forward glitch (boot-time corrections land before the addon
-- loads), which a normal client clock does not produce — and erring toward
-- "expired" is the safe direction here: the rule is that a timer must never come
-- back, so we never resurrect one.
function LT:GetTradeRemaining(item)
    if not item or not item.droppedAt then return nil end
    local elapsed = Now() - item.droppedAt
    local hwm = item.maxElapsed or 0
    if hwm > elapsed then elapsed = hwm end
    local remaining = TRADE_WINDOW_SECONDS - elapsed
    if remaining <= 0 then return nil end
    return remaining
end

-- Format helper: "1h 47m" while > 1h, "47m" while > 5m, "4m 23s" in the last
-- 5 minutes (so the player sees a meaningful change every second near the end).
local function FormatTradeRemaining(remaining)
    if remaining >= 3600 then
        return string.format("%dh %02dm", math.floor(remaining / 3600),
            math.floor((remaining % 3600) / 60))
    elseif remaining > 300 then
        return string.format("%dm", math.ceil(remaining / 60))
    else
        local mins = math.floor(remaining / 60)
        local secs = math.floor(remaining % 60)
        return string.format("%dm %02ds", mins, secs)
    end
end

-- Color hex picked by urgency. See the spec's threshold table.
local function ColorTradeRemaining(remaining)
    if     remaining > 3600 then return "00ff00"  -- green
    elseif remaining > 1800 then return "ffff00"  -- yellow
    elseif remaining >  600 then return "ff8000"  -- orange
    else                        return "ff0000"  -- red
    end
end

-- Bundle the three numbers the UI needs. Returns nil if the item is past
-- its window so the caller can branch cleanly on "show timer or not".
function LT:GetTradeTimerStatus(item)
    local remaining = self:GetTradeRemaining(item)
    if not remaining then return nil end
    return {
        remainingSec = remaining,
        text         = FormatTradeRemaining(remaining),
        color        = ColorTradeRemaining(remaining),
    }
end

-- Flat sorted list for the sticky panel. Soonest-expiring first.
--
-- Panel-only filters (the Bosses tab list is unaffected):
--   * Distributed items follow the same distributedMode toggle as the Bosses
--     list: in "check" mode (default) they stay in the panel — the UI renders
--     them with the distributed marker instead of a countdown — and in "remove"
--     mode they are dropped from the panel entirely.
--   * In raid instances, sub-epic drops (quality < 4) are dropped so the panel
--     reminds only about gear worth chasing a trade for. Dungeons (party) and
--     any other instance type keep every quality. Quality is read from the link
--     each call; an unresolvable quality (cold cache) is treated as non-epic
--     and excluded in raids.
-- The 2h trade window still gates everything: an item only appears while it
-- still has remaining time, distributed or not.
function LT:GetActiveTradeTimers(session)
    if not session or not session.bosses then return {} end
    local raidFilter = session.instanceType == "raid"
    local removeDistributed = LootTrackerDB and LootTrackerDB.distributedMode == "remove"
    -- BoE filter: when disabled, BoE drops are dropped from the panel entirely
    -- (they have no real trade deadline). A cold-cache item reports nil here and
    -- is kept — it heals on a later tick once its bind type resolves.
    local hideBoE = LootTrackerDB and LootTrackerDB.tradeTimers
        and LootTrackerDB.tradeTimers.showBoE == false
    local result = {}
    for _, boss in ipairs(session.bosses) do
        for _, item in ipairs(boss.items) do
            local remaining = self:GetTradeRemaining(item)
            if remaining and not (removeDistributed and item.distributed) then
                local include = true
                if raidFilter then
                    local q = GetItemQualityFromLink(item.itemLink)
                    include = (q ~= nil) and q >= 4
                end
                if include and hideBoE and self:GetItemBoE(item.itemId) then
                    include = false
                end
                if include then
                    result[#result + 1] = {
                        item         = item,
                        boss         = boss,
                        remainingSec = remaining,
                    }
                end
            end
        end
    end
    -- Still-to-trade items first (so the small visible window surfaces what the
    -- player still needs to hand off), then distributed items; each group sorted
    -- soonest-expiring first.
    table.sort(result, function(a, b)
        local ad = a.item.distributed and 1 or 0
        local bd = b.item.distributed and 1 or 0
        if ad ~= bd then return ad < bd end
        return a.remainingSec < b.remainingSec
    end)
    return result
end

-- ---------------------------------------------------------------------------
-- Bag scan: recover already-tradeable drops into the trade window
-- ---------------------------------------------------------------------------
--
-- After a crash/relog where the trade-window entry was never persisted (WoW only
-- flushes SavedVariables on clean logout/reload — there is no force-save API in
-- 3.3.5), a looted BoP item can sit in the bags still tradeable but untracked.
-- This recovers it WITHOUT fabricating a deadline: WotLK exposes the real
-- remaining trade time on the item's bag tooltip
--   BIND_TRADE_TIME_REMAINING = "You may trade this item with players that were
--    also eligible to loot this item for the next %s."
-- so we read the true remaining time and back-compute droppedAt. No readable
-- line (soulbound / ineligible / server doesn't render it) ⟹ the item is skipped,
-- never given an invented timer. This keeps the monotonic "never renew" contract.

-- Pull hours+minutes out of the trade line's duration ("1 hour 47 min",
-- "2 hours", "47 minutes", "30 min", "1h 47m", ...). The duration is isolated
-- FIRST to just the tail after "next " (the global is "...for the next %s.") so a
-- number injected earlier in the line by a server reword can't be miscounted;
-- if that anchor is absent we fall back to the whole line. Within the duration, a
-- number before an h/H is hours and before an m/M is minutes. Returns seconds in
-- (0, TRADE_WINDOW_SECONDS], or nil if nothing parses.
local function ParseTradeDuration(text)
    if not text then return nil end
    local dur = text:match("[Nn]ext%s+(.-)%.?%s*$") or text
    local total, found = 0, false
    for n in dur:gmatch("(%d+)%s*[Hh]") do total = total + tonumber(n) * 3600; found = true end
    for n in dur:gmatch("(%d+)%s*[Mm]") do total = total + tonumber(n) * 60;   found = true end
    if not found or total <= 0 then return nil end
    if total > TRADE_WINDOW_SECONDS then total = TRADE_WINDOW_SECONDS end
    return total
end

-- Read a bag item's remaining BoP trade time by scanning its (per-instance) bag
-- tooltip. SetBagItem is required — the static "item:" link does NOT carry the
-- trade line. The phrase match is deliberately lenient (lower-cased substring,
-- not the full anchored global string) so a server-side reword of the tail still
-- works; Warmane is known to redefine some loot globals. Returns seconds or nil.
local tradeScanner
function LT:GetBagItemTradeRemaining(bag, slot)
    if not tradeScanner then
        tradeScanner = CreateFrame("GameTooltip", "LootTrackerTradeScanner", nil, "GameTooltipTemplate")
        tradeScanner:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    tradeScanner:ClearLines()
    tradeScanner:SetBagItem(bag, slot)
    local n = tradeScanner:NumLines() or 0
    -- Scan from line 1 (no item name can contain the trade phrase) so the match
    -- is robust to whatever line the trade notice lands on.
    for i = 1, n do
        local fs = _G["LootTrackerTradeScannerTextLeft" .. i]
        local text = fs and fs:GetText()
        if text and text:lower():find("you may trade this item", 1, true) then
            return ParseTradeDuration(text)
        end
    end
    return nil
end

local TRADE_RECOVER_DEDUP_TOLERANCE = 90  -- seconds; covers minute-rounding + drift

-- Scan the player's bags and add any still-tradeable item that drops from a boss
-- in the CURRENT instance but isn't already tracked. Returns scanned, updated
-- (scanned = current-instance tradeable items examined; updated = newly added).
function LT:ScanBagsForTradeWindow()
    local session = self.currentSession
    if not session then return 0, 0 end
    local now = Now()
    -- Same data-determined model the live loot path uses: an item belongs to
    -- the current instance iff ResolveItemSource pins it to a bridge boss in
    -- this instance (a boss we killed, or the unique boss in this instance that
    -- drops it). Trash / uncertain items are not recovered — never invent a
    -- source for an ambiguous drop.
    local ctx = BuildAttributionCtx(self)

    -- Collect tradeable current-instance bag copies, grouped by itemId.
    local byItem, scanned = {}, 0
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            local itemId = link and GetItemIDFromLink(link)
            if itemId then
                local decision = LT.ResolveItemSource(itemId, ctx)
                -- Only a confident, non-uncertain boss source counts as
                -- "drops from a boss in this instance". Uncertain (several
                -- possible bosses) and trash are skipped.
                local inInstance = decision.kind == "boss" and not decision.uncertain
                if inInstance then
                    local remaining = self:GetBagItemTradeRemaining(bag, slot)
                    if remaining then
                        scanned = scanned + 1
                        local _, count = GetContainerItemInfo(bag, slot)
                        local list = byItem[itemId]
                        if not list then list = {}; byItem[itemId] = list end
                        list[#list + 1] = { remaining = remaining, link = link, count = count or 1 }
                    end
                end
            end
        end
    end

    -- Dedup per itemId by remaining-time proximity, then recover the uncovered
    -- copies. Existing live entries are consumed on match so a partially-tracked
    -- multi-copy stack (2 in bags, 1 tracked) adds exactly the missing one.
    local updated = 0
    for itemId, copies in pairs(byItem) do
        local existing = {}
        for _, boss in ipairs(session.bosses) do
            for _, item in ipairs(boss.items) do
                if item.itemId == itemId then
                    local r = self:GetTradeRemaining(item)
                    if r then existing[#existing + 1] = r end
                end
            end
        end
        for _, copy in ipairs(copies) do
            -- Consume the CLOSEST in-tolerance existing entry (not merely the
            -- first), so when several copies and several tracked entries have
            -- overlapping tolerance windows they pair up by nearest remaining
            -- rather than greedily — avoiding a spurious extra recovery.
            local matchedIdx, matchedDist
            for idx = 1, #existing do
                if existing[idx] then
                    local dist = math.abs(existing[idx] - copy.remaining)
                    if dist <= TRADE_RECOVER_DEDUP_TOLERANCE
                        and (not matchedDist or dist < matchedDist)
                    then
                        matchedIdx, matchedDist = idx, dist
                    end
                end
            end
            if matchedIdx then
                existing[matchedIdx] = false  -- consumed; already tracked
            else
                -- Resolve (and register, if needed) the boss this item drops
                -- from. The membership filter above already guaranteed a
                -- confident boss decision for this itemId, so ResolveLootTarget
                -- returns that boss; the guard is defensive only.
                local boss = ResolveLootTarget(self, itemId)
                if boss then
                    local elapsed = TRADE_WINDOW_SECONDS - copy.remaining
                    local entry = {
                        itemId     = itemId,
                        itemLink   = copy.link,
                        recipient  = UnitName("player"),
                        count      = copy.count or 1,
                        quality    = GetItemQualityFromLink(copy.link),
                        droppedAt  = now - elapsed,
                        maxElapsed = elapsed,  -- seed the monotonic guard at the true elapsed
                        rolls      = {},
                        recovered  = true,     -- provenance: came from a bag scan, not a live loot
                    }
                    table.insert(boss.items, entry)
                    self:Fire("ItemReceived", session, boss, entry)
                    updated = updated + 1
                end
            end
        end
    end

    if updated > 0 then self:StartTradeTimerTicker() end
    return scanned, updated
end

-- ---------------------------------------------------------------------------
-- Trade-window ticker
-- ---------------------------------------------------------------------------

-- Print a single chat alert. Matches the existing |cffffd200LootTracker|r
-- prefix used by debug output so users recognise the source. The separator
-- between item link and label is a plain ASCII hyphen: WoW 3.3.5's chat
-- frame renders the em-dash UTF-8 byte sequence (\xe2\x80\x94) as garbled
-- text on most fonts/locales.
local function PrintTradeAlert(item, label)
    if not item or not item.itemLink then return end
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cffffd200LootTracker|r %s - %s",
        item.itemLink, label))
end

-- Walk existing items at AddonLoaded and mark every already-crossed threshold
-- as alerted WITHOUT firing chat. Suppresses the chat-flood that would
-- otherwise happen the first time the user reloads after installing this
-- feature (potentially dozens of items × four thresholds each), or after
-- the addon was disabled long enough for many items to cross thresholds
-- while it wasn't watching.
--
-- Freshly-dropped items added AFTER this runs (via OnLootReceived) start
-- with no alertedThresholds; TickTradeTimers lazy-inits the field there and
-- their remaining time is still > every threshold, so no thresholds get
-- pre-marked and alerts fire normally as time crosses each one.
local function SeedAlertedThresholds()
    EnsureDB()
    local now = Now()
    for _, session in ipairs(LootTrackerDB.sessions or {}) do
        for _, boss in ipairs(session.bosses) do
            for _, item in ipairs(boss.items) do
                if item.droppedAt and not item.alertedThresholds then
                    item.alertedThresholds = {}
                    -- Use the monotonic elapsed (high-water mark) so the seed
                    -- matches TickTradeTimers / GetTradeRemaining; otherwise a
                    -- backward clock move across the reload would leave thresholds
                    -- unmarked and replay their alerts on the first tick.
                    local elapsed = now - item.droppedAt
                    if (item.maxElapsed or 0) > elapsed then elapsed = item.maxElapsed end
                    local remaining = TRADE_WINDOW_SECONDS - elapsed
                    for _, th in ipairs(TRADE_ALERT_THRESHOLDS) do
                        if remaining <= th.atOrBelow then
                            item.alertedThresholds[th.key] = true
                        end
                    end
                end
            end
        end
    end
end

local tradeTickerFrame
local tradeTickerElapsed = 0

local function TickTradeTimers()
    EnsureDB()
    local alertsOn = LootTrackerDB.tradeTimers
        and LootTrackerDB.tradeTimers.alerts
    local alertMinQuality = (LootTrackerDB.tradeTimers
        and LootTrackerDB.tradeTimers.alertMinQuality) or 3
    local anyLive = false
    local anyAlertFired = false
    local now = Now()

    for _, session in ipairs(LootTrackerDB.sessions or {}) do
        for _, boss in ipairs(session.bosses) do
            for _, item in ipairs(boss.items) do
                -- Distributed items are settled: no countdown alerts, and they
                -- must not keep the ticker alive on their own (anyLive).
                if item.droppedAt and not item.distributed then
                    item.alertedThresholds = item.alertedThresholds or {}
                    -- Ratchet the elapsed high-water mark (see GetTradeRemaining).
                    -- maxElapsed only ever grows and is persisted, so a backward
                    -- clock move across reload / logout / crash can never rewind
                    -- it — the timer stays monotonic and never renews.
                    local rawElapsed = now - item.droppedAt
                    if rawElapsed > (item.maxElapsed or 0) then
                        item.maxElapsed = rawElapsed
                    end
                    -- Skip items already past the window AND already alerted
                    -- about expiry. Everything else still needs threshold
                    -- checks — including items currently past expiry but not
                    -- yet alerted (addon was disabled when the boundary was
                    -- crossed, or this is the first tick after a fresh login
                    -- with a pre-existing expired item).
                    if not item.alertedThresholds.expired then
                        -- Drive thresholds + expiry off the SAME monotonic elapsed
                        -- the display uses, so the panel countdown, the inline
                        -- badge, and the chat alerts always agree and an item can
                        -- never un-expire or re-fire an alert after a clock jump.
                        local remaining = TRADE_WINDOW_SECONDS - (item.maxElapsed or 0)
                        if remaining > 0 then anyLive = true end
                        -- remaining can be negative here; the threshold list
                        -- includes an entry with atOrBelow = 0 ("expired") so
                        -- the loop catches the expired transition uniformly.
                        for _, th in ipairs(TRADE_ALERT_THRESHOLDS) do
                            if remaining <= th.atOrBelow
                                and not item.alertedThresholds[th.key]
                            then
                                -- Quality gate: only announce items at or above
                                -- the configured tier (default Rare+). Unknown
                                -- quality (cold cache) fails open so a real epic
                                -- is never silently skipped. The item still
                                -- appears in the panel/list regardless — only
                                -- the chat alert is filtered.
                                local q = item.quality
                                    or GetItemQualityFromLink(item.itemLink)
                                local qualityOk = (not q) or q >= alertMinQuality
                                -- Bag-presence gate: only chat-alert for items
                                -- currently in the player's bags. Suppresses
                                -- alerts for items already traded away, items
                                -- looted by other players, and items stashed
                                -- in the bank/mail. GetItemCount default scope
                                -- is bags only (bank/charges excluded).
                                if alertsOn
                                    and qualityOk
                                    and GetItemCount(item.itemId) > 0
                                then
                                    PrintTradeAlert(item, th.label)
                                end
                                -- Always record the threshold, even when alerts
                                -- are suppressed (off, or item not in bags), so
                                -- re-enabling alerts or re-acquiring the item
                                -- doesn't replay historical thresholds.
                                item.alertedThresholds[th.key] = true
                                anyAlertFired = true
                            end
                        end
                    end
                end
            end
        end
    end

    -- Fire only when something changed: at least one item is still live (so
    -- its display text may need updating) or an alert just fired (UI may need
    -- to drop a row from the sticky panel). Skipping the no-op fire keeps the
    -- UI from doing pointless reflows once everything has expired.
    if anyLive or anyAlertFired then
        LT:Fire("TradeTimerTick")
    end

    if not anyLive and tradeTickerFrame then
        tradeTickerFrame:Hide()
    end
end

-- Lazily creates and shows the ticker. Called from AddonLoaded and from
-- OnLootReceived (post-attribution) so new drops re-start a stopped ticker.
function LT:StartTradeTimerTicker()
    if not tradeTickerFrame then
        tradeTickerFrame = CreateFrame("Frame")
        tradeTickerFrame:SetScript("OnUpdate", function(_, dt)
            tradeTickerElapsed = tradeTickerElapsed + dt
            if tradeTickerElapsed < TRADE_TIMER_TICK_SECONDS then return end
            tradeTickerElapsed = 0
            TickTradeTimers()
        end)
    end
    -- Run one tick immediately so the UI / alerts react without waiting for
    -- the first OnUpdate tick after a fresh login.
    tradeTickerElapsed = 0
    TickTradeTimers()
    tradeTickerFrame:Show()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function LT:GetSessions()
    EnsureDB()
    return LootTrackerDB.sessions
end

function LT:GenerateMockData()
    EnsureDB()
    local now = Now()

    local function mkLink(id, name, qHex)
        return "|cff" .. qHex .. "|Hitem:" .. id .. ":0:0:0:0:0:0:0|h[" .. name .. "]|h|r"
    end
    local function mkRoll(player, class, value, equipId, equipName, rollType)
        return {
            player = player, class = class, value = value,
            minRoll = 1, maxRoll = 100, time = now,
            rollType = rollType or "Need",
            equippedLink = equipId and mkLink(equipId, equipName, "a335ee") or nil,
        }
    end
    local function mkItem(id, name, qHex, quality, expanded, rolls, droppedAtOverride)
        local rolledBy = {}
        for _, r in ipairs(rolls) do rolledBy[r.player] = true end
        table.sort(rolls, function(a, b) return (a.value or 0) > (b.value or 0) end)
        return {
            itemId = id, itemLink = mkLink(id, name, qHex),
            count = 1, quality = quality, expanded = expanded,
            droppedAt = droppedAtOverride or now, rolls = rolls, rolledBy = rolledBy,
        }
    end

    local session = {
        id           = LootTrackerDB.nextSessionId,
        instanceName = "Icecrown Citadel",
        instanceType = "raid",
        difficulty   = "25 Player",
        startedAt    = now - 7200,
        endedAt      = nil,
        bosses       = {},
    }
    LootTrackerDB.nextSessionId = session.id + 1

    -- Mock equipped items (verified real IDs via wowhead.com/wotlk):
    --   39417 Death's Bite                       — 2H axe,    Naxx25 KT     (ilvl 213)
    --   47078 Justicebringer                     — 2H axe,    ToC25         (ilvl 258)
    --   40400 Wall of Terror                     — shield,    Naxx25 KT     (ilvl 226)
    --   39515 Heroes' Robe of Faith              — cloth,     T7 Priest     (ilvl 200)
    --   40718 Signet of the Impregnable Fortress — ring,      Naxx25        (ilvl 213)

    -- Dropped + mock equipped item IDs verified via wowhead.com/wotlk:
    --   Dropped (ICC-era):
    --     50415 Bryntroll, the Bone Arbiter        — 2H axe   (Marrowgar)
    --     49835 Splintered Door of the Citadel     — shield   (HoR Marwyn)
    --     51263 Sanctified Crimson Acolyte Robe    — cloth    (ICC vendor, priest)
    --     49623 Shadowmourne                       — 2H axe   (legendary, ICC)
    --     50402 Ashen Band of Endless Vengeance    — ring     (Ashen Verdict)
    --   Mock equipped (Naxx25 / ToC25 — "previous tier"):
    --     39417 Death's Bite                       — 2H axe
    --     47078 Justicebringer                     — 2H axe
    --     40400 Wall of Terror                     — shield
    --     39515 Heroes' Robe of Faith              — cloth chest (priest)
    --     40718 Signet of the Impregnable Fortress — ring

    table.insert(session.bosses, {
        name = "Lord Marrowgar",
        killedAt = now - 6800,
        items = {
            mkItem(50415, "Bryntroll, the Bone Arbiter", "a335ee", 4, true, {
                mkRoll("Gronkar",      "WARRIOR",     97,  39417, "Death's Bite", "Need"),
                mkRoll("Plaguebearer", "DEATHKNIGHT", 84,  39417, "Death's Bite", "Need"),
                mkRoll("Stabbystab",   "ROGUE",       55,  39417, "Death's Bite", "Greed"),
                mkRoll("Sneakkitty",   "DRUID",       nil, 39417, "Death's Bite", "Pass"),
                mkRoll("Pewpewlazor",  "PALADIN",     12,  39417, "Death's Bite", "Need"),
            }, now - 1200),  -- 20m elapsed → 1h 40m left (green)
            mkItem(49835, "Splintered Door of the Citadel", "a335ee", 4, false, {
                mkRoll("Pewpewlazor", "PALADIN", 88,  40400, "Wall of Terror", "Need"),
                mkRoll("Gronkar",     "WARRIOR", 45,  40400, "Wall of Terror", "Greed"),
            }, now - 300),   -- 5m elapsed → 1h 55m left (green)
        },
    })

    table.insert(session.bosses, {
        name = "Lady Deathwhisper",
        killedAt = now - 6000,
        items = {
            mkItem(51263, "Sanctified Crimson Acolyte Robe", "a335ee", 4, false, {
                mkRoll("Lightheal",  "PRIEST",  91,  39515, "Heroes' Robe of Faith", "Need"),
                mkRoll("Frostybolt", "MAGE",    73,  39515, "Heroes' Robe of Faith", "Greed"),
                mkRoll("Doomtroll",  "WARLOCK", 42,  39515, "Heroes' Robe of Faith", "Disenchant"),
            }, now - 5400),  -- 90m elapsed → 30m left (orange/yellow edge)
        },
    })

    table.insert(session.bosses, {
        name = "Deathbringer Saurfang",
        killedAt = now - 5200,
        items = {
            mkItem(49623, "Shadowmourne", "ff8000", 5, true, {
                mkRoll("Plaguebearer", "DEATHKNIGHT", 99,  47078, "Justicebringer", "Need"),
                mkRoll("Gronkar",      "WARRIOR",     56,  47078, "Justicebringer", "Need"),
                mkRoll("Pewpewlazor",  "PALADIN",     33,  47078, "Justicebringer", "Need"),
            }, now - 6750),  -- 112.5m elapsed → 7.5m left (red, close to pulse)
            mkItem(50402, "Ashen Band of Endless Vengeance", "a335ee", 4, false, {
                mkRoll("Bowsong",    "HUNTER", 87,  40718, "Signet of the Impregnable Fortress", "Need"),
                mkRoll("Shockwave",  "SHAMAN", 35,  40718, "Signet of the Impregnable Fortress", "Greed"),
                mkRoll("Stabbystab", "ROGUE",  nil, 40718, "Signet of the Impregnable Fortress", "Pass"),
            }, now - 7400),  -- past 2h: no timer
        },
    })

    table.insert(LootTrackerDB.sessions, session)
    -- Mock items are backdated by design (see droppedAt overrides above) so
    -- their timers span every color band. Without this, StartTradeTimerTicker
    -- below would chat-flood the user with every threshold those backdated
    -- items have already crossed. Seed silently before the first tick.
    SeedAlertedThresholds()
    self:Fire("SessionChanged")
    self:StartTradeTimerTicker()
end

function LT:DeleteSession(sessionId)
    EnsureDB()
    for i, s in ipairs(LootTrackerDB.sessions) do
        if s.id == sessionId then
            table.remove(LootTrackerDB.sessions, i)
            if self.currentSession == s then
                self.currentSession = nil
                ClearTransientState(self)
            end
            self:Fire("SessionChanged")
            return true
        end
    end
end

function LT:Reset()
    EnsureDB()
    LootTrackerDB.sessions = {}
    LootTrackerDB.nextSessionId = 1
    if self.currentSession then
        self.currentSession.endedAt = Now()
    end
    self.currentSession = nil
    ClearTransientState(self)
    self:OnZoneChanged()
    -- If we weren't in an instance, OnZoneChanged was a no-op; force a refresh.
    if not self.currentSession then
        self:Fire("SessionChanged")
    end
end

-- ---------------------------------------------------------------------------
-- Chat / combat-log dispatch
-- ---------------------------------------------------------------------------

local function ParseLoot(text)
    local link, qty = text:match(LOOT_SELF_MULTI)
    if link then return UnitName("player"), link, tonumber(qty) end

    link = text:match(LOOT_SELF_SINGLE)
    if link then return UnitName("player"), link, 1 end

    -- Pushed-to-you items (LFG bonus, quest reward, ...) — tagged pushed = true so
    -- the caller records only currencies/materials and never boss-attributes them.
    link, qty = text:match(LOOT_PUSHED_MULTI)
    if link then return UnitName("player"), link, tonumber(qty), true end

    link = text:match(LOOT_PUSHED_SINGLE)
    if link then return UnitName("player"), link, 1, true end

    local name
    name, link, qty = text:match(LOOT_OTHER_MULTI)
    if name and link then return name, link, tonumber(qty) end

    name, link = text:match(LOOT_OTHER_SINGLE)
    if name and link then return name, link, 1 end
end

-- Sum a coin line into total copper. Called for both CHAT_MSG_MONEY and
-- CHAT_MSG_SYSTEM (the dungeon/BG completion reward arrives on one or the other).
-- The message must match a counted wrapper: solo "You loot <amount>", grouped
-- "You receive <amount> as your share.", or the "Received <amount>" reward (see
-- MONEY_LOOT_* / MONEY_REWARD); mail / vendor / quest coin use other wrappers and
-- aren't matched. The captured amount embeds whichever of the three coin tokens
-- are present; we fold them to copper. Returns 0 for a non-coin line or an
-- unparseable amount.
local function ParseMoney(text)
    if not text then return 0 end
    local amount = text:match(MONEY_LOOT_SELF) or text:match(MONEY_LOOT_SHARE)
        or text:match(MONEY_REWARD)
    if not amount then return 0 end
    -- Strip any digit-group separator the client might inject into a large
    -- amount ("1,234 Gold") so the "(%d+)" denomination captures aren't
    -- truncated at the separator. 3.3.5 loot lines are un-separated in practice;
    -- this just keeps the parse correct if a server/locale ever inserts one.
    local sep = LARGE_NUMBER_SEPERATOR or ","
    amount = amount:gsub(sep:gsub("(%W)", "%%%1"), "")
    local g = tonumber(amount:match(MONEY_GOLD))   or 0
    local s = tonumber(amount:match(MONEY_SILVER)) or 0
    local c = tonumber(amount:match(MONEY_COPPER)) or 0
    return g * 10000 + s * 100 + c
end

-- Parse a "won" announcement at the end of a group-loot roll. Returns
-- (recipient, itemLink) where recipient is the local player's name for the
-- self-won variant, the captured player name for the other-won variant, or
-- nil for "Everyone passed" (item was wasted / DE'd). Returns nil entirely
-- if the message isn't a won announcement.
local function ParseGroupLootWon(text)
    local selfLink = text:match(WON_SELF)
    if selfLink then return UnitName("player"), selfLink end

    local otherName, otherLink = text:match(WON_OTHER)
    if otherName and otherLink then return otherName, otherLink end

    local nobodyLink = text:match(WON_NOBODY)
    if nobodyLink then return nil, nobodyLink end
end

local function ParseGroupLootRoll(text)
    -- 1) Fast path: patterns built from WoW globals (LOOT_ROLL_ROLLED_*).
    local name, value, link = text:match(GROUP_ROLL_NEED)
    if name then return name, tonumber(value), link, "Need" end
    name, value, link = text:match(GROUP_ROLL_GREED)
    if name then return name, tonumber(value), link, "Greed" end
    name, value, link = text:match(GROUP_ROLL_DE)
    if name then return name, tonumber(value), link, "Disenchant" end

    -- 2) "Detailed Loot Information" variant (Social options → Detailed Loot).
    -- Format: "<Type> Roll - <Value> for <ItemLink> by <PlayerName>".
    -- The "by <Player>" form is checked BEFORE the self-form so a "by Player"
    -- suffix doesn't get swallowed by the more permissive self pattern.
    -- " [Rr][Oo][Ll][Ll] " is the case-insensitive form of " Roll " (Lua
    -- patterns have no case-insensitive flag); private servers sometimes
    -- lowercase the keyword. The %a+ type capture is lowercased before the
    -- CANONICAL_ROLL_TYPE lookup so it matches regardless of source casing.
    -- rLink is validated to contain |Hitem: because (.-) accepts the empty
    -- string and the caller's `rollName and rollLink` guard treats "" as
    -- truthy — bare validation keeps a malformed message from dispatching.
    local rType, rValue, rLink, rName =
        text:match("^(%a+) [Rr][Oo][Ll][Ll] %- (%d+) for%s*(.-) by (.+)$")
    if rType and rValue and rLink and rName and rLink:find("|Hitem:", 1, true) then
        local canonical = CANONICAL_ROLL_TYPE[rType:lower()]
        if canonical then return rName, tonumber(rValue), rLink, canonical end
    end
    -- Self-roll variant of the same format (no "by Player" suffix).
    rType, rValue, rLink = text:match("^(%a+) [Rr][Oo][Ll][Ll] %- (%d+) for%s*(.+)$")
    if rType and rValue and rLink and rLink:find("|Hitem:", 1, true) then
        local canonical = CANONICAL_ROLL_TYPE[rType:lower()]
        if canonical then
            return UnitName("player"), tonumber(rValue), rLink, canonical
        end
    end

    -- 2.5) Pre-roll intent: "<Player> has selected Need/Greed/Disenchant for:
    -- <Item>" (Warmane + Detailed Loot Information). The actual numeric roll
    -- broadcast that follows is suppressed by the server when the player's
    -- selection can't win (e.g. Need beats every Greed → no point sending
    -- the Greed rolls). Capturing the intent here ensures non-winning
    -- selectors still appear in the item's roll list — as no-value entries.
    -- When the value broadcast DOES follow, OnGroupLootRoll upgrades the
    -- entry rather than duplicating it.
    local selName, selType, selLink = text:match("^(.-) has selected (%a+) for: (.+)$")
    if selName and selType and selLink and selLink:find("|Hitem:", 1, true) then
        local canonical = CANONICAL_ROLL_TYPE[selType:lower()]
        if canonical and selName ~= "" then
            return selName, nil, selLink, canonical
        end
    end
    -- Self variant of "has selected": "You have selected Type for: [Item]".
    selType, selLink = text:match("^You have selected (%a+) for: (.+)$")
    if selType and selLink and selLink:find("|Hitem:", 1, true) then
        local canonical = CANONICAL_ROLL_TYPE[selType:lower()]
        if canonical then
            return UnitName("player"), nil, selLink, canonical
        end
    end

    -- 3) Permissive fallback for "<Player> rolled <N> for <Item> [Type]"
    -- variants. Detects Need/Greed/Disenchant by keyword presence in the
    -- pre-link and post-link spans only — the link's own text is excluded
    -- so items named with substrings like "Need" (e.g., "Needle Encrusted
    -- Scorpion" from heroic ToC) can't false-classify.
    local linkStart, linkEnd = text:find(ITEM_LINK_FULL)
    if linkStart then
        local fbLink = text:sub(linkStart, linkEnd)
        local fbName, fbValue = text:match("^(.-) rolled (%d+) ")
        if fbName and fbValue then
            local before = text:sub(#fbName + 1, linkStart - 1)
            local after  = text:sub(linkEnd + 1)
            local search = before .. " " .. after
            local rollType
            if     search:find("Disenchant", 1, true) then rollType = "Disenchant"
            elseif search:find("Need", 1, true)       then rollType = "Need"
            elseif search:find("Greed", 1, true)      then rollType = "Greed"
            end
            if rollType then
                return fbName, tonumber(fbValue), fbLink, rollType
            end
        end
    end

    -- 4) Pass: standard + auto-pass variants. Check after rolls so a Need/Greed
    -- message with a player name containing "passed" isn't misclassified.
    -- The "|Hitem:" check mirrors step 2: BuildPattern's `(.-)` capture
    -- accepts empty strings and the caller's truthy guard would otherwise
    -- dispatch a degenerate Pass.
    local passName, passLink = text:match(GROUP_PASS)
    if passName and passLink and passLink:find("|Hitem:", 1, true) then
        return passName, nil, passLink, "Pass"
    end
    passName, passLink = text:match(GROUP_PASS_AUTO)
    if passName and passLink and passLink:find("|Hitem:", 1, true) then
        return passName, nil, passLink, "Pass"
    end
    -- Permissive fallback covers localization variants (auto-pass reason
    -- text differs by client gender/locale) and non-standard auto-pass forms.
    -- "Everyone passed on:" / "Nobody won:" are summary messages, not per-
    -- player passes — filter so they don't show up as a roll from a roller
    -- named "Everyone"/"Nobody". The standard formats are caught earlier by
    -- WON_NOBODY in ParseGroupLootWon; this guard is for non-standard variants
    -- that fall through to here.
    local permissiveLink = text:match(ITEM_LINK_FULL)
    if permissiveLink then
        passName, passLink = text:match("^(.-) passed on: (.+)$")
        if passName and passLink then
            local cleaned = passName:gsub("%s+automatically$", "")
            if cleaned ~= "" then passName = cleaned end
            if passName == "Everyone" or passName == "Nobody" then return end
            return passName, nil, permissiveLink, "Pass"
        end
    end
end

local function HandleCombatLog(timestamp, event, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags)
    if event ~= "UNIT_DIED" and event ~= "PARTY_KILL" then return end
    if not LT.currentSession then return end
    if not destGUID or destGUID == "" then return end

    local isNPC = destFlags and bit.band(destFlags, COMBATLOG_OBJECT_TYPE_NPC or 0x800) ~= 0
    if not isNPC then return end

    local npcId = GetNPCID(destGUID)
    if not npcId or npcId == 0 then return end

    -- Only register bosses the bridge knows; everything else is trash (it never
    -- becomes a boss header). The kill is the only deterministic source signal,
    -- and the npcId ALONE uniquely identifies the boss and its instance: you can
    -- only combat-log a kill of a creature physically present in your current
    -- instance, and the build-time bridge pins same-named cross-instance bosses
    -- (Anub'arak, Kael'thas, Lich King) to the correct npcId.
    --
    -- We deliberately do NOT also require entry.instance to string-match
    -- GetInstanceInfo()'s name. Those strings come from different sources
    -- (AtlasLoot/DBM vs. the client) and diverge for several instances
    -- ("Battle for Mount Hyjal" vs "Hyjal Summit", "Tempest Keep" vs "The Eye",
    -- world bosses, ...). Gating on that equality silently dropped clean kills
    -- to Trash in exactly those instances. destName is the real creature name.
    local entry = LootTracker_NPCBridge and LootTracker_NPCBridge[npcId]
    if not entry then return end

    LT:RegisterBossKill(npcId, destName, destGUID, timestamp)
end

local eventFrame = CreateFrame("Frame", "LootTrackerEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:RegisterEvent("START_LOOT_ROLL")
eventFrame:RegisterEvent("CANCEL_LOOT_ROLL")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("CHAT_MSG_MONEY")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("CHAT_MSG_RAID_WARNING")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("INSPECT_TALENT_READY")

-- One-shot delayed bag scan. Bag item data and tooltips are cold immediately
-- after PLAYER_ENTERING_WORLD, so the post-login recovery scan waits a few
-- seconds. Re-arming just resets the timer (last call wins).
local BAG_SCAN_DELAY_SECONDS = 3
local bagScanTimer
local function ScheduleBagScan(delay)
    if not bagScanTimer then bagScanTimer = CreateFrame("Frame") end
    local elapsed = 0
    bagScanTimer:SetScript("OnUpdate", function(frame, dt)
        elapsed = elapsed + dt
        if elapsed < delay then return end
        frame:SetScript("OnUpdate", nil)
        frame:Hide()
        if not LT.currentSession then return end
        local _, updated = LT:ScanBagsForTradeWindow()
        -- Auto-scan is silent unless it actually recovered something, to avoid
        -- chat spam on every login/reload.
        if updated and updated > 0 then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cffffd200LootTracker|r: recovered %d tradeable item%s into the trade window.",
                updated, updated == 1 and "" or "s"))
        end
    end)
    bagScanTimer:Show()
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == "LootTracker" then
            EnsureDB()
            -- Boss attribution is dead without the npcId bridge (Data\NPCBridge.lua).
            -- If it failed to load, say so once at startup: otherwise every rare+
            -- drop silently falls to Trash with no visible reason.
            if not _G.LootTracker_NPCBridge then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff4040LootTracker|r: boss data "
                    .. "(NPCBridge) failed to load - drops will be tracked under "
                    .. "Trash only. Reinstall the addon to restore attribution.")
            end
            LT:RefreshClassCache()
            LT:Fire("AddonLoaded")
            -- Seed thresholds on existing items BEFORE the first ticker fire,
            -- so any historic items that have already passed thresholds don't
            -- chat-flood the user on first reload.
            SeedAlertedThresholds()
            -- Re-kick the ticker whenever a new drop lands, in case it had
            -- stopped after the last live timer expired. StartTradeTimerTicker
            -- is idempotent — safe to call on every receive.
            LT:On("ItemReceived", function() LT:StartTradeTimerTicker() end)
            LT:StartTradeTimerTicker()
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        LT:RefreshClassCache()
        LT:OnZoneChanged()
        -- After a reload/relog/crash-recovery, recover already-tradeable drops
        -- sitting in the bags whose trade-window entry was lost (WoW only flushes
        -- SavedVariables on clean logout/reload). Gated to PLAYER_ENTERING_WORLD
        -- (login/reload/instance entry, not every sub-zone) and to being in an
        -- instance; the scan is idempotent, so a re-fire is harmless.
        if event == "PLAYER_ENTERING_WORLD" and LT.currentSession then
            ScheduleBagScan(BAG_SCAN_DELAY_SECONDS)
        end
    elseif event == "PLAYER_LOGOUT" then
        if LT.currentSession then LT.currentSession.endedAt = Now() end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        LT:RefreshClassCache()
    elseif event == "INSPECT_TALENT_READY" then
        -- Inspect cache just updated for some player; refresh UI so any roll
        -- entries whose equipped slot was nil get re-queried by the renderer.
        LT:Fire("InspectReady")
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        HandleCombatLog(...)
    elseif event == "START_LOOT_ROLL" then
        local rollID, duration = ...
        LT:OnStartLootRoll(rollID, duration)
    elseif event == "CANCEL_LOOT_ROLL" then
        local rollID = ...
        LT:OnCancelLootRoll(rollID)
    elseif event == "CHAT_MSG_LOOT" then
        local text = ...
        local recipient, link, count, pushed = ParseLoot(text)
        if recipient and link then
            LogDebug("loot in:  " .. text)
            LogDebug("loot out: recipient=" .. tostring(recipient)
                .. " link=" .. tostring(link) .. " pushed=" .. tostring(pushed))
            LT:OnLootReceived(recipient, link, count, pushed)
        else
            -- "Won" announcements first — they share CHAT_MSG_LOOT with the
            -- "rolled" messages but carry the final recipient, not a roll
            -- result. Checking won before roll avoids the "X won: [Item]"
            -- text accidentally matching a permissive roll pattern.
            local wonRecipient, wonLink = ParseGroupLootWon(text)
            if wonLink then
                LogDebug("won in:   " .. text)
                LogDebug("won out:  recipient=" .. tostring(wonRecipient)
                    .. " link=" .. tostring(wonLink))
                LT:OnGroupLootWon(wonRecipient, wonLink)
            else
                -- rollValue is nil for Pass; don't gate the dispatch on it or
                -- every Pass message would be silently dropped.
                local rollName, rollValue, rollLink, rollType = ParseGroupLootRoll(text)
                LogDebug("roll in:  " .. text)
                LogDebug("roll out: name=" .. tostring(rollName)
                    .. " val=" .. tostring(rollValue)
                    .. " type=" .. tostring(rollType)
                    .. " link=" .. tostring(rollLink))
                if rollName and rollLink then
                    LT:OnGroupLootRoll(rollName, rollValue, rollLink, rollType)
                end
            end
        end
    elseif event == "CHAT_MSG_MONEY" then
        local text = ...
        local copper = ParseMoney(text)
        if copper > 0 then
            LogDebug("money in: " .. tostring(text) .. " -> " .. copper .. "c")
            LT:OnMoneyReceived(copper)
        end
    elseif event == "CHAT_MSG_RAID_WARNING" then
        -- Master-loot manual rolls: the loot master raid-warns an item
        -- ("/rw [Item] roll"). The first item link in the warning opens a
        -- roll window that subsequent /roll system messages attach to.
        local text = ...
        local link = text and text:match(ITEM_LINK_FULL)
        if link then
            LT:OnManualRollAnnounce(link)
        end
    elseif event == "CHAT_MSG_SYSTEM" then
        local text = ...
        -- Dungeon/BG completion coin reward ("Received <amount>") arrives here on
        -- some servers (others use CHAT_MSG_MONEY, handled above). ParseMoney is
        -- >0 only for a real coin line, so this no-ops on the roll/reset messages.
        local copper = ParseMoney(text)
        if copper > 0 then
            LogDebug("money in: " .. tostring(text) .. " -> " .. copper .. "c")
            LT:OnMoneyReceived(copper)
            return
        end
        -- Master-loot manual roll result: "<Player> rolls <N> (<min>-<max>)".
        -- Anchored to the item from the most recent raid-warning announcement
        -- (see OnManualRoll); link-less, so it can't be attributed on its own.
        local rollerName, rollValue, rollMin, rollMax = text:match(RANDOM_ROLL)
        if rollerName then
            LT:OnManualRoll(StripRealm(rollerName), tonumber(rollValue),
                tonumber(rollMin), tonumber(rollMax))
        else
            -- "<Instance> has been reset." — flag the instance so the next
            -- OnZoneChanged into it starts a fresh session instead of rejoining
            -- the recent one via FindRecentMatchingSession. Assumes the system
            -- message's instance name matches GetInstanceInfo()'s value
            -- case-insensitively (true for enUS WotLK 3.3.5; some private
            -- servers append difficulty suffixes like " (10)" which would
            -- break the match — out of scope per the addon's enUS policy).
            local resetName = text:match(INSTANCE_RESET)
            if resetName then
                LT.resetInstanceNames[resetName:lower()] = true
            end
        end
    end
end)

-- Self-test for the pure attribution rule (Task 3). The main /lt slash handler
-- lives in UI.lua and is not modified here, so the test gets its own command:
--   /lttest  -> runs LT:RunSelfTest() (5 PASS lines + ALL PASS expected).
SLASH_LOOTTRACKERTEST1 = "/lttest"
SlashCmdList["LOOTTRACKERTEST"] = function()
    LT:RunSelfTest()
end
