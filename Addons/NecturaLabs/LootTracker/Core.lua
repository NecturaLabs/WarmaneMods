local LT = {}
_G.LootTracker = LT

local LOOT_WINDOW_SECONDS         = 600
local SESSION_REENTRY_SECONDS     = 1800
local CANDIDATE_WINDOW_SECONDS    = 90
local CANDIDATE_BUFFER_LIMIT      = 12
local LOOT_SESSION_GRACE_SECONDS  = 30
local LOOT_SESSION_QUEUE_LIMIT    = 8
-- Tight window for promoting a recent UNIT_DIED candidate when the LOOT_OPENED
-- target isn't a valid dead NPC (autoloot / click-loot without target). Short
-- enough that walking to an unrelated chest after a kill still falls through
-- to the synthetic "Chest" path, long enough to absorb autoloot latency.
local LOOT_OPEN_FALLBACK_WINDOW   = 20
local TRASH_BOSS_NAME             = "Trash"

local TRADE_WINDOW_SECONDS        = 7200   -- WotLK 3.3.5 BoP trade window
local TRADE_TIMER_TICK_SECONDS    = 30     -- minute-granularity display
-- Thresholds (seconds remaining) at which a chat alert is emitted.
-- Order matters: higher thresholds fire first as time ticks down.
local TRADE_ALERT_THRESHOLDS = {
    { key = "30m",     atOrBelow = 1800, label = "30m left to trade" },
    { key = "10m",     atOrBelow =  600, label = "10m left to trade" },
    { key = "1m",      atOrBelow =   60, label = "1m left to trade"  },
    { key = "expired", atOrBelow =    0, label = "trade window expired" },
}

local nextSyntheticGuid = 0

LT.classCache       = {}
LT.currentSession   = nil
LT.lastBossKill     = nil   -- { session, bossIndex, time, guid }
LT.candidateDeaths  = {}    -- recent unattributed NPC deaths
LT.lootSessions     = {}    -- queue of { guid, npcId, name, time, items } from recent LOOT_OPENED snapshots
LT.activeGroupRolls   = {}  -- [rollID] = { session, bossIndex, itemIndex, itemId, itemLink, startedAt, expiresAt }
LT.manualRoll         = nil  -- master-loot: { itemId, itemLink, expiresAt } — item currently being /roll'd on
LT.resetInstanceNames = {}  -- [instanceName:lower()] = true; consumed on the next entry into that instance
LT.listeners          = {}

local GROUP_ROLL_GRACE_SECONDS = 30  -- keep rollID entries around this long after CANCEL for late chat
-- Master-loot manual rolls: how long an /rw-announced item collects /roll
-- results before the window expires (a fresh announcement also supersedes it).
local MANUAL_ROLL_WINDOW_SECONDS = 120

-- Forward declaration: FindGroupRollContext is defined later (in the group-loot
-- section) but is also called by OnLootReceived (defined earlier in the file).
-- Without this, the local would not yet exist at OnLootReceived's definition
-- and the closure would bind to a global nil instead.
local FindGroupRollContext

-- Forward declaration: ResolveInferredBoss is defined later (after
-- EnsureBossRegistered, with which it shares the synthetic-guid contract)
-- but is also called by EnsureBossContext, defined earlier. Same reasoning
-- as FindGroupRollContext above.
local ResolveInferredBoss

-- Forward declaration: EnsureBossRegistered is defined later but called by
-- EnsureBossContext (defined earlier, in its snapshot-with-npcId branch).
-- Without this, that reference would bind to a nil global and error the first
-- time the branch is hit. Same reasoning as ResolveInferredBoss above.
local EnsureBossRegistered

-- Single source of truth for "wipe everything tied to the current run." Four
-- sites need this (zone exit, zone re-enter into new session, DeleteSession
-- of the current one, Reset) and previously each site enumerated the fields
-- inline — easy to forget one when a new field is added (as happened when
-- activeGroupRolls was introduced).
local function ClearTransientState(self)
    self.lastBossKill     = nil
    self.candidateDeaths  = {}
    self.lootSessions     = {}
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

local LOOT_SELF_SINGLE   = BuildPattern(LOOT_ITEM_SELF           or "You receive loot: %s.")
local LOOT_SELF_MULTI    = BuildPattern(LOOT_ITEM_SELF_MULTIPLE  or "You receive loot: %sx%d.")
local LOOT_OTHER_SINGLE  = BuildPattern(LOOT_ITEM                or "%s receives loot: %s.")
local LOOT_OTHER_MULTI   = BuildPattern(LOOT_ITEM_MULTIPLE       or "%s receives loot: %sx%d.")
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

local function GetNPCID(guid)
    if not guid then return nil end
    local entry = guid:match("^0x[fF]13.%x%x%x%x(%x%x%x%x)")
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
-- when players rolled before the winner received it. Those placeholders have
-- no recipient. On the first actual receive, fill in the recipient instead of
-- double-incrementing the drop count. A *true* re-drop of the same item (same
-- boss, recipient already set) does increment count, as before.
local function FillRecipientOrIncrement(existing, recipient, count)
    if not existing.recipient then
        existing.recipient = recipient
        existing.count = count or existing.count or 1
    else
        existing.count = (existing.count or 1) + (count or 1)
    end
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
        if n and fileName then cache[n] = fileName end
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
    LootTrackerDB.tradeTimers = LootTrackerDB.tradeTimers or {}
    if LootTrackerDB.tradeTimers.enabled        == nil then LootTrackerDB.tradeTimers.enabled        = true  end
    if LootTrackerDB.tradeTimers.alerts         == nil then LootTrackerDB.tradeTimers.alerts         = true  end
    if LootTrackerDB.tradeTimers.panelCollapsed == nil then LootTrackerDB.tradeTimers.panelCollapsed = false end
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
-- Candidate buffer + boss promotion
-- ---------------------------------------------------------------------------

-- Dedupe by guid: UNIT_DIED and PARTY_KILL both fire for the same kill, and
-- the buffer is GUID-keyed for downstream pop/match. Without the dedupe a
-- stale duplicate could remain after the first copy is popped, then later
-- get promoted by OnLootReceived fallback for an unrelated nearby loot
-- event and mis-attribute it.
local function PushCandidate(guid, npcId, name)
    for i = 1, #LT.candidateDeaths do
        if LT.candidateDeaths[i].guid == guid then return end
    end
    table.insert(LT.candidateDeaths, {
        guid = guid, npcId = npcId, name = name, time = Now(),
    })
    while #LT.candidateDeaths > CANDIDATE_BUFFER_LIMIT do
        table.remove(LT.candidateDeaths, 1)
    end
end

-- `window` defaults to CANDIDATE_WINDOW_SECONDS. Callers needing a tighter
-- gate (e.g., OnLootOpened's autoloot fallback, where chest-opens minutes
-- after a kill must NOT pull the dead mob from the buffer) pass a shorter
-- window explicitly.
local function PopRecentCandidate(window)
    window = window or CANDIDATE_WINDOW_SECONDS
    local now = Now()
    for i = #LT.candidateDeaths, 1, -1 do
        local c = LT.candidateDeaths[i]
        if now - c.time <= window then
            table.remove(LT.candidateDeaths, i)
            return c
        end
    end
end

-- Point lastBossKill at an already-registered boss entry. OnBossKill is the
-- only other writer of lastBossKill, but the EnsureBossRegistered /
-- ResolveInferredBoss paths can hand back an EXISTING entry without going
-- through it (guid match, or npcId match against a prior inferred/real entry).
-- Those paths must promote explicitly or lastBossKill silently stays stale —
-- or nil, when transient state was cleared (zone exit) but the session's boss
-- list survived — and EnsureBossContext's callers crash indexing it. Returns
-- true if the boss was found in the current session and promoted.
local function PromoteBossToLBK(self, boss)
    local session = self.currentSession
    if not (session and boss) then return false end
    for i = #session.bosses, 1, -1 do
        if session.bosses[i] == boss then
            self.lastBossKill = {
                session   = session,
                bossIndex = i,
                time      = boss.killedAt,
                guid      = boss.guid,
            }
            return true
        end
    end
    return false
end

-- Group loot, and master-loot raids where the announcing player isn't the
-- local one, can fire CHAT_MSG_LOOT roll/announce messages BEFORE the player
-- has opened any loot window — meaning OnLootOpened (and its DB shortcut)
-- never ran. Promote the right candidate so the roll/announce has a boss
-- entry to attach to. Returns true if there's a valid boss context after the
-- call, false otherwise. On a true return, self.lastBossKill is guaranteed
-- non-nil and pointing at the resolved boss — callers rely on this.
--
-- Disambiguation priority (when itemId is known):
--   1. a recent LOOT_OPENED snapshot contains this item (direct observation
--      of the actual source — required for chests with group-loot, where
--      rolls fire before any boss could otherwise be registered)
--   2. lastBossKill, if its DB loot table contains this item
--   3. a candidate whose DB loot table contains this item (handles back-to-
--      back boss kills where lastBossKill is the previous boss)
--   4. ResolveInferredBoss: the item's DB entry pins it to a unique source
--   5. lastBossKill, regardless of item match (best guess for DB miss)
local function EnsureBossContext(self, itemId)
    local now = Now()
    local lbk = self.lastBossKill
    local lbkValid = lbk and now - lbk.time <= LOOT_WINDOW_SECONDS

    -- Step 1: a recent LOOT_OPENED snapshot contains this item. Chests with
    -- group-loot live or die on this: OnLootOpened pushes the chest's items
    -- into the snapshot queue under a synthetic "container:N" guid, but the
    -- "Chest" boss entry itself is only lazy-created by OnLootReceived's
    -- snapshot-claim fallback when the winner's loot message arrives. Every
    -- START_LOOT_ROLL and roll-chat message fires BEFORE that — without this
    -- step, EnsureBossContext would skip to step 5 (lbk fallback) and
    -- mis-attribute the rolls to whatever was last killed, or return false
    -- and silently drop them. Iterate oldest-first to match ClaimLootSession-
    -- ByItem's ordering for the rare multi-snapshot-with-same-item case.
    if itemId then
        for i = 1, #LT.lootSessions do
            local s = LT.lootSessions[i]
            if now - s.time <= LOOT_SESSION_GRACE_SECONDS
                and (s.items[itemId] or 0) > 0
            then
                local bossIndex, existing = FindBossByGuid(self.currentSession, s.guid)
                if existing then
                    -- Promote to lastBossKill so the caller's lbk-derived
                    -- lookup lands on the snapshot's source rather than
                    -- whatever was last killed. Steps 3-4 update lbk
                    -- implicitly via OnBossKill when they create a new
                    -- entry; the existing-boss branch here has to do it
                    -- explicitly or lbk silently stays stale.
                    self.lastBossKill = {
                        session   = self.currentSession,
                        bossIndex = bossIndex,
                        time      = existing.killedAt,
                        guid      = existing.guid,
                    }
                elseif s.npcId then
                    -- EnsureBossRegistered may return an existing entry without
                    -- touching lastBossKill; promote it ourselves so the
                    -- contract (true ⟹ valid lastBossKill) holds.
                    if not PromoteBossToLBK(self,
                        EnsureBossRegistered(self, s.npcId, s.name, s.time, s.guid))
                    then
                        return false
                    end
                else
                    self:OnBossKill(nil, s.name, s.time, s.guid)
                    if not self.lastBossKill then return false end
                end
                return true
            end
        end
    end

    -- Step 2: lastBossKill's boss has this item in its DB loot? Use it.
    if lbkValid and itemId and LootTracker_Bosses then
        local boss = lbk.session.bosses[lbk.bossIndex]
        local entry = boss and boss.npcId and LootTracker_Bosses[boss.npcId]
        if entry and entry.loot and entry.loot[itemId] then
            return true
        end
    end

    -- Step 3: candidate whose DB loot contains this item — handles the
    -- "kill boss 1, walk to boss 2, kill boss 2, rolls fire before LOOT_OPENED"
    -- case so boss 2's roll doesn't get mis-attributed to boss 1.
    if itemId and LootTracker_Bosses then
        for i = #LT.candidateDeaths, 1, -1 do
            local c = LT.candidateDeaths[i]
            if now - c.time <= CANDIDATE_WINDOW_SECONDS then
                local entry = c.npcId and LootTracker_Bosses[c.npcId]
                if entry and entry.loot and entry.loot[itemId] then
                    table.remove(LT.candidateDeaths, i)
                    self:OnBossKill(c.npcId, entry.name or c.name, c.time, c.guid)
                    return true
                end
            end
        end
    end

    -- Step 4: infer the boss from the item's DB loot table. The item id
    -- often pins exactly one source; using it BEFORE the lastBossKill
    -- best-guess prevents the "kill boss A, then UNIT_DIED is missed for
    -- boss B, items from B's group-loot rolls attach to A via step 5"
    -- mis-attribution. Returns nil for items not in any DB loot table,
    -- which falls through to step 5.
    -- ResolveInferredBoss returns an existing entry without promoting it (and
    -- after a zone-exit ClearTransientState, lastBossKill is nil while the
    -- inferred boss survives) — promote so the true return honors the contract.
    if PromoteBossToLBK(self, ResolveInferredBoss(self, itemId)) then
        return true
    end

    -- Step 5: fall back to lastBossKill (best guess for non-DB content
    -- and items missing from the DB loot tables).
    if lbkValid then return true end

    return false
end

-- Compose the synthetic guid used by ResolveInferredBoss to register a
-- boss before its real UNIT_DIED GUID is known. Owned here because
-- EnsureBossRegistered keys the synthetic→real upgrade off this exact
-- format; centralising it keeps the contract in one place.
local function MakeInferredGuid(npcId)
    return "inferred:" .. tostring(npcId)
end

-- Register a kill only if no boss entry already exists for this guid OR
-- npcId. Used by every eager-registration path: HandleCombatLog UNIT_DIED,
-- OnLootOpened's target/candidate/per-slot paths, and ResolveInferredBoss.
--
-- Two-step dedup:
--   1. Guid match: same-guid registration is a no-op. Trivial case.
--   2. NpcId match (when npcId is non-nil — Trash/Chest entries use nil):
--      an inferred registration with a synthetic "inferred:<npcId>" guid
--      may have created the entry before the real GUID arrived. If so,
--      upgrade the stored guid (and lastBossKill if it pointed there) to
--      the real one so future FindBossByGuid lookups by real guid match.
--
-- Returns the existing or freshly-registered boss entry, or nil if no
-- session is active.
-- Assigned (not declared) — see forward declaration near the top of the file.
EnsureBossRegistered = function(self, npcId, name, killTime, guid)
    if not self.currentSession then return nil end
    local _, existing = FindBossByGuid(self.currentSession, guid)
    if existing then return existing end
    -- Side effect: this branch may mutate an existing entry's `guid` (and
    -- LT.lastBossKill.guid) from synthetic to real. Callers don't need to
    -- handle that — the upgrade is invisible — but it's a side effect to
    -- be aware of when reasoning about boss-entry identity over time.
    if npcId then
        local inferredGuid = MakeInferredGuid(npcId)
        for _, b in ipairs(self.currentSession.bosses) do
            if b.npcId == npcId then
                if b.guid == inferredGuid then
                    b.guid = guid
                    if self.lastBossKill and self.lastBossKill.guid == inferredGuid then
                        self.lastBossKill.guid = guid
                    end
                end
                return b
            end
        end
    end
    self:OnBossKill(npcId, name, killTime, guid)
    return self.currentSession.bosses[#self.currentSession.bosses]
end

-- Reverse index from itemId → list of {npcId, dbEntry} pairs for bosses
-- whose DB loot table contains this item. Built lazily on first lookup.
-- Walk cost: O(#bosses × #items_per_boss) ≈ a few thousand ops, one-time.
local ItemToBosses

local function BuildItemToBosses()
    ItemToBosses = {}
    if not LootTracker_Bosses then return end
    for npcId, entry in pairs(LootTracker_Bosses) do
        if entry.loot then
            for itemId in pairs(entry.loot) do
                local list = ItemToBosses[itemId]
                if not list then
                    list = {}
                    ItemToBosses[itemId] = list
                end
                list[#list + 1] = { npcId = npcId, entry = entry }
            end
        end
    end
end

-- Inferred-boss fallback: identify the source from the item's own DB entry
-- when no other path knows it. Used when UNIT_DIED missed, the player
-- didn't loot the corpse, and the candidate buffer evicted the kill before
-- the loot message arrived — none of which leave anything for the primary
-- DB walk or the snapshot queue to match against.
--
-- Picks the unique boss for single-match items (the common case for most
-- gear) or, on ambiguity, the boss whose DB `instance` field matches the
-- current session's instance name. Returns nil if neither applies —
-- callers should fall through to Trash.
--
-- Dedup against existing same-npcId entries (real or prior inferred) is
-- handled by EnsureBossRegistered, so we don't pre-scan here.
-- Assigned (not declared) — see forward declaration above.
ResolveInferredBoss = function(self, itemId)
    if not itemId or not self.currentSession then return nil end
    if not ItemToBosses then BuildItemToBosses() end
    local matches = ItemToBosses[itemId]
    if not matches then return nil end

    local sessName = self.currentSession.instanceName
    local picked
    for i = 1, #matches do
        if matches[i].entry.instance == sessName then
            picked = matches[i]
            break
        end
    end
    if not picked and #matches == 1 then
        picked = matches[1]
    end
    if not picked then return nil end

    return EnsureBossRegistered(self, picked.npcId, picked.entry.name,
        Now(), MakeInferredGuid(picked.npcId))
end

function LT:OnBossKill(npcId, npcName, killTime, guid)
    if not self.currentSession then return end
    local entry = {
        npcId    = npcId,
        name     = npcName,
        guid     = guid,
        killedAt = killTime or Now(),
        items    = {},
    }
    table.insert(self.currentSession.bosses, entry)
    self.lastBossKill = {
        session   = self.currentSession,
        bossIndex = #self.currentSession.bosses,
        time      = entry.killedAt,
        guid      = guid,
    }
    -- Discard older unattributed NPC deaths — they predated a confirmed boss
    -- and are now trash by elimination. Skipped for non-NPC sources (chests /
    -- herbs / ore): opening a container doesn't say anything about whether
    -- earlier unattributed deaths were bosses or trash.
    if npcId then
        local cutoff = entry.killedAt
        for i = #self.candidateDeaths, 1, -1 do
            if self.candidateDeaths[i].time <= cutoff then
                table.remove(self.candidateDeaths, i)
            end
        end
    end
    self:Fire("BossKilled", self.currentSession, entry)
end

-- ---------------------------------------------------------------------------
-- Loot opened (corpse)
-- ---------------------------------------------------------------------------

-- Lazily create (or return) the single per-session "Trash" entry. All non-DB
-- NPC sources in a session route here, regardless of drop quality. The
-- sentinel guid encodes the session id so a stale Trash entry from a previous
-- session can't be matched accidentally by FindBossByGuid.
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

-- Item-class classification. Materials = any item whose itemSubType is
-- "Enchanting" — catches dusts, essences, shards, crystals across all
-- expansions without a hardcoded list. Returns false on cold cache; the
-- caller routes uncategorised items normally.
local function IsMaterial(itemLink)
    if not itemLink then return false end
    local _, _, _, _, _, _, itemSubType = GetItemInfo(itemLink)
    return itemSubType == "Enchanting"
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

-- Snapshot the loot window's contents at open so OnLootReceived can match
-- each incoming CHAT_MSG_LOOT back to the source corpse / chest. WoW 3.3.5
-- exposes GetLootSourceInfo(slot), which returns the exact source GUID(s)
-- per loot slot — independent of the player's target or autoloot. We bucket
-- items by that GUID so AOE-loot of mixed corpses, autoloot without target,
-- and /reload-clobbered candidate buffers all attribute correctly.
--
-- Bucket key resolution per slot's source GUID:
--   1. NPC GUID in LootTracker_Bosses           → key = the GUID itself;
--                                                 eagerly register the boss.
--   2. NPC GUID NOT in LootTracker_Bosses       → key = "trash:" .. session.id;
--                                                 routes to the single per-
--                                                 session Trash entry.
--   3a. Non-NPC GUID present (GameObject:
--       chest/herb/ore/fishing node, or an
--       inventory container like a Dungeon
--       Finder satchel / Frozen Orb bag)        → key = "container:" .. sourceGuid;
--                                                 synthetic Chest bucket. We
--                                                 deliberately do NOT fall
--                                                 through to lastBossKill
--                                                 here — that mis-attributed
--                                                 lootbag drops to the last
--                                                 boss killed (e.g. Frozen Orb
--                                                 bag in Ramparts → Kargath).
--   3b. Missing/empty GUID
--      (private-server quirk)                   → fall through to legacy
--                                                 target / candidate /
--                                                 lastBossKill / synthetic
--                                                 "Chest" chain.
function LT:OnLootOpened()
    if not self.currentSession then return end
    local session = self.currentSession
    local trashKey = "trash:" .. tostring(session.id)

    -- Build legacy-chain bucket lazily — only created if at least one slot
    -- needs it (GameObject loot, GetLootSourceInfo miss, etc.). Mirrors the
    -- pre-refactor logic exactly so existing behaviour is preserved for
    -- containers and addon-load-mid-fight scenarios.
    local legacyBucket
    local function getLegacyBucket()
        if legacyBucket then return legacyBucket end

        local guid, npcId, name
        local targetGuid = UnitGUID("target")
        if targetGuid and targetGuid ~= "" and UnitIsDead("target") then
            local id = GetNPCID(targetGuid)
            if id and id ~= 0 then
                guid  = targetGuid
                npcId = id
                local dbEntry = LootTracker_Bosses and LootTracker_Bosses[id]
                if dbEntry then
                    EnsureBossRegistered(self, id, dbEntry.name, Now(), targetGuid)
                    name = dbEntry.name
                else
                    -- Non-DB NPC via target: route to Trash bucket key.
                    guid = trashKey
                    npcId = nil
                    name = TRASH_BOSS_NAME
                end
            end
        end

        if not guid then
            local c = PopRecentCandidate(LOOT_OPEN_FALLBACK_WINDOW)
            if c then
                local dbEntry = LootTracker_Bosses and LootTracker_Bosses[c.npcId]
                if dbEntry then
                    guid  = c.guid
                    npcId = c.npcId
                    name  = dbEntry.name
                    EnsureBossRegistered(self, c.npcId, dbEntry.name, c.time, c.guid)
                else
                    -- Non-DB candidate: Trash.
                    guid = trashKey
                    npcId = nil
                    name = TRASH_BOSS_NAME
                end
            end
        end

        if not guid then
            local lbk = self.lastBossKill
            if lbk and Now() - lbk.time <= LOOT_OPEN_FALLBACK_WINDOW then
                local boss = lbk.session.bosses[lbk.bossIndex]
                if boss then
                    guid  = lbk.guid
                    npcId = boss.npcId
                    name  = boss.name or "Unknown"
                end
            end
        end

        if not guid then
            -- Synthetic-counter form (e.g. "container:5") — used only by the
            -- legacy fallback when no source GUID was available. The per-slot
            -- branch above uses "container:" .. sourceGuid (always 0x-prefixed
            -- hex), so the two forms share the "container:" prefix without
            -- colliding. Treat both as opaque keys.
            nextSyntheticGuid = nextSyntheticGuid + 1
            guid = "container:" .. nextSyntheticGuid
            name = "Chest"
        end

        legacyBucket = { guid = guid, npcId = npcId, name = name, items = {} }
        return legacyBucket
    end

    local buckets = {}

    local n = GetNumLootItems() or 0
    for slot = 1, n do
        local link = GetLootSlotLink(slot)
        local id = link and GetItemIDFromLink(link)
        if id then
            local bucketKey, bucketRec

            local sourceGuid
            if GetLootSourceInfo then
                sourceGuid = select(1, GetLootSourceInfo(slot))
            end

            if sourceGuid and sourceGuid ~= "" then
                local npcId = GetNPCID(sourceGuid)
                if npcId and npcId ~= 0 then
                    local dbEntry = LootTracker_Bosses and LootTracker_Bosses[npcId]
                    if dbEntry then
                        -- Eager-register the boss the moment we see its GUID
                        -- in a loot slot. This runs BEFORE the currency /
                        -- material filter below, so a DB-known boss whose
                        -- entire loot window is emblems still gets a Bosses-
                        -- tab header (the kill happened; currencies aggregate
                        -- separately). Symmetric with the UNIT_DIED eager
                        -- registration in HandleCombatLog — covers the case
                        -- where UNIT_DIED was missed (combat-log range,
                        -- /reload, addon-load-mid-fight).
                        bucketKey = sourceGuid
                        bucketRec = buckets[bucketKey]
                        if not bucketRec then
                            EnsureBossRegistered(self, npcId, dbEntry.name, Now(), sourceGuid)
                            bucketRec = {
                                guid = sourceGuid,
                                npcId = npcId,
                                name = dbEntry.name,
                                items = {},
                            }
                            buckets[bucketKey] = bucketRec
                        end
                    else
                        -- NPC not in DB → Trash.
                        bucketKey = trashKey
                        bucketRec = buckets[bucketKey]
                        if not bucketRec then
                            bucketRec = {
                                guid = trashKey,
                                npcId = nil,
                                name = TRASH_BOSS_NAME,
                                items = {},
                            }
                            buckets[bucketKey] = bucketRec
                        end
                    end
                else
                    -- Non-NPC sourceGuid: GameObject (chest, herb, ore, fishing)
                    -- OR an inventory container (Dungeon Finder satchel, Frozen
                    -- Orb bag, etc.). We have a real source GUID and we know
                    -- it's not a corpse — falling back to the lastBossKill /
                    -- candidate heuristic here would mis-attribute lootbag
                    -- drops to the last boss killed (e.g. a Frozen Orb bag
                    -- opened in Ramparts → Kargath). Route directly to a
                    -- synthetic Chest bucket keyed by this source GUID so all
                    -- slots from the same source aggregate together.
                    bucketKey = "container:" .. sourceGuid
                    bucketRec = buckets[bucketKey]
                    if not bucketRec then
                        bucketRec = {
                            guid  = bucketKey,
                            npcId = nil,
                            name  = "Chest",
                            items = {},
                        }
                        buckets[bucketKey] = bucketRec
                    end
                end
            else
                -- GetLootSourceInfo missing or empty — fall back to legacy
                -- chain (target / candidate / lastBossKill / synthetic Chest).
                -- The `buckets[bucketKey] or lb` guards the case where multiple
                -- legacy-fallback slots in the same loot window resolve to the
                -- same guid (e.g. all to trashKey) so the lazily-built bucket
                -- isn't overwritten on subsequent slots.
                local lb = getLegacyBucket()
                bucketKey = lb.guid
                bucketRec = buckets[bucketKey] or lb
                buckets[bucketKey] = bucketRec
            end

            -- Skip currencies, materials, and sub-rare drops at the snapshot
            -- layer too. The classification gates in OnLootReceived return
            -- before claiming from the snapshot, so leaving these in the
            -- bucket would just sit there until the 30s grace expires —
            -- and worse, a bucket holding one rare + one green would stay
            -- alive (because items still has entries) past the rare claim.
            -- Materials with a cold GetItemInfo cache leak through harmlessly
            -- — they're already handled by the gate on OnLootReceived's side.
            local q = GetItemQualityFromLink(link)
            if not IsCurrency(id)
                and not IsMaterial(link)
                and not (q and q < 3)
            then
                bucketRec.items[id] = (bucketRec.items[id] or 0) + 1
            end
        end
    end

    local now = Now()
    for _, bucket in pairs(buckets) do
        -- Skip buckets whose items were entirely filtered out by the
        -- currency/material classification — pushing them would create
        -- snapshot entries that can never claim anything.
        if next(bucket.items) then
            table.insert(self.lootSessions, {
                guid  = bucket.guid,
                npcId = bucket.npcId,
                name  = bucket.name,
                time  = now,
                items = bucket.items,
            })
        end
    end
    while #self.lootSessions > LOOT_SESSION_QUEUE_LIMIT do
        table.remove(self.lootSessions, 1)
    end
end

-- ---------------------------------------------------------------------------
-- Loot received
-- ---------------------------------------------------------------------------

-- Pop a candidate by exact GUID. Unlike PopRecentCandidate, this intentionally
-- ignores CANDIDATE_WINDOW_SECONDS: a LOOT_OPENED GUID match is direct proof
-- of which corpse we're looting, so the candidate's age is irrelevant. The
-- buffer is size-capped (CANDIDATE_BUFFER_LIMIT) so it can't grow unbounded.
local function PopCandidateByGUID(guid)
    for i = #LT.candidateDeaths, 1, -1 do
        local c = LT.candidateDeaths[i]
        if c.guid == guid then
            table.remove(LT.candidateDeaths, i)
            return c
        end
    end
end

-- Claim the oldest non-expired loot session whose snapshot still has this
-- item. Oldest-first matches CHAT_MSG_LOOT arrival order: messages from the
-- first corpse's window arrive before the second's, even when the player
-- opened both in quick succession. Decrements the item count so the same
-- session won't double-claim a second message for the same item; drops the
-- entry from the queue once every snapshot slot has been claimed.
local function ClaimLootSessionByItem(itemId)
    local now = Now()
    for i = 1, #LT.lootSessions do
        local s = LT.lootSessions[i]
        if now - s.time <= LOOT_SESSION_GRACE_SECONDS
            and (s.items[itemId] or 0) > 0
        then
            s.items[itemId] = s.items[itemId] - 1
            if s.items[itemId] == 0 then
                s.items[itemId] = nil
                if not next(s.items) then table.remove(LT.lootSessions, i) end
            end
            return s
        end
    end
end

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

function LT:OnLootReceived(recipient, itemLink, count)
    if not self.currentSession then return end
    local itemId = GetItemIDFromLink(itemLink)
    if not itemId then return end

    -- Master-loot manual rolls: assignment of the announced item ends its
    -- roll. Close the window now so a later unrelated /roll within the 120s
    -- timeout can't be mis-recorded as a Need roll on an already-resolved
    -- item. The item's existing roll entry (built during the rolling phase)
    -- and recipient fill-in below are unaffected.
    if self.manualRoll and self.manualRoll.itemId == itemId then
        self.manualRoll = nil
    end

    local quality = GetItemQualityFromLink(itemLink)
    -- Drop grey/white drops entirely — the addon tracks rolled loot, and
    -- vendor trash would just pollute the items list and force extra UI
    -- filtering downstream. Unknown-quality items pass through (we can't
    -- distinguish "junk" from "parse failure"); the DB walk below also
    -- only succeeds when the item is in a boss's loot table, which never
    -- includes vendor trash, so the practical effect is the same.
    if quality and quality < 2 then return end

    -- Classification gate: currencies and materials never enter boss.items.
    -- They aggregate per-session into their own buckets so the Bosses tab
    -- stays focused on rolled gear. Run BEFORE the rollID/snapshot/DB walks
    -- — those paths assume boss attribution and would otherwise create
    -- placeholder boss entries for emblems / dust / shards.
    --
    -- Personal-loot only: the Currencies/Materials tabs track what YOU earned,
    -- not the whole group's emblem/dust haul. ParseLoot sets recipient to
    -- UnitName("player") for your own "You receive loot:" line and to the other
    -- player's name for "X receives loot:", so this comparison cleanly tells the
    -- two apart. A non-personal currency/material is still classified here (so it
    -- returns and never reaches the boss-attribution walks below) — it just
    -- isn't recorded.
    local isPersonalLoot = IsLocalPlayer(recipient)
    if IsCurrency(itemId) then
        if isPersonalLoot then
            local entry = RecordCurrency(self.currentSession, itemId, itemLink, recipient, count)
            self:Fire("CurrencyReceived", self.currentSession, entry)
        end
        return
    end
    if IsMaterial(itemLink) then
        if isPersonalLoot then
            local entry = RecordMaterial(self.currentSession, itemId, itemLink, recipient, count)
            self:Fire("MaterialReceived", self.currentSession, entry)
        end
        return
    end

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
            -- is nil here and FillRecipientOrIncrement takes the "set" branch.
            -- The defensive guard remains in case a previous drop's ctx was
            -- somehow re-bound (shouldn't happen with per-drop entries, but
            -- cheap insurance).
            if not item.recipient then
                FillRecipientOrIncrement(item, recipient, count)
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
        local _, existing = FindItemInBoss(trash, itemId)
        if existing then
            FillRecipientOrIncrement(existing, recipient, count)
        else
            existing = {
                itemId    = itemId,
                itemLink  = itemLink,
                recipient = recipient,
                count     = count or 1,
                quality   = quality,
                droppedAt = Now(),
                rolls     = {},
            }
            table.insert(trash.items, existing)
        end
        MaybeAddSyntheticRoll(self, existing, recipient)
        self:Fire("ItemReceived", self.currentSession, trash, existing)
        return
    end

    -- Snapshot-first attribution: GetLootSourceInfo gave OnLootOpened a
    -- definitive source GUID. If a fresh snapshot bucketed this item under
    -- a specific source (registered DB boss or Trash sentinel), use that —
    -- it's direct observation and wins over the DB walk, which can wrongly
    -- attribute when the DB lists the item under a different boss than
    -- the one that actually dropped it (e.g. Mantle of Perenolde drops
    -- from Epoch Hunter in Durnholde but is listed in Skarloc's DB loot).
    -- Symmetric with OnStartLootRoll's snapshot-first step. Container/Chest
    -- sources fall through here and are handled by the snapshot-fallback
    -- block below, which lazy-registers them as Chest entries.
    local snapBoss
    do
        local now = Now()
        for i = 1, #LT.lootSessions do
            local s = LT.lootSessions[i]
            if now - s.time <= LOOT_SESSION_GRACE_SECONDS
                and (s.items[itemId] or 0) > 0
            then
                local bIdx, b = FindBossByGuid(self.currentSession, s.guid)
                if b then
                    snapBoss = b
                    -- Promote lastBossKill (see the symmetric note in
                    -- OnStartLootRoll's snapshot-first block).
                    self.lastBossKill = {
                        session   = self.currentSession,
                        bossIndex = bIdx,
                        time      = b.killedAt,
                        guid      = b.guid,
                    }
                elseif s.guid == "trash:" .. tostring(self.currentSession.id) then
                    snapBoss = GetOrCreateTrashBoss(self.currentSession)
                    -- Don't promote lastBossKill for Trash.
                end
                if snapBoss then
                    -- Decrement / evict per ClaimLootSessionByItem semantics.
                    s.items[itemId] = s.items[itemId] - 1
                    if s.items[itemId] == 0 then
                        s.items[itemId] = nil
                        if not next(s.items) then
                            table.remove(LT.lootSessions, i)
                        end
                    end
                    break
                end
            end
        end
    end
    if snapBoss then
        local _, existing = FindItemInBoss(snapBoss, itemId)
        if existing then
            FillRecipientOrIncrement(existing, recipient, count)
        else
            existing = {
                itemId    = itemId,
                itemLink  = itemLink,
                recipient = recipient,
                count     = count or 1,
                quality   = quality,
                droppedAt = Now(),
                rolls     = {},
            }
            table.insert(snapBoss.items, existing)
        end
        MaybeAddSyntheticRoll(self, existing, recipient)
        self:Fire("ItemReceived", self.currentSession, snapBoss, existing)
        return
    end

    -- DB walk: registered boss whose DB loot set contains this item, walked
    -- newest-first. Used when snapshot doesn't have the item (snapshot
    -- expired, non-looter without a LOOT_OPENED event, etc.).
    if LootTracker_Bosses then
        local bosses = self.currentSession.bosses
        for i = #bosses, 1, -1 do
            local b = bosses[i]
            local dbEntry = b.npcId and LootTracker_Bosses[b.npcId]
            if dbEntry and dbEntry.loot and dbEntry.loot[itemId] then
                local _, existing = FindItemInBoss(b, itemId)
                if existing then
                    FillRecipientOrIncrement(existing, recipient, count)
                else
                    existing = {
                        itemId    = itemId,
                        itemLink  = itemLink,
                        recipient = recipient,
                        count     = count or 1,
                        quality   = quality,
                        droppedAt = Now(),
                        rolls     = {},
                    }
                    table.insert(b.items, existing)
                end
                MaybeAddSyntheticRoll(self, existing, recipient)
                self:Fire("ItemReceived", self.currentSession, b, existing)
                return
            end
        end
    end

    -- Inferred-boss path: no registered boss matched the item in its DB
    -- loot table, but the item itself may point at exactly one DB boss.
    -- Covers the case where UNIT_DIED for the source boss was missed by
    -- HandleCombatLog and the player never opened the loot window — the
    -- only signals we have are the chat messages from group-loot rolls
    -- and the eventual "X receives loot" CHAT_MSG_LOOT.
    local inferred = ResolveInferredBoss(self, itemId)
    if inferred then
        local _, existing = FindItemInBoss(inferred, itemId)
        if existing then
            FillRecipientOrIncrement(existing, recipient, count)
        else
            existing = {
                itemId    = itemId,
                itemLink  = itemLink,
                recipient = recipient,
                count     = count or 1,
                quality   = quality,
                droppedAt = Now(),
                rolls     = {},
            }
            table.insert(inferred.items, existing)
        end
        MaybeAddSyntheticRoll(self, existing, recipient)
        self:Fire("ItemReceived", self.currentSession, inferred, existing)
        return
    end

    -- Fallback: snapshot-based attribution. With per-slot source resolution
    -- in OnLootOpened, every loot slot already carries the right bucket guid
    -- — either a registered boss, the per-session Trash sentinel, or a
    -- synthetic Chest. We just look up the bucket by item from the snapshot
    -- queue and route to whichever entry it points at.
    local lootSession = ClaimLootSessionByItem(itemId)
    local sourceGuid = lootSession and lootSession.guid or nil

    local active
    if sourceGuid then
        if self.lastBossKill and self.lastBossKill.guid == sourceGuid
            and (Now() - self.lastBossKill.time <= LOOT_WINDOW_SECONDS)
        then
            active = self.lastBossKill.session.bosses[self.lastBossKill.bossIndex]
        else
            local _, existingBoss = FindBossByGuid(self.currentSession, sourceGuid)
            if existingBoss then
                active = existingBoss
            elseif sourceGuid == "trash:" .. tostring(self.currentSession.id) then
                -- Trash bucket sentinel: lazy-create the single Trash entry.
                active = GetOrCreateTrashBoss(self.currentSession)
            elseif lootSession.npcId then
                -- Snapshot recorded a real NPC id (typically when OnLootOpened
                -- ran the legacy chain for a missing GetLootSourceInfo). If
                -- DB-known, register; otherwise fold into Trash.
                local dbEntry = LootTracker_Bosses and LootTracker_Bosses[lootSession.npcId]
                if dbEntry then
                    local cand = PopCandidateByGUID(sourceGuid)
                    if cand then
                        self:OnBossKill(cand.npcId, cand.name, cand.time, cand.guid)
                    else
                        self:OnBossKill(lootSession.npcId, lootSession.name,
                            lootSession.time, sourceGuid)
                    end
                    active = self.lastBossKill.session.bosses[self.lastBossKill.bossIndex]
                else
                    active = GetOrCreateTrashBoss(self.currentSession)
                end
            else
                -- Non-NPC source (GameObject) — register as a Chest entry.
                self:OnBossKill(nil, lootSession.name, lootSession.time, sourceGuid)
                active = self.lastBossKill.session.bosses[self.lastBossKill.bossIndex]
            end
        end
    else
        -- No snapshot match. Could be a CHAT_MSG_LOOT arriving after its
        -- snapshot expired (LOOT_SESSION_GRACE_SECONDS). Anchor to a recent
        -- lastBossKill if available; otherwise route to Trash so it isn't
        -- lost. Quality-based promotion is gone — Task 4 makes orphaned
        -- attribution rare enough that the simpler default is better.
        active = self.lastBossKill
            and (Now() - self.lastBossKill.time <= LOOT_WINDOW_SECONDS)
            and self.lastBossKill.session.bosses[self.lastBossKill.bossIndex]
            or nil
        if not active then
            active = GetOrCreateTrashBoss(self.currentSession)
        end
    end

    local _, existing = FindItemInBoss(active, itemId)
    if existing then
        FillRecipientOrIncrement(existing, recipient, count)
    else
        existing = {
            itemId    = itemId,
            itemLink  = itemLink,
            recipient = recipient,
            count     = count or 1,
            quality   = quality,
            droppedAt = Now(),
            rolls     = {},
        }
        table.insert(active.items, existing)
    end
    MaybeAddSyntheticRoll(self, existing, recipient)
    self:Fire("ItemReceived", self.currentSession, active, existing)
end

-- START_LOOT_ROLL fires on EVERY client eligible to roll on a group-loot
-- item — not just the looter. This is the only signal a non-looter ever
-- gets that an item is up for rolling (LOOT_OPENED only fires for the
-- player whose corpse window is open). Using the rollID we get a
-- deterministic item identity via GetLootRollItemInfo / GetLootRollItemLink,
-- so subsequent CHAT_MSG_LOOT roll messages can be mapped directly to the
-- right boss + item entry without the EnsureBossContext heuristic dance.
function LT:OnStartLootRoll(rollID, duration)
    if not self.currentSession then return end

    local itemLink = GetLootRollItemLink and GetLootRollItemLink(rollID)
    if not itemLink then return end
    local itemId = GetItemIDFromLink(itemLink)
    if not itemId then return end

    -- Bail if quality is missing (stale rollID or transient API miss): the
    -- fast path bypasses the rare+ promotion gate downstream, so a nil
    -- quality here could leak grey items into the boss list. The chat-message
    -- fallback in OnGroupLootRoll still catches genuine rolls.
    local _, _, count, quality = GetLootRollItemInfo(rollID)
    if not quality or quality < 2 then return end

    local session = self.currentSession
    local boss, bossIndex

    -- Sub-rare items route to the per-session Trash bucket so subsequent
    -- roll messages and won announcements (which look up via this rollID's
    -- ctx) attribute to a Trash item entry rather than creating a green on
    -- the boss. Bosses tab is rare+ only; keeps START_LOOT_ROLL aligned with
    -- OnLootReceived's quality gate.
    if quality < 3 then
        boss = GetOrCreateTrashBoss(session)
        if boss then
            -- Trash is keyed by a deterministic guid, so FindBossByGuid is
            -- both self-documenting and avoids a reverse linear scan over
            -- a long raid's boss list every sub-rare roll. The `or` fallback
            -- makes the post-insert invariant explicit: GetOrCreateTrashBoss
            -- just inserted at the end (or found the existing entry), so the
            -- lookup can't legitimately miss — but if it ever did, bossIndex
            -- would be nil and downstream session.bosses[nil] indirection
            -- would silently swallow the rollID context.
            bossIndex = FindBossByGuid(session, "trash:" .. tostring(session.id))
                or #session.bosses
        end
    else
        -- Step 1 (snapshot-first): GetLootSourceInfo gave OnLootOpened a
        -- definitive source GUID per slot. If a recent snapshot bucketed
        -- this item under a specific source (a registered DB boss, the
        -- per-session Trash bucket, or a Chest container) USE IT — that's
        -- direct observation, not a heuristic. This wins over the DB walk
        -- below, which can wrongly attribute items to the wrong boss when
        -- the DB lists the same item under multiple bosses or when the DB
        -- is simply wrong (e.g., Mantle of Perenolde / Diamond Prism of
        -- Recurrence are listed under Skarloc but drop from Epoch Hunter
        -- in Durnholde; the DB walk would pick Skarloc as lastBossKill
        -- even though the actual corpse was Epoch Hunter).
        local now = Now()
        for i = 1, #LT.lootSessions do
            local s = LT.lootSessions[i]
            if now - s.time <= LOOT_SESSION_GRACE_SECONDS
                and (s.items[itemId] or 0) > 0
            then
                local bIdx, b = FindBossByGuid(session, s.guid)
                if b then
                    boss = b
                    bossIndex = bIdx
                    -- Promote lastBossKill so any subsequent event that
                    -- consults it (EnsureBossContext step 2/5, OnGroupLoot-
                    -- Roll's fallback, OnLootReceived's later branches when
                    -- snapshot has expired) anchors to the snapshot's actual
                    -- source rather than a stale prior kill. Mirrors
                    -- EnsureBossContext step 1's lastBossKill promotion.
                    self.lastBossKill = {
                        session   = session,
                        bossIndex = bIdx,
                        time      = b.killedAt,
                        guid      = b.guid,
                    }
                elseif s.guid == "trash:" .. tostring(session.id) then
                    boss = GetOrCreateTrashBoss(session)
                    bossIndex = FindBossByGuid(session,
                        "trash:" .. tostring(session.id))
                        or #session.bosses
                    -- Don't promote lastBossKill for Trash — it isn't a
                    -- "kill" and promoting it would mask a real prior boss
                    -- the rest of the heuristic chain still needs.
                end
                -- Container/Chest sources (no FindBossByGuid match and not
                -- the trash sentinel) fall through to DB walk + EnsureBoss-
                -- Context; the snapshot-fallback path in OnLootReceived
                -- lazy-registers them as Chest entries when the item is
                -- actually received.
                if boss then
                    -- Decrement the snapshot's slot count and evict the
                    -- bucket when fully claimed. Matches ClaimLootSession-
                    -- ByItem's semantics so two overlapping snapshots
                    -- sharing the same itemId (boss A drops X then boss B
                    -- drops X within 30s grace) don't both route every
                    -- drop of X to whichever snapshot was iterated first.
                    s.items[itemId] = s.items[itemId] - 1
                    if s.items[itemId] == 0 then
                        s.items[itemId] = nil
                        if not next(s.items) then
                            table.remove(LT.lootSessions, i)
                        end
                    end
                    break
                end
            end
        end

        -- Step 2 (DB walk): registered boss whose DB loot table contains
        -- this item, walked newest-first. Used when snapshot doesn't have
        -- the item (snapshot expired, addon loaded mid-roll, non-looter
        -- with no LOOT_OPENED event). Mirrors OnLootReceived's primary
        -- path so START_LOOT_ROLL and OnLootReceived attribute the same
        -- item to the same boss when the snapshot path is unavailable.
        if not boss and LootTracker_Bosses then
            local bosses = session.bosses
            for i = #bosses, 1, -1 do
                local b = bosses[i]
                local dbEntry = b.npcId and LootTracker_Bosses[b.npcId]
                if dbEntry and dbEntry.loot and dbEntry.loot[itemId] then
                    boss = b
                    bossIndex = i
                    break
                end
            end
        end

        -- Step 3 (heuristic fallback): items not in any registered boss's
        -- DB loot (non-DB encounters, custom server items, holiday loot).
        if not boss then
            if not EnsureBossContext(self, itemId) then return end
            if not self.lastBossKill then return end
            bossIndex = self.lastBossKill.bossIndex
            boss = session.bosses[bossIndex]
        end
    end

    if not boss then return end

    -- Always create a fresh entry per rollID — never reuse an existing entry
    -- via FindItemInBoss. The same itemId can drop multiple times from the
    -- same boss; reusing would collapse all drops into one entry and the
    -- rolledBy guard in OnGroupLootRoll would silently drop every roll from
    -- a player who already rolled on a prior drop. Each rollID gets its own
    -- rolls list, recipient, and trade-window timer.
    local item = {
        itemId    = itemId,
        itemLink  = itemLink,
        count     = count or 1,
        quality   = quality,
        droppedAt = Now(),
        rolls     = {},
    }
    table.insert(boss.items, item)
    local itemIndex = #boss.items
    self:Fire("ItemReceived", session, boss, item)

    -- WoW 3.3.5 passes `duration` in milliseconds.
    local durSec = (duration or 90000) / 1000
    self.activeGroupRolls[rollID] = {
        session   = session,
        bossIndex = bossIndex,
        itemIndex = itemIndex,
        itemId    = itemId,
        itemLink  = itemLink,
        startedAt = Now(),
        expiresAt = Now() + durSec + GROUP_ROLL_GRACE_SECONDS,
    }
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
    -- This bypasses EnsureBossContext entirely for the common case. It is NOT
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
            if not EnsureBossContext(self, itemId) then return end
            if not self.lastBossKill then return end
            session = self.lastBossKill.session
            boss = session.bosses[self.lastBossKill.bossIndex]
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

-- Open (or replace) the manual-roll window from a raid-warning item link.
-- Gated to master loot so normal group-loot raids — where the automatic system
-- already tracks rolls — don't spawn phantom windows from incidental item
-- links in a warning. Only the FIRST link in the warning is used (one active
-- roll at a time); a later announcement supersedes the current window.
function LT:OnManualRollAnnounce(itemLink)
    if not self.currentSession then return end
    if not (GetLootMethod and GetLootMethod() == "master") then return end
    local itemId = GetItemIDFromLink(itemLink)
    if not itemId then return end
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
    if recipient and not item.recipient then
        item.recipient = recipient
        self:Fire("ItemReceived", session, boss, item)
    end

    -- Do NOT drop activeGroupRolls[ctxID] here. The matching "X receives loot"
    -- CHAT_MSG_LOOT fires within milliseconds AFTER this won message, and
    -- OnLootReceived needs the context to avoid creating a duplicate item
    -- entry on a different boss (the heuristic fallback uses lastBossKill,
    -- which may not be the boss the START_LOOT_ROLL anchored to). Natural
    -- expiry via the CANCEL_LOOT_ROLL grace handles cleanup.
end

-- ---------------------------------------------------------------------------
-- Trade-window helpers
-- ---------------------------------------------------------------------------

-- Returns seconds remaining in the 2h trade window, or nil if past it / no
-- droppedAt. Pure function — used by the ticker, the sticky panel, and the
-- inline badge so all three agree on remaining time.
function LT:GetTradeRemaining(item)
    if not item or not item.droppedAt then return nil end
    local remaining = TRADE_WINDOW_SECONDS - (Now() - item.droppedAt)
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
function LT:GetActiveTradeTimers(session)
    if not session or not session.bosses then return {} end
    local result = {}
    for _, boss in ipairs(session.bosses) do
        for _, item in ipairs(boss.items) do
            local remaining = self:GetTradeRemaining(item)
            if remaining then
                result[#result + 1] = {
                    item         = item,
                    boss         = boss,
                    remainingSec = remaining,
                }
            end
        end
    end
    table.sort(result, function(a, b) return a.remainingSec < b.remainingSec end)
    return result
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
                    local remaining = TRADE_WINDOW_SECONDS - (now - item.droppedAt)
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
    local anyLive = false
    local anyAlertFired = false
    local now = Now()

    for _, session in ipairs(LootTrackerDB.sessions or {}) do
        for _, boss in ipairs(session.bosses) do
            for _, item in ipairs(boss.items) do
                if item.droppedAt then
                    item.alertedThresholds = item.alertedThresholds or {}
                    -- Skip items already past the window AND already alerted
                    -- about expiry. Everything else still needs threshold
                    -- checks — including items currently past expiry but not
                    -- yet alerted (addon was disabled when the boundary was
                    -- crossed, or this is the first tick after a fresh login
                    -- with a pre-existing expired item).
                    if not item.alertedThresholds.expired then
                        local remaining = TRADE_WINDOW_SECONDS - (now - item.droppedAt)
                        if remaining > 0 then anyLive = true end
                        -- remaining can be negative here; the threshold list
                        -- includes an entry with atOrBelow = 0 ("expired") so
                        -- the loop catches the expired transition uniformly.
                        for _, th in ipairs(TRADE_ALERT_THRESHOLDS) do
                            if remaining <= th.atOrBelow
                                and not item.alertedThresholds[th.key]
                            then
                                -- Bag-presence gate: only chat-alert for items
                                -- currently in the player's bags. Suppresses
                                -- alerts for items already traded away, items
                                -- looted by other players, and items stashed
                                -- in the bank/mail. GetItemCount default scope
                                -- is bags only (bank/charges excluded).
                                if alertsOn
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
    -- Run one tick immediately so the UI / alerts react without waiting 30s
    -- for the first OnUpdate after a fresh login.
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

    local name
    name, link, qty = text:match(LOOT_OTHER_MULTI)
    if name and link then return name, link, tonumber(qty) end

    name, link = text:match(LOOT_OTHER_SINGLE)
    if name and link then return name, link, 1 end
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

    PushCandidate(destGUID, npcId, destName)

    -- Eager registration for DB-known bosses: register the kill at UNIT_DIED
    -- (or PARTY_KILL) time so the UI shows the boss immediately and so any
    -- subsequent group-loot roll messages match via EnsureBossContext's
    -- lbkValid path (step 1) instead of needing the candidate buffer. Non-DB
    -- NPCs deliberately stay candidates-only — eager-registering every NPC
    -- would surface trash as boss headers.
    local dbEntry = LootTracker_Bosses and LootTracker_Bosses[npcId]
    if dbEntry then
        EnsureBossRegistered(LT, npcId, dbEntry.name, nil, destGUID)
    end
end

local eventFrame = CreateFrame("Frame", "LootTrackerEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("START_LOOT_ROLL")
eventFrame:RegisterEvent("CANCEL_LOOT_ROLL")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("CHAT_MSG_RAID_WARNING")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("INSPECT_TALENT_READY")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == "LootTracker" then
            EnsureDB()
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
    elseif event == "LOOT_OPENED" then
        LT:OnLootOpened()
    elseif event == "START_LOOT_ROLL" then
        local rollID, duration = ...
        LT:OnStartLootRoll(rollID, duration)
    elseif event == "CANCEL_LOOT_ROLL" then
        local rollID = ...
        LT:OnCancelLootRoll(rollID)
    elseif event == "CHAT_MSG_LOOT" then
        local text = ...
        local recipient, link, count = ParseLoot(text)
        if recipient and link then
            LogDebug("loot in:  " .. text)
            LogDebug("loot out: recipient=" .. tostring(recipient)
                .. " link=" .. tostring(link))
            LT:OnLootReceived(recipient, link, count)
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
