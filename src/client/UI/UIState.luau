--!strict
--[[
	UIState (Phase 11)
	Which full-screen UI owns the player's input right now: the main menu (open / closed) and the modal dialogs
	(settings, credits, confirmations). Gameplay input (flight keys, building, camera drag and zoom, the map view)
	checks isInputBlocked() and ignores the player while the menu or any modal is open.
	CHANGED (Phase 11 review): UI/CharacterControls switches the character's own controls (walk, jump) off meanwhile.

	The main menu controller owns setMenuOpen (it should open the menu in its Init, before gameplay reads input);
	anything else that wants the menu (the builder's Menu button) calls requestMenu(), which the main menu
	controller listens to. Modals are named and treated as a set: pushing a name that is already open does nothing,
	popping removes it wherever it is. Every signal fires only on a real change.

	API:
	  UIState.isMenuOpen() -> boolean
	  UIState.setMenuOpen(open)
	  UIState.onMenuChanged(fn(open)) -> RBXScriptConnection
	  UIState.requestMenu()
	  UIState.onMenuRequested(fn()) -> RBXScriptConnection
	  UIState.pushModal(name)
	  UIState.popModal(name)
	  UIState.isModalOpen() -> boolean
	  UIState.topModal() -> string?                        the most recently pushed modal still open
	  UIState.onModalChanged(fn()) -> RBXScriptConnection
	  UIState.isInputBlocked() -> boolean                  menu or any modal open: ignore gameplay input
	  UIState.onInputBlockedChanged(fn(blocked)) -> RBXScriptConnection
]]

--============================================================================
-- Tunables
--============================================================================
local MENU_OPEN_AT_START = false -- the main menu controller opens it itself (in its Init)
--============================================================================

local UIState = {}

local menuOpen = MENU_OPEN_AT_START
local modals: { string } = {} -- open modal names, oldest first
local lastBlocked = MENU_OPEN_AT_START

local menuChanged = Instance.new("BindableEvent")
local menuRequested = Instance.new("BindableEvent")
local modalChanged = Instance.new("BindableEvent")
local blockedChanged = Instance.new("BindableEvent")

local function updateBlocked()
	local blocked = UIState.isInputBlocked()
	if blocked ~= lastBlocked then
		lastBlocked = blocked
		blockedChanged:Fire(blocked)
	end
end

function UIState.isMenuOpen(): boolean
	return menuOpen
end

function UIState.setMenuOpen(open: boolean)
	if open == menuOpen then
		return
	end
	menuOpen = open
	menuChanged:Fire(open)
	updateBlocked()
end

function UIState.onMenuChanged(fn: (open: boolean) -> ()): RBXScriptConnection
	return menuChanged.Event:Connect(fn)
end

-- Asks for the main menu (e.g. the builder's Menu button); the main menu controller decides what to do.
function UIState.requestMenu()
	menuRequested:Fire()
end

function UIState.onMenuRequested(fn: () -> ()): RBXScriptConnection
	return menuRequested.Event:Connect(fn)
end

function UIState.pushModal(name: string)
	if table.find(modals, name) then
		return
	end
	table.insert(modals, name)
	modalChanged:Fire()
	updateBlocked()
end

function UIState.popModal(name: string)
	local index = table.find(modals, name)
	if index == nil then
		return
	end
	table.remove(modals, index)
	modalChanged:Fire()
	updateBlocked()
end

function UIState.isModalOpen(): boolean
	return #modals > 0
end

function UIState.topModal(): string?
	return modals[#modals]
end

function UIState.onModalChanged(fn: () -> ()): RBXScriptConnection
	return modalChanged.Event:Connect(fn)
end

function UIState.isInputBlocked(): boolean
	return menuOpen or #modals > 0
end

function UIState.onInputBlockedChanged(fn: (blocked: boolean) -> ()): RBXScriptConnection
	return blockedChanged.Event:Connect(fn)
end

return table.freeze(UIState)
