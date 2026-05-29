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

local nextSyntheticGuid = 0

LT.classCache       = {}
LT.currentSession   = nil
LT.lastBossKill     = nil   -- { session, bossIndex, time, guid }
LT.activeRollItem   = nil   -- { session, bossIndex, itemIndex, expiresAt }
LT.candidateDeaths  = {}    -- recent unattributed NPC deaths
LT.lootSessions     = {}    -- queue of { guid, npcId, name, time, items } from recent LOOT_OPENED snapshots
LT.activeGroupRolls   = {}  -- [rollID] = { session, bossIndex, itemIndex, itemId, itemLink, startedAt, expiresAt }
LT.resetInstanceNames = {}  -- [instanceName:lower()] = true; consumed on the next entry into that instance
LT.listeners          = {}

local GROUP_ROLL_GRACE_SECONDS = 30  -- keep rollID entries around this long after CANCEL for late chat

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

-- Single source of truth for "wipe everything tied to the current run." Four
-- sites need this (zone exit, zone re-enter into new session, DeleteSession
-- of the current one, Reset) and previously each site enumerated the fields
-- inline — easy to forget one when a new field is added (as happened when
-- activeGroupRolls was introduced).
local function ClearTransientState(self)
    self.lastBossKill     = nil
    self.activeRollItem   = nil
    self.candidateDeaths  = {}
    self.lootSessions     = {}
    self.activeGroupRolls = {}
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
local ROLL_PATTERN       = BuildPattern(RANDOM_ROLL_RESULT       or "%s rolls %d (%d-%d)")
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

local function FindItemInBoss(boss, itemId)
    for i, item in ipairs(boss.items) do
        if item.itemId == itemId then return i, item end
    end
end

-- An item entry may already exist as a placeholder created by OnGroupLootRoll
-- (when players rolled before the winner received it) or OnItemLinkAnnounced
-- (master-loot pre-announce). Those placeholders have no recipient. On the
-- first actual receive, fill in the recipient instead of double-incrementing
-- the drop count. A *true* re-drop of the same item (same boss, recipient
-- already set) does increment count, as before.
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

-- Group loot, and master-loot raids where the announcing player isn't the
-- local one, can fire CHAT_MSG_LOOT roll/announce messages BEFORE the player
-- has opened any loot window — meaning OnLootOpened (and its DB shortcut)
-- never ran. Promote the right candidate so the roll/announce has a boss
-- entry to attach to. Returns true if there's a valid boss context after
-- the call, false otherwise.
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
                    EnsureBossRegistered(self, s.npcId, s.name, s.time, s.guid)
                else
                    self:OnBossKill(nil, s.name, s.time, s.guid)
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
    if ResolveInferredBoss(self, itemId) then return true end

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
local function EnsureBossRegistered(self, npcId, name, killTime, guid)
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
--   3. Missing GUID (private-server quirk) or
--      non-NPC GUID (GameObject: chest, herb,
--      ore, fishing node)                       → fall through to legacy
--                                                 target / candidate /
--                                                 lastBossKill / synthetic
--                                                 "Chest" chain (preserved).
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
                    -- GameObject GUID (chest, herb, ore, fishing) — use legacy chain.
                    -- If the legacy chain's resolved guid collides with a bucket
                    -- already created by an earlier slot's per-slot path (e.g.
                    -- both ended up at trashKey), reuse the existing bucket so
                    -- its items aren't overwritten.
                    local lb = getLegacyBucket()
                    bucketKey = lb.guid
                    bucketRec = buckets[bucketKey] or lb
                    buckets[bucketKey] = bucketRec
                end
            else
                -- GetLootSourceInfo missing or empty — use legacy chain.
                -- Same collision guard as the GameObject branch above.
                local lb = getLegacyBucket()
                bucketKey = lb.guid
                bucketRec = buckets[bucketKey] or lb
                buckets[bucketKey] = bucketRec
            end

            -- Skip currencies and materials at the snapshot layer too. The
            -- classification gate in OnLootReceived returns before claiming
            -- from the snapshot, so leaving these in the bucket would just
            -- sit there until the 30s grace expires. Materials with a cold
            -- GetItemInfo cache leak through harmlessly — they're already
            -- handled by the gate on OnLootReceived's side.
            if not IsCurrency(id) and not IsMaterial(link) then
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
-- the item. Two scenarios both need this:
--   1. Solo play: there is no group, so no group-loot roll fires; without
--      this, every solo drop renders as "no rolls yet".
--   2. Master loot: the loot master assigns directly, often with no rolls
--      in chat at all. The recipient is the de-facto winner; surface that
--      as a clean 100 Need entry so the UI is consistent with group-loot
--      drops.
-- In both cases, if any real rolls already populated item.rolls (e.g. raid
-- did /random before the ML assigned), we leave them alone — the synthetic
-- only fires for genuinely roll-less drops.
--
-- Known limitation (shared with the FillRecipientOrIncrement note in the
-- activeGroupRolls short-circuit): when the SAME itemId drops twice from
-- one boss, FindItemInBoss reuses the existing entry. The first recipient's
-- synthetic 100 Need stays; the second drop's recipient is not surfaced
-- because #item.rolls > 0 guards re-entry. Acceptable per the project's
-- simpler-over-comprehensive stance.
local function MaybeAddSyntheticRoll(self, item, recipient)
    if not recipient then return end
    item.rolls = item.rolls or {}
    if #item.rolls > 0 then return end

    local isMasterLoot = GetLootMethod and GetLootMethod() == "master"
    if not isMasterLoot then
        -- Solo gate: only fire if we're truly solo. Master-loot path
        -- doesn't need this gate.
        if recipient ~= UnitName("player") then return end
        local nR = (GetNumRaidMembers and GetNumRaidMembers()) or 0
        local nP = (GetNumPartyMembers and GetNumPartyMembers()) or 0
        if nR > 0 or nP > 0 then return end
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
    if IsCurrency(itemId) then
        local entry = RecordCurrency(self.currentSession, itemId, itemLink, recipient, count)
        self:Fire("CurrencyReceived", self.currentSession, entry)
        return
    end
    if IsMaterial(itemLink) then
        local entry = RecordMaterial(self.currentSession, itemId, itemLink, recipient, count)
        self:Fire("MaterialReceived", self.currentSession, entry)
        return
    end

    -- Short-circuit: if START_LOOT_ROLL recently created an item entry for
    -- this itemId (active rollID context), reuse it. This prevents the
    -- fallback below from creating a duplicate entry on lastBossKill when
    -- the item was already attributed to a different boss by OnStartLootRoll
    -- (common for non-DB bosses on private servers where the DB walk below
    -- would also fail to find a match). Skips both primary and fallback.
    local ctxID, ctx = FindGroupRollContext(self, itemId)
    if ctx then
        local boss = ctx.session.bosses[ctx.bossIndex]
        local item = boss and boss.items[ctx.itemIndex]
        if item then
            -- If recipient was already set by OnGroupLootWon (fires just
            -- before this loot-received message), DON'T re-run Fill — it
            -- would take the increment branch and double-count a single
            -- drop. OnGroupLootWon doesn't track count, so leave whatever
            -- OnStartLootRoll set (which came from GetLootRollItemInfo).
            --
            -- Known limitation: when the SAME itemId drops twice from one
            -- boss in quick succession, FindItemInBoss in OnStartLootRoll
            -- reuses the existing entry, and OnGroupLootWon's "if not
            -- item.recipient" guard refuses to overwrite. The second drop's
            -- winner and count are silently lost. Acceptable per the
            -- project's "simpler over comprehensive" stance.
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

    -- Primary attribution: walk currentSession.bosses newest-first and pick
    -- the first whose DB loot set contains this item. This is deterministic
    -- and unaffected by LOOT_OPENED timing — items can ONLY be attributed
    -- to a boss whose static loot table actually contains them.
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

-- ---------------------------------------------------------------------------
-- Roll association
-- ---------------------------------------------------------------------------

function LT:OnItemLinkAnnounced(itemLink)
    if not self.currentSession then return end
    local itemId = GetItemIDFromLink(itemLink)
    if not itemId then return end
    -- Same quality gate as OnLootReceived — don't track grey/white items.
    local announceQuality = GetItemQualityFromLink(itemLink)
    if announceQuality and announceQuality < 2 then return end
    if not EnsureBossContext(self, itemId) then return end

    local session = self.lastBossKill.session
    local boss = session.bosses[self.lastBossKill.bossIndex]
    if not boss then return end

    local idx, entry = FindItemInBoss(boss, itemId)
    if not entry then
        entry = {
            itemId    = itemId,
            itemLink  = itemLink,
            count     = 1,
            quality   = announceQuality,
            droppedAt = Now(),
            rolls     = {},
        }
        table.insert(boss.items, entry)
        idx = #boss.items
        self:Fire("ItemReceived", session, boss, entry)
    end

    self.activeRollItem = {
        session   = session,
        bossIndex = self.lastBossKill.bossIndex,
        itemIndex = idx,
        itemId    = itemId,
    }
end

function LT:OnRoll(playerName, value, minRoll, maxRoll)
    local active = self.activeRollItem
    if not active then return end

    local boss = active.session.bosses[active.bossIndex]
    if not boss then return end
    local item = boss.items[active.itemIndex]
    if not item then return end

    if not item.rolledBy then
        item.rolledBy = {}
        for _, r in ipairs(item.rolls) do item.rolledBy[r.player] = true end
    end
    if item.rolledBy[playerName] then return end
    item.rolledBy[playerName] = true

    table.insert(item.rolls, {
        player       = playerName,
        class        = self:GetPlayerClass(playerName),
        value        = value,
        minRoll      = minRoll,
        maxRoll      = maxRoll,
        time         = Now(),
        equippedLink = GetEquippedForCompare(playerName, item.itemLink),
    })
    table.sort(item.rolls, function(a, b) return (a.value or 0) > (b.value or 0) end)
    self:Fire("RollAdded", active.session, boss, item)
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

    -- Prefer a registered boss whose DB loot table contains this item, walked
    -- newest-first. Mirrors OnLootReceived's primary path so START_LOOT_ROLL
    -- and OnLootReceived attribute the same item to the same boss — without
    -- this, EnsureBossContext could attach to lastBossKill while OnLootReceived
    -- later picks a different (correct, DB-matched) boss, producing a duplicate
    -- entry and orphaning the rolls onto the wrong copy.
    local session = self.currentSession
    local boss, bossIndex
    if LootTracker_Bosses then
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

    -- Fallback to the existing heuristic for items not in any registered
    -- boss's DB loot (non-DB encounters, custom server items, holiday loot).
    if not boss then
        if not EnsureBossContext(self, itemId) then return end
        bossIndex = self.lastBossKill.bossIndex
        boss = session.bosses[bossIndex]
        if not boss then return end
    end

    local itemIndex, item = FindItemInBoss(boss, itemId)
    if not item then
        item = {
            itemId    = itemId,
            itemLink  = itemLink,
            count     = count or 1,
            quality   = quality,
            droppedAt = Now(),
            rolls     = {},
        }
        table.insert(boss.items, item)
        itemIndex = #boss.items
        self:Fire("ItemReceived", session, boss, item)
    end

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
    -- fully deterministic when two bosses drop the same item with overlapping
    -- roll windows — CHAT_MSG_LOOT carries no rollID, so all roll messages
    -- for that itemId route to the most-recently-started context (the older
    -- boss's rolls misattribute to the newer one). This is an inherent limit
    -- of the chat surface; the pre-existing EnsureBossContext heuristic had
    -- the same/worse problem (everything pinned to lastBossKill).
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
        if not EnsureBossContext(self, itemId) then return end
        session = self.lastBossKill.session
        boss = session.bosses[self.lastBossKill.bossIndex]
        if not boss then return end

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
        -- Existing entry. Upgrade a "has selected" intent (value=nil) when
        -- the corresponding numeric roll value arrives. Don't downgrade a
        -- numeric value back to nil, and don't overwrite an already-numeric
        -- value (the first broadcast wins on the rare case of duplicates).
        if value ~= nil then
            for _, r in ipairs(item.rolls) do
                if r.player == playerName then
                    if r.value == nil then
                        r.value = value
                        r.rollType = rollType
                        r.time = Now()
                        table.sort(item.rolls,
                            function(a, b) return (a.value or 0) > (b.value or 0) end)
                        self:Fire("RollAdded", session, boss, item)
                    end
                    return
                end
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
    local function mkItem(id, name, qHex, quality, expanded, rolls)
        local rolledBy = {}
        for _, r in ipairs(rolls) do rolledBy[r.player] = true end
        table.sort(rolls, function(a, b) return (a.value or 0) > (b.value or 0) end)
        return {
            itemId = id, itemLink = mkLink(id, name, qHex),
            count = 1, quality = quality, expanded = expanded,
            droppedAt = now, rolls = rolls, rolledBy = rolledBy,
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
            }),
            mkItem(49835, "Splintered Door of the Citadel", "a335ee", 4, false, {
                mkRoll("Pewpewlazor", "PALADIN", 88,  40400, "Wall of Terror", "Need"),
                mkRoll("Gronkar",     "WARRIOR", 45,  40400, "Wall of Terror", "Greed"),
            }),
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
            }),
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
            }),
            mkItem(50402, "Ashen Band of Endless Vengeance", "a335ee", 4, false, {
                mkRoll("Bowsong",    "HUNTER", 87,  40718, "Signet of the Impregnable Fortress", "Need"),
                mkRoll("Shockwave",  "SHAMAN", 35,  40718, "Signet of the Impregnable Fortress", "Greed"),
                mkRoll("Stabbystab", "ROGUE",  nil, 40718, "Signet of the Impregnable Fortress", "Pass"),
            }),
        },
    })

    table.insert(LootTrackerDB.sessions, session)
    self:Fire("SessionChanged")
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
eventFrame:RegisterEvent("CHAT_MSG_RAID")
eventFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
eventFrame:RegisterEvent("CHAT_MSG_RAID_WARNING")
eventFrame:RegisterEvent("CHAT_MSG_PARTY")
eventFrame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
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
            local active = LT.activeRollItem
            if active then
                local receivedId = GetItemIDFromLink(link)
                if receivedId and active.itemId == receivedId then
                    LT.activeRollItem = nil
                end
            end
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
    elseif event == "CHAT_MSG_SYSTEM" then
        local text = ...
        local n, v, mn, mx = text:match(ROLL_PATTERN)
        if n and v then
            LT:OnRoll(n, tonumber(v), tonumber(mn), tonumber(mx))
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
    elseif event == "CHAT_MSG_RAID"
        or event == "CHAT_MSG_RAID_LEADER"
        or event == "CHAT_MSG_RAID_WARNING"
        or event == "CHAT_MSG_PARTY"
        or event == "CHAT_MSG_PARTY_LEADER"
    then
        local text = ...
        local link = text:match(ITEM_LINK_FULL)
        if link then LT:OnItemLinkAnnounced(link) end
    end
end)
