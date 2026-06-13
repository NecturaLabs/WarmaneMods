-- EssentialCommands
--
-- Adds "/i" (and "/instance") as an instance-chat command targeting whatever
-- group channel you are currently in, behaving exactly like a native chat
-- channel command (/p, /raid, /s): live "/i "+space convert, Enter to send,
-- and it sticks to the channel afterward.
--   * In a raid group       -> RAID    (/raid)
--   * In a party (not raid)  -> PARTY   (/p)
--   * Not grouped            -> SAY     (/s)
--
-- Usage:
--   /i             type "/i" then space (or Enter) to switch the box to the
--                  channel and stay there -- just like typing "/p "
--   /i <message>   send <message> to the channel and stay on it
--
-- How it works: when typed in the chat box, "/i" is registered as a *dynamic
-- chat type* (hash_ChatTypeInfoList), so Blizzard's own chat code does the
-- convert/send/sticky, identical to /p. A chat-type entry maps to a single
-- channel, so we refresh it whenever group state changes. A plain SlashCmdList
-- handler is also kept so "/i" still works from macros and key bindings, which
-- never go through the chat edit box.

-- Resolve the chat type for the player's current group state.
-- Raid is checked first because, while in a raid, GetNumPartyMembers() is 0.
local function GetGroupChatType()
	if GetNumRaidMembers() > 0 then
		return "RAID"
	elseif GetNumPartyMembers() > 0 then
		return "PARTY"
	end
	return "SAY"
end

-- === Typed-in-chat path: dynamic chat type ================================
-- ChatEdit_ParseText resolves a typed "/x" against hash_ChatTypeInfoList
-- (UPPERCASE key) BEFORE the slash-command list, and reads it live on every
-- space/enter. Pointing "/I" and "/INSTANCE" at the current channel gives full
-- native behavior (live space-convert, send, sticky) and wins the token away
-- from /invite. The value must be a real ChatTypeInfo key, so we re-point it on
-- group changes.
local function RefreshInstanceChatType()
	local chatType = GetGroupChatType()
	hash_ChatTypeInfoList = hash_ChatTypeInfoList or {}
	hash_ChatTypeInfoList["/I"] = chatType
	hash_ChatTypeInfoList["/INSTANCE"] = chatType
end

RefreshInstanceChatType() -- initial mapping at load; refreshed on events below

-- === Macro / key-binding path: slash command =============================
-- Chat-type entries are only consulted inside the chat edit box, so macros and
-- key bindings also need a normal slash command.

-- Point the chat edit box at chatType and make it STICK there (matches /p).
-- stickyType is what the UI restores into chatType after each Enter
-- (ChatEdit_ResetChatTypeToSticky); without it we'd snap back to SAY.
local function SetChannel(editBox, chatType)
	editBox:SetAttribute("chatType", chatType)
	editBox:SetAttribute("stickyType", chatType)
	ChatEdit_UpdateHeader(editBox)
end

-- A bare "/i" from a macro/binding should open the box on the channel. The UI
-- may close the box right after the command runs, so defer the open by one
-- frame via this one-shot driver. Taint-safe: own frame, no protected calls.
local switcher = CreateFrame("Frame")
switcher:Hide()
switcher:SetScript("OnUpdate", function(self)
	self:Hide()
	local chatType = self.chatType
	self.chatType = nil
	if not chatType then
		return
	end

	local editBox = ChatEdit_ChooseBoxForSend()
	SetChannel(editBox, chatType)
	ChatEdit_ActivateChat(editBox)
end)

local function SwapToChannel(chatType)
	switcher.chatType = chatType
	switcher:Show()
end

-- editBox is the real chat box when typed; nil from a macro/binding.
local function HandleInstanceCommand(msg, editBox)
	local chatType = GetGroupChatType()
	editBox = editBox or ChatEdit_ChooseBoxForSend()

	-- Trim surrounding whitespace so "/i   " is treated as empty.
	msg = (msg or ""):gsub("^%s*(.-)%s*$", "%1")
	SetChannel(editBox, chatType)

	if msg == "" then
		SwapToChannel(chatType) -- keep the box open to type
	else
		SendChatMessage(msg, chatType)
	end
end

SLASH_ESSENTIALINSTANCE1 = "/i"
SLASH_ESSENTIALINSTANCE2 = "/instance"
SlashCmdList["ESSENTIALINSTANCE"] = HandleInstanceCommand

-- === Setup: refresh on group changes, seed token, confirm load ============
-- PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE are the WotLK group events
-- (GROUP_ROSTER_UPDATE does not exist until 5.x). PLAYER_ENTERING_WORLD covers
-- login/zone/reload.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("PARTY_MEMBERS_CHANGED")
loader:RegisterEvent("RAID_ROSTER_UPDATE")
loader:SetScript("OnEvent", function(self, event)
	RefreshInstanceChatType()
	if event == "PLAYER_LOGIN" then
		-- Belt-and-suspenders for the macro/binding path: claim "/i" in the
		-- slash hash so it resolves to us, not /invite, if ever reached via the
		-- slash route. "/inv" and "/invite" still invite.
		hash_SlashCmdList = hash_SlashCmdList or {}
		hash_SlashCmdList["/I"] = SlashCmdList["ESSENTIALINSTANCE"]
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99EssentialCommands|r loaded \226\128\148 |cffffff00/i|r is instance chat (use /inv to invite).")
	end
end)
