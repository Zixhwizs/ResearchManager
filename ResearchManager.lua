local RM = ResearchManager
local ADDON_NAME = RM.ADDON_NAME

-- =============================================================================
-- Boot
-- =============================================================================

local function ReindexInventory()
    RM.Scanner:BuildInventoryIndex()
end

-- Inventory changes fire bursts of events; coalesce into a single rebuild.
local pendingRebuild = false
local function ScheduleReindex()
    if pendingRebuild then return end
    pendingRebuild = true
    zo_callLater(function()
        pendingRebuild = false
        ReindexInventory()
    end, 1500)
end

-- When a research starts, the underlying item is consumed. Drop the oldest
-- matching binding for the current character so the GUI's "Items bound to
-- recipients" list reflects reality. This runs for both our auto-research
-- step machine and any manual research the player kicks off in the UI.
-- The event payload doesn't include the consumed item's bag/slot, so we
-- match by (craftingType, lineIndex, traitIndex) + recipient == current char.
local function RemoveBindingForResearch(craftingType, lineIndex, traitIndex)
    if not (RM.db and RM.db.craftedFor) then return end
    local myKey = RM:GetCharacterKey()
    local bestKey, bestWhen = nil, math.huge
    for k, v in pairs(RM.db.craftedFor) do
        if type(v) == "table"
            and v.recipient == myKey
            and v.craftingType == craftingType
            and v.lineIndex == lineIndex
            and v.traitIndex == traitIndex
        then
            local w = v.when or 0
            if w < bestWhen then
                bestKey = k
                bestWhen = w
            end
        end
    end
    if bestKey then
        RM.db.craftedFor[bestKey] = nil
        RM:Log("Dropped binding %s on research start", bestKey)
        -- If the window is open, reflect the change immediately.
        if RM.UI and RM.UI.window and not RM.UI.window:IsHidden() then
            RM.UI:RefreshWindow()
        end
    end
end

local function OnResearchStarted(_, craftingType, lineIndex, traitIndex)
    RM.Scanner:UpdateTraitState(craftingType, lineIndex, traitIndex)
    ScheduleReindex()
    RemoveBindingForResearch(craftingType, lineIndex, traitIndex)
end

local function OnResearchCompleted(_, craftingType, lineIndex, traitIndex)
    RM.Scanner:UpdateTraitState(craftingType, lineIndex, traitIndex)
    ScheduleReindex()
end

local function OnResearchCanceled(_, craftingType, lineIndex, traitIndex)
    RM.Scanner:UpdateTraitState(craftingType, lineIndex, traitIndex)
    ScheduleReindex()
end

local function OnResearchTimesUpdated()
    -- Lightweight: just refresh the snapshot's timer fields. Easiest to do via
    -- a full state scan since it's only 4 crafts.
    RM.Scanner:ScanResearchState()
end

local function OnSingleSlotUpdate(_, bagId, slotIndex, isNewItem)
    if bagId ~= BAG_BACKPACK and bagId ~= BAG_BANK and bagId ~= BAG_SUBSCRIBER_BANK then return end
    if isNewItem and bagId == BAG_BACKPACK then
        RM.Crafter:OnItemAdded(bagId, slotIndex)
    end
    ScheduleReindex()
end

-- Rescan on every crafting-station open AND close, regardless of station type.
-- Open: even non-smithing stations (alchemy, enchanting, etc.) imply the player
-- is actively crafting and a refreshed research-timer snapshot makes the next
-- queue planning accurate. Close: catches research the player just started at
-- this smithing station, plus any inventory changes from refining/extracting.
-- The scan reads GetSmithingResearchLineTraitTimes which works from any
-- context, so we don't need to gate on station type. Cheap relative to a
-- station interaction (a few hundred GetSmithingResearchLineTraitInfo calls).
local function RescanCurrentCharacter()
    RM.Scanner:ScanResearchState()
    RM.Scanner:BuildInventoryIndex()
end

local function OnCraftingStationInteract(_, craftingType)
    RescanCurrentCharacter()
    RM.Crafter:OnStationEnter(_, craftingType)
end

local function OnCraftingStationEnd()
    RescanCurrentCharacter()
    RM.Crafter:OnStationLeave()
end

-- On bank open, ship backpack items crafted for an alt's research into the
-- account bank so the recipient can withdraw and research them. Deferred one
-- tick so the bank bags are fully populated before we scan for empty slots.
--
-- EVENT_OPEN_BANK also fires for house storage (BAG_HOUSE_BANK_*) and the
-- furniture vault; only the regular account bank (BAG_BANK) is universally
-- withdrawable by the recipient, so we gate on it and skip the rest. The
-- furniture vault would reject gear anyway.
local function OnBankOpen(_, bankBag)
    if bankBag ~= BAG_BANK then return end
    zo_callLater(function() RM.Crafter:DepositResearchItemsToBank() end, 50)
end

-- How recent the saved snapshot has to be for us to treat the activation as
-- a /reloadui (and skip auto-scan) rather than a fresh login. EVENT_PLAYER_-
-- ACTIVATED's `initial` parameter can't tell these apart because /reloadui
-- resets the Lua state, so we use the persisted snapshot timestamp instead:
-- /reloadui is instantaneous (snapshot is seconds old), real logins always
-- restore a snapshot that's at least minutes-old since the previous logout.
local RELOADUI_SNAPSHOT_AGE_SECS = 60

local function OnPlayerActivated()
    local snap = RM.Scanner:GetCurrentSnapshot()
    if snap and snap.updatedAt then
        local age = GetTimeStamp() - snap.updatedAt
        if age >= 0 and age < RELOADUI_SNAPSHOT_AGE_SECS then
            RM:Log("Skipping auto-scan: snapshot is %ds old (likely /reloadui)", age)
            return
        end
    end
    RM.Scanner:ScanResearchState()
    RM.Scanner:BuildInventoryIndex()
end

local function HandleCraftArgs(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "" then
        RM.Crafter:PrintCraftingPlan()
    elseif rest:lower() == "all" then
        RM.Crafter:QueueForAll()
    else
        local key = RM.Crafter:FindCharKeyByName(rest)
        if not key then
            RM:AnnounceWarn(zo_strformat(GetString(SI_RM_CRAFT_UNKNOWN_ALT), rest))
            return
        end
        RM.Crafter:QueueForRecipient(key)
    end
end

local function RegisterSlashCommands()
    SLASH_COMMANDS["/research"] = function(args)
        args = args or ""
        local first, rest = args:match("^%s*(%S+)%s*(.*)$")
        first = (first or ""):lower()
        if first == "" or first == "status" then
            RM.UI:PrintStatus()
        elseif first == "next" or first == "recommend" then
            RM.UI:PrintRecommendations(5)
        elseif first == "scan" then
            RM.Scanner:ScanResearchState()
            RM.Scanner:BuildInventoryIndex()
            RM:Announce("Rescanned.")
        elseif first == "alts" or first == "gaps" then
            RM.Crafter:PrintAltGaps()
        elseif first == "craft" then
            HandleCraftArgs(rest)
        elseif first == "queue" then
            RM.Crafter:PrintQueue()
        elseif first == "show" or first == "window" or first == "gui" then
            RM.UI:ToggleWindow()
        elseif first == "debug" then
            RM.db.debug = not RM.db.debug
            RM:Announce("debug=" .. tostring(RM.db.debug))
        else
            -- Treat the first token as a character name: /research <AltName>
            local raw = (first or "") .. (rest ~= "" and (" " .. rest) or "")
            raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
            local key = RM.Crafter:FindCharKeyByName(raw)
            if key then
                RM.Crafter:QueueForRecipient(key)
            else
                RM:Announce("commands: show, status, next, scan, alts, craft, craft <name>, craft all, queue, <name>, debug")
            end
        end
    end
    SLASH_COMMANDS["/researchmgr"] = function()
        if LibAddonMenu2 then
            LibAddonMenu2:OpenToPanel(_G[RM.ADDON_NAME .. "_Panel"])
        end
    end
end

local function OnAddOnLoaded(_, name)
    if name ~= ADDON_NAME then return end
    EVENT_MANAGER:UnregisterForEvent(ADDON_NAME, EVENT_ADD_ON_LOADED)

    RM.db = ZO_SavedVars:NewAccountWide(
        "ResearchManager_SavedVars",
        RM.VERSION,
        nil,
        RM.DEFAULTS
    )

    -- Acquire our LibLazyCrafting handle. Required-dep, so it's loaded by now.
    -- Two things happen in the callback:
    --   1. Debug log every event.
    --   2. On LLC_CRAFT_SUCCESS, parse our reference field for the recipient
    --      and bind the new item's UUID -> recipient in SavedVars so the
    --      auto-research step machine knows this item belongs to that
    --      character specifically (see Crafter.ItemIsForCurrentCharacter).
    RM.LLC = LibLazyCrafting:AddRequestingAddon(ADDON_NAME, true, function(event, station, result)
        RM:Log("LLC event=%s station=%s ref=%s",
            tostring(event), tostring(station), tostring(result and result.reference))
        if event == LLC_CRAFT_SUCCESS and result and result.reference then
            local recipientName, ct, line, trait =
                result.reference:match("^RM:(.-):(%d+):(%d+):(%d+)$")
            local charKey = recipientName and RM.Crafter and RM.Crafter:FindCharKeyByName(recipientName)
            if charKey then
                -- LLC's smithing success path (Smithing.lua:1580) sends a
                -- shallow copy of the queue entry plus bag/slot and does NOT
                -- include uniqueId or link. Only the stackable-craft path
                -- used by alchemy/provisioning (LibLazyCrafting.lua:313)
                -- populates those fields. Pull both ourselves from bag/slot
                -- when the result table doesn't carry them.
                local uniqueId = result.uniqueId
                local bag, slot = result.bag, result.slot
                if not uniqueId and bag and slot then
                    uniqueId = GetItemUniqueId(bag, slot)
                end
                local itemLink = result.link
                if (not itemLink or itemLink == "") and bag and slot then
                    itemLink = GetItemLink(bag, slot)
                end
                if uniqueId then
                    local uuidKey = Id64ToString(uniqueId)
                    RM.db.craftedFor = RM.db.craftedFor or {}
                    RM.db.craftedFor[uuidKey] = {
                        recipient    = charKey,
                        when         = GetTimeStamp(),
                        itemLink     = itemLink,
                        craftingType = tonumber(ct),
                        lineIndex    = tonumber(line),
                        traitIndex   = tonumber(trait),
                    }
                    RM:Log("Bound %s -> %s", uuidKey, charKey)
                else
                    RM:Log("LLC success had no uniqueId or bag/slot to recover one; binding skipped (ref=%s)",
                        tostring(result.reference))
                end
            end
        end
    end)

    -- Migrate / repair: ensure all default keys exist (the constructor only
    -- copies defaults on first init).
    for k, v in pairs(RM.DEFAULTS) do
        if RM.db[k] == nil then RM.db[k] = v end
    end

    RM:InitSettings()
    RM.UI:InstallTooltipHooks()
    RM.UI:InstallActionHooks()
    RM.UI:InitWindow()
    RegisterSlashCommands()

    EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_PLAYER_ACTIVATED, OnPlayerActivated)
    EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_SMITHING_TRAIT_RESEARCH_STARTED, OnResearchStarted)
    EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_SMITHING_TRAIT_RESEARCH_COMPLETED, OnResearchCompleted)
    EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_SMITHING_TRAIT_RESEARCH_CANCELED, OnResearchCanceled)
    EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_SMITHING_TRAIT_RESEARCH_TIMES_UPDATED, OnResearchTimesUpdated)

    EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_INVENTORY_SINGLE_SLOT_UPDATE, OnSingleSlotUpdate)
    EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_CRAFTING_STATION_INTERACT, OnCraftingStationInteract)
    EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_END_CRAFTING_STATION_INTERACT, OnCraftingStationEnd)
    EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_OPEN_BANK, OnBankOpen)
end

EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_ADD_ON_LOADED, OnAddOnLoaded)
