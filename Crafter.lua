local RM = ResearchManager
RM.Crafter = {}
local Crafter = RM.Crafter

-- =============================================================================
-- New-item detection during crafting
-- =============================================================================
-- We watch EVENT_INVENTORY_SINGLE_SLOT_UPDATE for isNewItem=true while inside
-- a smithing crafting station, then check whether the new item should be
-- earmarked for an alt that hasn't researched its trait yet.

local inSmithingStation = false
local activeCraftType = nil

-- Craft types whose stations have smithing trait research (and the gifting
-- new-item flow). The other LLC craft types -- enchanting, alchemy,
-- provisioning -- still autocraft from the queue, so they get the auto-exit
-- orchestration but no research and no inSmithingStation gifting hooks.
local RESEARCH_CRAFTS = {
    [CRAFTING_TYPE_BLACKSMITHING]   = true,
    [CRAFTING_TYPE_CLOTHIER]        = true,
    [CRAFTING_TYPE_WOODWORKING]     = true,
    [CRAFTING_TYPE_JEWELRYCRAFTING] = true,
}
local AUTOEXIT_CRAFTS = {
    [CRAFTING_TYPE_ENCHANTING]   = true,
    [CRAFTING_TYPE_ALCHEMY]      = true,
    [CRAFTING_TYPE_PROVISIONING] = true,
}

-- Per-visit bookkeeping for the optional auto-exit (db.autoExitAtStation).
--
-- A fresh `visit` table is created on every OnStationEnter and stored in
-- `activeVisit`. Every deferred callback in the wait -> research -> exit chain
-- carries the visit it belongs to and checks VisitIsCurrent(visit) before acting.
-- This makes the chain re-entrancy safe: if the player leaves and re-enters the
-- same station type within the poll window, a second chain starts under a new
-- visit, `activeVisit` is replaced, and the stale chain detects the mismatch and
-- bails -- instead of corrupting the new visit's counters or doing duplicate
-- research/auto-exit. (The old design used two shared module upvalues, which the
-- second chain would overwrite while the first was still reading them.)
--
-- Per-visit fields:
--   craftingType:   the station this visit is for.
--   pendingAtEntry: LLC requests queued for this station when we arrived, so we
--                   can tell whether LLC actually crafted anything (queue shrank).
--   llcCrafted:     true once we observe the queue drained from a non-zero entry
--                   count -- i.e. LLC really crafted a queued item this visit.
-- Auto-exit fires only when something happened -- a research was started OR a
-- queued item was crafted -- never on an idle visit.
local activeVisit = nil

local function VisitIsCurrent(visit)
    return visit ~= nil and visit == activeVisit
end

function Crafter:OnStationEnter(_, craftingType)
    if RESEARCH_CRAFTS[craftingType] then
        inSmithingStation = true
        activeCraftType = craftingType
    elseif not AUTOEXIT_CRAFTS[craftingType] then
        return  -- not a station we automate
    end
    -- New visit supersedes any chain still running from a previous entry.
    local visit = { craftingType = craftingType, pendingAtEntry = 0, llcCrafted = false }
    activeVisit = visit
    -- Defer one frame so the station UI has finished initializing (and, for
    -- research stations, the research line data is populated) before we touch
    -- it, then gate our station actions behind any in-flight LibLazyCrafting
    -- crafting so research extraction / auto-exit doesn't race LLC's animation.
    zo_callLater(function() Crafter:WaitForLLCThenStationActions(visit, 1) end, 250)
end

function Crafter:OnStationLeave()
    inSmithingStation = false
    activeCraftType = nil
    -- Drop the visit so any in-flight deferred chain bails on its next tick.
    activeVisit = nil
end

-- For the (alt, craftingType, itemTraitType, item category) tuple, identify the
-- single research line the item maps to, if unambiguous. Returns lineIndex,
-- traitIndex, lineName on success; nil otherwise.
local function ResolveLineForAlt(altSnap, craftingType, itemTraitType, itemCategory)
    local craft = altSnap.crafts and altSnap.crafts[craftingType]
    if not craft then return nil end

    local matches = {}
    for lineIndex, line in pairs(craft.lines) do
        for traitIndex, trait in pairs(line.traits) do
            if trait.type == itemTraitType and not trait.known and not trait.researching then
                local cat = GetItemTraitTypeCategory(trait.type)
                if cat == itemCategory then
                    matches[#matches + 1] = {
                        lineIndex = lineIndex,
                        traitIndex = traitIndex,
                        lineName = line.name,
                    }
                end
            end
        end
    end
    if #matches == 0 then return nil end
    -- May be ambiguous (e.g. an Axe-shaped item also matches a different
    -- weapon-type line). Return the first match — the alt's research UI will
    -- show the actual valid target at station time.
    return matches[1]
end

local function ItemBroadCategory(itemLink)
    local traitType = GetItemLinkTraitInfo(itemLink)
    if traitType == ITEM_TRAIT_TYPE_NONE or traitType == nil then return nil, nil end
    if RM:ItemLinkHasSet(itemLink) then return nil, nil end  -- set items can't be researched
    local cat = GetItemTraitTypeCategory(traitType)
    if not RM:IsResearchableTraitCategory(cat) then return nil, nil end
    return cat, traitType
end

local function FindRecipients(itemLink)
    local craftingType = GetItemLinkCraftingSkillType(itemLink)
    if not RM.CRAFT_SET[craftingType] then return nil end

    local category, itemTraitType = ItemBroadCategory(itemLink)
    if not category then return nil end

    local myKey = RM:GetCharacterKey()
    local recipients = {}
    for charKey, snap in pairs(RM.db.characters or {}) do
        if charKey ~= myKey then
            local match = ResolveLineForAlt(snap, craftingType, itemTraitType, category)
            if match then
                recipients[#recipients + 1] = {
                    name = snap.name or charKey,
                    lineName = match.lineName,
                }
            end
        end
    end

    if #recipients == 0 then return nil end
    return recipients, itemTraitType
end

-- =============================================================================
-- FCO ItemSaver integration
-- =============================================================================
-- FCOIS is a required dependency, so the manifest guarantees it's loaded.

local function MarkResearchItem(bagId, slotIndex)
    if FCOIS.IsMarked(bagId, slotIndex, FCOIS_CON_ICON_RESEARCH) then
        return true
    end
    return FCOIS.MarkItem(bagId, slotIndex, FCOIS_CON_ICON_RESEARCH, true, true) ~= false
end

-- =============================================================================
-- Handle a freshly crafted item
-- =============================================================================

function Crafter:ProcessNewItem(bagId, slotIndex)
    if not (RM.db and RM.db.autoMarkGiftItems) then return end
    if not inSmithingStation then return end

    local itemLink = GetItemLink(bagId, slotIndex)
    if not itemLink or itemLink == "" then return end

    local recipients = FindRecipients(itemLink)
    if not recipients then return end

    -- Mark the item with the FCOIS Research icon so it's protected from
    -- accidental deconstruct/sell/etc. Transfer to the recipient happens via
    -- bank for this player, so we don't print a "mail to" instruction --
    -- the bindings section of the GUI shows the recipient.
    MarkResearchItem(bagId, slotIndex)
end

-- Called by the global single-slot-update handler when an item is added.
function Crafter:OnItemAdded(bagId, slotIndex)
    if not inSmithingStation then return end
    -- Defer briefly so the link is fully populated.
    zo_callLater(function() Crafter:ProcessNewItem(bagId, slotIndex) end, 50)
end

-- =============================================================================
-- Auto-deposit research items into the bank
-- =============================================================================
-- Items crafted for an alt's research sit in the crafting character's backpack,
-- bound by UUID (in RM.db.craftedFor) to a recipient. The hand-off to that
-- recipient runs through the account bank: this character deposits, the
-- recipient logs in elsewhere and withdraws/researches. When the bank opens we
-- push every backpack item bound to *another* character into the bank. Items
-- bound to the current character are left alone -- those are meant to be
-- researched here (auto-research handles them at the station), not shipped off.
--
-- RequestMoveItem is a protected function; addon (tainted) code reaches it via
-- CallSecureProtected. Bank transfers don't require a hardware event, so calling
-- it from the EVENT_OPEN_BANK handler is allowed and doesn't taint -- we never
-- feed a return value back into secure code.

local BANK_DEST_BAGS = { BAG_BANK, BAG_SUBSCRIBER_BANK }

-- Claim the next empty destination slot across the bank bags, honoring a
-- per-bag "already used this pass" set so two deposits issued in the same frame
-- don't both target the same slot before the queued moves settle. An empty slot
-- reports an empty item link. The ESO Plus subscriber bank is only considered
-- while subscribed -- its slots are inaccessible otherwise.
local function ClaimEmptyBankSlot(usedByBag)
    for _, destBag in ipairs(BANK_DEST_BAGS) do
        local usable = true
        if destBag == BAG_SUBSCRIBER_BANK then
            usable = type(IsESOPlusSubscriber) == "function" and IsESOPlusSubscriber()
        end
        if usable then
            local size = GetBagSize(destBag) or 0
            local used = usedByBag[destBag]
            for slot = 0, size - 1 do
                if not used[slot] then
                    local link = GetItemLink(destBag, slot)
                    if not link or link == "" then
                        used[slot] = true
                        return destBag, slot
                    end
                end
            end
        end
    end
    return nil, nil
end

-- Walk the backpack and deposit every item bound to another character into the
-- bank. Slot indices are stable across moves (ESO inventories don't compact),
-- so issuing moves mid-scan doesn't disturb the slots we haven't visited yet.
function Crafter:DepositResearchItemsToBank()
    if not (RM.db and RM.db.autoDepositResearchItems) then return end
    if not RM.db.craftedFor then return end
    if type(CallSecureProtected) ~= "function" then return end

    local myKey = RM:GetCharacterKey()
    local usedByBag = {}
    for _, destBag in ipairs(BANK_DEST_BAGS) do usedByBag[destBag] = {} end

    local deposited, noRoom = 0, false
    local bagSize = GetBagSize(BAG_BACKPACK)
    for slotIndex = 0, bagSize - 1 do
        local uuid = GetItemUniqueId(BAG_BACKPACK, slotIndex)
        local uuidKey = uuid and Id64ToString(uuid) or nil
        local entry = uuidKey and RM.db.craftedFor[uuidKey]
        if type(entry) == "table" and entry.recipient and entry.recipient ~= myKey then
            local destBag, destSlot = ClaimEmptyBankSlot(usedByBag)
            if not destBag then
                noRoom = true
                break
            end
            local stackCount = (GetSlotStackSize and GetSlotStackSize(BAG_BACKPACK, slotIndex)) or 1
            if not stackCount or stackCount < 1 then stackCount = 1 end
            local ok = pcall(CallSecureProtected, "RequestMoveItem",
                BAG_BACKPACK, slotIndex, destBag, destSlot, stackCount)
            if ok then
                deposited = deposited + 1
                RM:Log("Deposited %s -> bank (recipient %s)", tostring(uuidKey), tostring(entry.recipient))
            else
                RM:Log("Bank deposit failed for slot %d (uuid %s)", slotIndex, tostring(uuidKey))
            end
        end
    end

    if deposited > 0 then
        RM:AnnounceGood(zo_strformat(GetString(SI_RM_BANK_DEPOSITED), deposited))
    end
    if noRoom then
        RM:AnnounceWarn(GetString(SI_RM_BANK_FULL))
    end
end

-- =============================================================================
-- LibLazyCrafting queueing for alts
-- =============================================================================

-- Walk matIndex 1..maxMatIndex, score each by max craftable items (count /
-- per-item cost). Tie-break by lower per-item cost so within a single material
-- tier we pick the cheaper variant (e.g. CP150 over CP160 when both use the
-- same materials).
--
-- NOTE on LLC call convention: GetMatRequirements and isSmithingLevelValid are
-- attached to the addon handle (RM.LLC) but are NOT written method-style --
-- their signatures are (pattern, index, station) and (isCP, lvl) with no
-- `self` first arg. Calling them with `:` would shift every argument by one
-- and hand them the handle as `pattern`. Always use dot notation here.
local MAX_MAT_INDEX = 41
function Crafter:PickAutoLevel(craftingType, patternIndex)
    if not RM.LLC then return nil end
    local best = nil
    for matIndex = 1, MAX_MAT_INDEX do
        local _, _, _, _, _, _, _, _, _, _, level, isCP = GetSmithingPatternMaterialItemInfo(patternIndex, matIndex)
        if level and level > 0 then
            local count = GetCurrentSmithingMaterialItemCount(patternIndex, matIndex) or 0
            local perItem = RM.LLC.GetMatRequirements(patternIndex, matIndex, craftingType)
            if count > 0 and perItem and perItem > 0 then
                local maxItems = math.floor(count / perItem)
                if maxItems > 0 then
                    local better = not best
                        or maxItems > best.maxItems
                        or (maxItems == best.maxItems and perItem < best.perItem)
                    if better then
                        best = {
                            matIndex = matIndex, level = level, isCP = isCP,
                            count = count, perItem = perItem, maxItems = maxItems,
                        }
                    end
                end
            end
        end
    end
    return best
end

-- Resolve the actual (level, isCP) we'll pass to LLC based on settings.
-- Returns level, isCP, autoInfo (table or nil for FIXED).
function Crafter:ResolveLevel(craftingType, patternIndex)
    if RM.db.craftLevelMode == "AUTO" then
        local pick = self:PickAutoLevel(craftingType, patternIndex)
        if pick then return pick.level, pick.isCP, pick end
        -- Fall through to fixed if auto found nothing usable.
    end
    return RM.db.craftFixedLevel, RM.db.craftFixedIsCP, nil
end

local function GetFreeSlots(snap, craftingType)
    -- Delegated to Scanner so research that expired since the alt's last
    -- snapshot (saved activeSlots is stale) still counts toward free capacity.
    return RM.Scanner:GetEffectiveFreeSlots(snap, craftingType)
end

-- Look up a saved snapshot by case-insensitive character name.
function Crafter:FindCharKeyByName(name)
    local lower = name:lower()
    for charKey, snap in pairs(RM.db.characters or {}) do
        if snap.name and snap.name:lower() == lower then
            return charKey
        end
    end
    return nil
end

-- Parse our `RM:<recipient>:<craft>:<line>:<trait>` reference (built in QueueOne)
-- into its parts. Returns recipient, craftingType, lineIndex, traitIndex; any may
-- be nil if the reference didn't match (e.g. a foreign or malformed reference).
local function ParseRef(ref)
    if type(ref) ~= "string" then return nil end
    local name, ct, line, trait = ref:match("^RM:(.-):(%d+):(%d+):(%d+)$")
    if not name then return nil end
    return name, tonumber(ct), tonumber(line), tonumber(trait)
end

-- Iterate every request in OUR LibLazyCrafting queue. getAddonCraftingQueue is
-- per-addon, so every entry is ours; fn is called as
-- fn(station, req, recipient, craftingType, lineIndex, traitIndex) with the last
-- four already parsed from req.reference via ParseRef (any may be nil for an
-- unparseable reference -- req itself is always valid). Each call site applies
-- its own match/guard logic inside fn.
--
-- This is a LIVE walk of the queue: callers that cancel or remove requests must
-- snapshot what they need first and mutate after the walk returns (see
-- CancelAllLLCRequests), never from inside fn.
function Crafter:ForEachOwnRequest(fn)
    if not RM.LLC then return end
    local queue = RM.LLC:getAddonCraftingQueue()
    if type(queue) ~= "table" then return end
    for station, stationQueue in pairs(queue) do
        if type(stationQueue) == "table" then
            for _, req in ipairs(stationQueue) do
                local recipient, ct, line, trait = ParseRef(req.reference)
                fn(station, req, recipient, ct, line, trait)
            end
        end
    end
end

-- A research line accepts only ONE trait being researched at a time, so once a
-- line is spoken for we must not craft (or auto-research) a second trait for it
-- -- the recipient could never start it until the first finishes. Build the set
-- of (craft, line) keys ("ct:line") already spoken for, for a recipient. A line
-- is blocked when:
--   (a) the recipient is actively researching some trait on it (their snapshot,
--       honoring expiry -- research that finished offline frees the line),
--   (b) an item is already bound to the recipient for that line (craftedFor,
--       awaiting research), or
--   (c) an LLC craft request for that line is still pending for the recipient.
-- This supersedes the older trait-level "already queued this exact trait" check:
-- blocking the whole line is stronger and matches how research really works.
local function BlockedLineKeys(charKey, recipientName, altSnap, now)
    now = now or GetTimeStamp()
    local blocked = {}

    -- (a) active research on the recipient's own snapshot.
    if altSnap and altSnap.crafts then
        for ct, craft in pairs(altSnap.crafts) do
            for lineIndex, line in pairs(craft.lines or {}) do
                for _, trait in pairs(line.traits or {}) do
                    if trait.researching and not trait.known
                        and (not trait.endsAt or now < trait.endsAt)
                    then
                        blocked[ct .. ":" .. lineIndex] = true
                        break
                    end
                end
            end
        end
    end

    -- (b) items already bound to this recipient awaiting research.
    for _, v in pairs(RM.db.craftedFor or {}) do
        if type(v) == "table" and v.recipient == charKey
            and v.craftingType and v.lineIndex
        then
            blocked[v.craftingType .. ":" .. v.lineIndex] = true
        end
    end

    -- (c) LLC craft requests still pending for this recipient. Reference shape
    -- is "RM:<recipientName>:<craft>:<line>:<trait>" (see QueueOne).
    Crafter:ForEachOwnRequest(function(_, _, recipient, ct, line)
        if recipient == recipientName and ct and line then
            blocked[ct .. ":" .. line] = true
        end
    end)

    return blocked
end

-- Build the priority-sorted candidate list for one recipient.
-- - Considers only (craft, line, trait) tuples the current character knows
--   and the recipient doesn't.
-- - Skips entire research lines that are already spoken for (see
--   BlockedLineKeys): actively being researched, or with an item already
--   queued/crafted for the recipient. A line can only research one trait at a
--   time, so a second trait on a busy line would strand the crafted item.
-- - Sorts by user trait priority (descending), then by craft and line for
--   stable ordering.
-- - Does NOT apply slot caps or material filtering. Those run in
--   QueueForRecipient during iteration so a trait-blocked candidate can
--   fall through to the next feasible one on the same line.
function Crafter:BuildAltCraftPlan(charKey)
    local myKey = RM:GetCharacterKey()
    local mySnap = RM.db.characters and RM.db.characters[myKey]
    local altSnap = RM.db.characters and RM.db.characters[charKey]
    if not mySnap or not altSnap then return {}, 0 end

    local recipientName = altSnap.name or charKey
    local blocked = BlockedLineKeys(charKey, recipientName, altSnap)

    local candidates = {}
    for ct, altCraft in pairs(altSnap.crafts or {}) do
        for lineIndex, line in pairs(altCraft.lines or {}) do
            if not blocked[ct .. ":" .. lineIndex] then
                for traitIndex, trait in pairs(line.traits or {}) do
                    if not trait.known and not trait.researching then
                        local mine = mySnap.crafts[ct] and mySnap.crafts[ct].lines[lineIndex]
                            and mySnap.crafts[ct].lines[lineIndex].traits[traitIndex]
                        if mine and mine.known then
                            candidates[#candidates + 1] = {
                                craftingType = ct,
                                lineIndex = lineIndex,
                                traitIndex = traitIndex,
                                lineName = line.name,
                                traitType = trait.type,
                                priority = RM.Optimizer:GetPriority(trait.type),
                            }
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        if a.craftingType ~= b.craftingType then return a.craftingType < b.craftingType end
        return a.lineIndex < b.lineIndex
    end)

    return candidates, #candidates
end

-- The nine basegame racial styles. We pick the player's most plentiful one
-- (that's known for the relevant pattern) when queueing requests, instead of
-- whatever GetFirstKnownItemStyleId returns first.
local BASEGAME_STYLES = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }

local function PickBestBasegameStyle(patternIndex)
    local bestId, bestCount = nil, -1
    for _, styleId in ipairs(BASEGAME_STYLES) do
        if IsSmithingStyleKnown(styleId, patternIndex) then
            local count = GetCurrentSmithingStyleItemCount(styleId) or 0
            if count > bestCount then
                bestId = styleId
                bestCount = count
            end
        end
    end
    if bestId then return bestId end
    -- Nothing in the basegame set is known for this pattern -- defer to whatever
    -- the player has first-known so the craft still goes through.
    local fallback = GetFirstKnownItemStyleId(patternIndex)
    if fallback and fallback > 0 then return fallback end
    return 1
end

-- Trait-material gate: queueing a request that needs a trait stone we don't
-- have would just sit in LLC forever, so skip it. Base material is left to
-- the user's level/auto settings -- if FIXED and we lack the ingots, LLC will
-- pause until materials arrive (the user opted into that). Style stones come
-- from PickBestBasegameStyle and use whichever basegame style we have the
-- most of, so a true zero-stone account is the only way to fail there.
local function HasTraitMaterialForRequest(item)
    local llcTraitIndex = (item.traitType or 0) + 1
    return (GetCurrentSmithingTraitItemCount(llcTraitIndex) or 0) >= 1
end

-- =============================================================================
-- Inventory claim: use existing items instead of crafting new ones
-- =============================================================================
-- When `/research craft all` runs we'd ordinarily queue a fresh LLC craft for
-- every (alt, line, trait) gap. But if the player already has a matching item
-- sitting unflagged in their backpack (or bank), crafting another is just wasted
-- materials. Walk those bags once, then before each candidate craft try to
-- claim a matching item from the pool: mark it with the FCOIS Research icon
-- and bind it to the recipient -- exactly what the LLC success callback does
-- when a fresh craft lands. The auto-research step machine then picks the
-- item up at the recipient's station the same way.
--
-- Match is by (craftingType, traitType) + valid category. Mirrors the
-- broad-category logic the gift flow uses for new crafts (see ItemBroadCategory
-- above and the CLAUDE.md note "Gift-item line resolution is broad-category,
-- not line-precise"). The alt's research panel resolves the specific line at
-- station time -- if the item's actual line isn't a gap, it just isn't
-- auto-researched, same risk as a directly-gifted item.
--
-- Jewelry is special-cased. ESO jewelry that drops as part of a SET carries a
-- trait but can never be researched, so a plain trait+category match would
-- wrongly claim (mark + bind) set jewelry the recipient could never research.
-- The non-set, researchable jewelry the game drops is always named
-- "Exemplary <trait> <ring|necklace>", so we gate jewelry on that name and also
-- source it from the bank (where these tend to be stashed). Weapons and armor
-- keep the original backpack-only, trait-only behavior.

-- The bags BuildAssignablePool considers: always the backpack, plus the bank and
-- ESO Plus subscriber bank when the player includes banked items. Weapons and
-- armor are only ever claimed from the backpack -- see ClassifyAssignableSlot.
local function AssignablePoolBags()
    local bags = { BAG_BACKPACK }
    if RM.db and RM.db.includeBank then
        bags[#bags + 1] = BAG_BANK
        bags[#bags + 1] = BAG_SUBSCRIBER_BANK
    end
    return bags
end

-- Evaluate one inventory slot for the assignable pool. Returns a pool entry
-- (bagId/slotIndex/craftingType/traitType/uuidKey/itemLink) or nil when the slot
-- isn't a claimable research item. Applies the game's own researchability gate
-- (not set / locked / retraited / reconstructed) plus our cross-character
-- constraints: a researchable trait, not already FCOIS-research-marked or bound to
-- someone. Weapons and armor are only claimed from the backpack; jewelry may also
-- come from the bank.
local function ClassifyAssignableSlot(bagId, slotIndex)
    local itemLink = GetItemLink(bagId, slotIndex)
    if not itemLink or itemLink == "" then return nil end

    local craftingType = GetItemLinkCraftingSkillType(itemLink)
    if not RM.CRAFT_SET[craftingType] then return nil end
    if RM:ItemLinkHasSet(itemLink) then return nil end  -- set items can't be researched
    if IsItemPlayerLocked(bagId, slotIndex) then return nil end
    if FCOIS.IsMarked(bagId, slotIndex, FCOIS_CON_ICON_RESEARCH) then return nil end

    local info = GetItemTraitInformation(bagId, slotIndex)
    if info == ITEM_TRAIT_INFORMATION_RETRAITED
        or info == ITEM_TRAIT_INFORMATION_RECONSTRUCTED
    then
        return nil
    end

    -- Researchable trait only. This is the locale-independent replacement for the
    -- old "Exemplary" jewelry name check (see ISSUES.md B2): membership in
    -- RESEARCHABLE_TRAIT_SET is intrinsic to the item and language-independent, and
    -- excludes NONE, Ornate/Intricate, and companion traits across all three
    -- crafts. (Set items are already filtered above; a researchable trait also
    -- implies a researchable category, so this subsumes the old category check.)
    local traitType = GetItemLinkTraitInfo(itemLink)
    if not RM:IsResearchableTrait(traitType) then return nil end

    -- Weapons and armor are only claimed from the backpack; jewelry may also be
    -- sourced from the bank, where researchable drops tend to be stashed.
    if craftingType ~= CRAFTING_TYPE_JEWELRYCRAFTING and bagId ~= BAG_BACKPACK then
        return nil
    end

    local uuid = GetItemUniqueId(bagId, slotIndex)
    local uuidKey = uuid and Id64ToString(uuid) or nil
    if uuidKey and RM.db.craftedFor and RM.db.craftedFor[uuidKey] then return nil end

    return {
        bagId = bagId,
        slotIndex = slotIndex,
        craftingType = craftingType,
        traitType = traitType,
        uuidKey = uuidKey,
        itemLink = itemLink,
    }
end

function Crafter:BuildAssignablePool()
    local pool = {}
    for _, bagId in ipairs(AssignablePoolBags()) do
        local bagSize = GetBagSize(bagId) or 0
        for slotIndex = 0, bagSize - 1 do
            local entry = ClassifyAssignableSlot(bagId, slotIndex)
            if entry then pool[#pool + 1] = entry end
        end
    end
    return pool
end

-- Pop the first pool entry matching the candidate's (craftingType, traitType).
local function ClaimMatchingItem(pool, candidate)
    if not pool then return nil end
    for i, item in ipairs(pool) do
        if item.craftingType == candidate.craftingType
            and item.traitType == candidate.traitType
        then
            table.remove(pool, i)
            return item
        end
    end
    return nil
end

-- Mark and bind an inventory item as if LibLazyCrafting had just completed a
-- craft for the recipient. Mirrors the LLC_CRAFT_SUCCESS handler in
-- ResearchManager.lua: FCOIS Research mark + craftedFor entry keyed by UUID.
function Crafter:AssignInventoryItem(item, charKey, candidate)
    MarkResearchItem(item.bagId, item.slotIndex)
    if item.uuidKey then
        RM.db.craftedFor = RM.db.craftedFor or {}
        RM.db.craftedFor[item.uuidKey] = {
            recipient    = charKey,
            when         = GetTimeStamp(),
            itemLink     = item.itemLink,
            craftingType = candidate.craftingType,
            lineIndex    = candidate.lineIndex,
            traitIndex   = candidate.traitIndex,
        }
        RM:Log("Claimed inventory item %s -> %s (%d/%d/%d)",
            item.uuidKey, charKey,
            candidate.craftingType, candidate.lineIndex, candidate.traitIndex)
    end
end

-- Submit a single (craft, line, trait) request to LibLazyCrafting.
-- Returns true if queued, false otherwise.
function Crafter:QueueOne(item, recipientName)
    if not RM.LLC then return false end
    local patternIndex = LibLazyCrafting.getPatternFromResearchLine(item.craftingType, item.lineIndex)
    if not patternIndex then return false end

    local level, isCP, autoInfo = self:ResolveLevel(item.craftingType, patternIndex)
    if not level or not RM.LLC.isSmithingLevelValid(isCP, level) then
        RM:Log("Skipped: invalid level %s (CP=%s) for pattern %s", tostring(level), tostring(isCP), tostring(patternIndex))
        return false
    end

    -- Use the most plentiful known basegame style instead of the first one
    -- that comes back. Keeps the player burning through stock they actually
    -- have rather than rare materials they're hoarding.
    local styleIndex = PickBestBasegameStyle(patternIndex)

    -- LLC's CraftSmithingItem trait index is ITEM_TRAIT_TYPE_* + 1
    -- (Smithing.lua:397,971 -- LLC subtracts 1 internally to compare with
    -- GetSmithingResearchLineTraitInfo).
    local llcTraitIndex = (item.traitType or 0) + 1

    local reference = string.format("RM:%s:%d:%d:%d",
        recipientName or "?", item.craftingType, item.lineIndex, item.traitIndex)

    RM.LLC:CraftSmithingItemByLevel(
        patternIndex,                                       -- pattern (line, for blacksmithing/jewelry)
        isCP,                                               -- bool
        level,                                              -- int
        styleIndex,                                         -- style
        llcTraitIndex,                                      -- trait (offset by +1)
        false,                                              -- useUniversalStyleItem
        item.craftingType,                                  -- station
        LibLazyCrafting.INDEX_NO_SET or 0,                  -- setIndex (non-set)
        RM.db.craftQuality,                                 -- quality
        true,                                               -- autocraft
        reference                                           -- our reference
    )

    if autoInfo and RM.db.debug then
        RM:Log("Auto-picked level %s%d (matIndex %d, %d/item, %d craftable)",
            isCP and "CP" or "L", level, autoInfo.matIndex, autoInfo.perItem, autoInfo.maxItems)
    end
    return true
end

-- Count research slots already "spoken for" by items destined for this
-- recipient that aren't researched yet: items sitting in the research queue
-- (craftedFor -- crafted, awaiting research) plus requests still pending in the
-- LLC craft queue (awaiting crafting). Each will consume a research slot once
-- it reaches the recipient, so it must be deducted from their free slots before
-- queueing additional crafts -- otherwise we over-queue past what the character
-- can ever research. Returns a table keyed by craftingType.
function Crafter:CountReservedSlots(charKey, recipientName)
    local reserved = {}

    -- Research queue: crafted items bound to this recipient (keyed by charKey).
    for _, v in pairs(RM.db.craftedFor or {}) do
        if type(v) == "table" and v.recipient == charKey and v.craftingType then
            reserved[v.craftingType] = (reserved[v.craftingType] or 0) + 1
        end
    end

    -- Craft queue: LLC requests still pending for this recipient. The reference
    -- we build in QueueOne is "RM:<recipientName>:<craft>:<line>:<trait>".
    self:ForEachOwnRequest(function(_, _, recipient, ct)
        if recipient == recipientName and ct then
            reserved[ct] = (reserved[ct] or 0) + 1
        end
    end)

    return reserved
end

-- Queue items for a single recipient. Returns number queued.
--
-- Walks the priority-sorted candidate list once. For each entry: skip if
-- the recipient's slots are full or this line is already taken; skip
-- WITHOUT taking the line if the current character is out of the trait
-- stone (so the next iteration can try a different trait on the same
-- research line); otherwise queue and mark the line.
--
-- Free slots are computed net of already-reserved items (see CountReservedSlots)
-- so the research queue and craft queue stay in sync with the character's actual
-- research capacity across repeated Queue presses.
function Crafter:QueueForRecipient(charKey, assignablePool, craftFilter)
    local snap = RM.db.characters and RM.db.characters[charKey]
    if not snap then return 0 end
    local recipientName = snap.name or charKey

    local candidates, totalGaps = self:BuildAltCraftPlan(charKey)

    -- Slots already taken by pending crafts/research for this recipient. The
    -- effective free count per craft is the raw free slots minus these.
    local reserved = self:CountReservedSlots(charKey, recipientName)
    local function EffectiveFree(ct)
        return math.max(0, GetFreeSlots(snap, ct) - (reserved[ct] or 0))
    end

    -- Optional per-skill restriction (used by the "Queue" button next to a
    -- single skill row in the window). Reduce candidates and the slot ceiling
    -- to the requested craft only so we don't accidentally bleed into other
    -- crafts when the user explicitly asked for one.
    local totalFree
    if craftFilter then
        local filtered = {}
        for _, c in ipairs(candidates) do
            if c.craftingType == craftFilter then filtered[#filtered + 1] = c end
        end
        candidates = filtered
        totalGaps = #filtered
        totalFree = EffectiveFree(craftFilter)
    else
        totalFree = 0
        for _, ct in ipairs(RM.CRAFTS) do
            totalFree = totalFree + EffectiveFree(ct)
        end
    end

    if totalGaps == 0 then
        RM:Announce(zo_strformat(GetString(SI_RM_CRAFT_NO_GAPS), recipientName))
        return 0
    end
    if totalFree == 0 then
        RM:Announce(zo_strformat(GetString(SI_RM_CRAFT_NO_FREE_SLOTS), recipientName))
        return 0
    end

    local takenPerCraft = {}
    local takenLineKey = {}
    local queued = 0
    local claimed = 0
    local skippedNoTrait = 0

    for _, c in ipairs(candidates) do
        if queued >= totalFree then break end
        local lineKey = c.craftingType .. ":" .. c.lineIndex
        if not takenLineKey[lineKey] then
            local free = EffectiveFree(c.craftingType)
            local used = takenPerCraft[c.craftingType] or 0
            if used < free then
                -- Prefer an already-owned matching item over spending mats on
                -- a fresh craft. ClaimMatchingItem mutates the pool so a
                -- subsequent alt in the same /research craft all run can't
                -- double-claim the same slot.
                local claimedItem = ClaimMatchingItem(assignablePool, c)
                if claimedItem then
                    self:AssignInventoryItem(claimedItem, charKey, c)
                    takenLineKey[lineKey] = true
                    takenPerCraft[c.craftingType] = used + 1
                    queued = queued + 1
                    claimed = claimed + 1
                elseif HasTraitMaterialForRequest(c) then
                    if self:QueueOne(c, recipientName) then
                        takenLineKey[lineKey] = true
                        takenPerCraft[c.craftingType] = used + 1
                        queued = queued + 1
                    end
                else
                    skippedNoTrait = skippedNoTrait + 1
                    -- Deliberately leave the line unmarked: a different trait
                    -- on the same line may have its stone in stock.
                end
            end
        end
    end

    local crafted = queued - claimed
    RM:AnnounceGood(
        zo_strformat(GetString(SI_RM_CRAFT_QUEUED), crafted, recipientName)
        .. string.format(" (%d/%d free research slots used)", queued, totalFree))
    if claimed > 0 then
        CHAT_SYSTEM:AddMessage("  " .. zo_strformat(
            GetString(SI_RM_CRAFT_CLAIMED_FROM_INVENTORY), claimed, recipientName))
    end
    if skippedNoTrait > 0 then
        CHAT_SYSTEM:AddMessage(string.format(
            "  %d item(s) skipped: missing trait stone.", skippedNoTrait))
    end
    local unfilled = totalGaps - queued - skippedNoTrait
    if unfilled > 0 and queued < totalFree then
        CHAT_SYSTEM:AddMessage(string.format(
            "  %d additional gap(s) unfilled: only %d slot(s) free.",
            unfilled, totalFree))
    end
    return queued
end

-- Queue items for every alt. Returns total queued.
--
-- Build the assignable-inventory pool once and share it across alts so an
-- item claimed for one recipient isn't double-claimed by the next. Alts are
-- iterated via pairs() which is undefined-order, so for an account with many
-- alts the recipient an item lands with is effectively first-fit -- fine for
-- the common "I've got a few spare items, who needs them" case.
function Crafter:QueueForAll()
    local myKey = RM:GetCharacterKey()
    local pool = self:BuildAssignablePool()
    local total = 0
    for charKey in pairs(RM.db.characters or {}) do
        if charKey ~= myKey then
            total = total + self:QueueForRecipient(charKey, pool)
        end
    end
    if total == 0 then
        RM:Announce("Nothing queued.")
    end
    return total
end

-- =============================================================================
-- Station-entry automation
-- =============================================================================
-- Opening a crafting station kicks off up to three automated stages, chained
-- across frames with zo_callLater because the engine needs time to settle
-- between crafting and inventory operations. The call graph, top to bottom:
--
--   OnStationEnter
--    \- WaitForLLCThenStationActions   wait out LibLazyCrafting's queued crafts
--        \- AfterLLCDrained            choose the next stage
--            |- AutoResearchAtStation  research stations, if auto-research is on
--            |   \- RunAutoResearchStep   serialized one-at-a-time research loop
--            |       \- OnStationActionsComplete
--            \- OnStationActionsComplete  (non-research stations / research off)
--                \- AutoExitStation     close the station, if the visit did work
--
-- The WaitFor.../...Step functions are deferred polls: each call does one tick
-- of work, then either finishes or re-schedules itself with stepNum + 1 until a
-- safety cap (the *_MAX_STEPS constants) bounds the wait.

-- ---- Timing: poll interval + safety cap for each deferred stage -------------

-- Spacing between consecutive ResearchSmithingTrait calls. ESO's extraction
-- animation (CraftingSmithingExtractSlotAnimation) plays Phase 1 + Phase 2
-- over ~1.2s and its OnStop handler races itself if a second extraction
-- starts before the previous burst's owner pointer is cleared, throwing
-- "attempt to index a nil value" at extractslotanimation.lua:34. 1500ms
-- gives the engine enough headroom to complete both phases cleanly.
local AUTO_RESEARCH_INTERVAL_MS = 1500
local AUTO_RESEARCH_MAX_STEPS   = 10   -- safety upper bound

-- LLC crafts one item per EVENT_CRAFT_COMPLETED cycle (~1-2s each), so a 500ms
-- poll catches the drained state promptly. The cap bounds a queue that never
-- drains (e.g. a request LLC can't fulfill for lack of mats sits there forever)
-- so we don't wait indefinitely once nothing is actually animating.
local LLC_WAIT_INTERVAL_MS = 500
local LLC_WAIT_MAX_STEPS   = 120  -- ~60s

-- Cadence + cap while waiting for a final craft/extract animation to settle
-- before closing. EndInteraction during an active craft animation can leave the
-- engine mid-process, so we hold off until idle.
local AUTO_EXIT_SETTLE_INTERVAL_MS = 400
local AUTO_EXIT_MAX_STEPS          = 25   -- ~10s safety

-- ---- Shared helpers ---------------------------------------------------------

local function IsFCOISResearchMarked(bagId, slotIndex)
    return FCOIS.IsMarked(bagId, slotIndex, FCOIS_CON_ICON_RESEARCH)
end

-- True if ANY unknown trait on this research line is currently being researched.
-- A line researches one trait at a time, so a busy line can't accept a new
-- start on a *different* trait until the in-progress one finishes -- attempting
-- it would waste the freed slot on an item the game won't accept. Mirrors ZOS's
-- own FindResearchingTraitIndex (smithingresearch_shared.lua): scan the line and
-- treat a non-nil trait duration as "in progress". `CanItemBeSmithingTrait-
-- Researched` is per-trait and does NOT cover this, so we check it separately.
local function IsResearchLineBusy(craftingType, lineIndex)
    local _, _, numTraits = GetSmithingResearchLineInfo(craftingType, lineIndex)
    for ti = 1, (numTraits or 0) do
        local _, _, known = GetSmithingResearchLineTraitInfo(craftingType, lineIndex, ti)
        if not known and GetSmithingResearchLineTraitTimes(craftingType, lineIndex, ti) then
            return true
        end
    end
    return false
end

-- An item the addon's LLC callback recorded as crafted for a specific alt
-- must only be auto-researched by that alt -- even if it ends up in the
-- wrong character's bag via mail mix-up. Items NOT in the craftedFor map
-- (loot drops, manual crafts, anything pre-tracking) pass through; we only
-- enforce the binding when we know who an item belongs to.
local function ItemIsForCurrentCharacter(bagId, slotIndex)
    if not RM.db or not RM.db.craftedFor then return true end
    local uuid = GetItemUniqueId(bagId, slotIndex)
    if not uuid then return true end
    local key = Id64ToString(uuid)
    local entry = RM.db.craftedFor[key]
    if not entry then return true end
    return entry.recipient == RM:GetCharacterKey()
end

-- LibLazyCrafting hands every requesting addon its own per-station queue
-- (personalQueue[craftingType]); on station entry LLC autocrafts whatever is
-- queued for the active station. Research extraction shares the engine's
-- single crafting-animation pipeline (see the extractslotanimation race noted
-- on AUTO_RESEARCH_INTERVAL_MS), so starting research while LLC is mid-craft
-- collides. Count pending requests across ALL LLC addons -- not just ours --
-- so a batch queued by Dolgubon's Writ Creator / Set Crafter gates us too.
local function CountPendingLLCCrafts(craftingType)
    local tables = LibLazyCrafting and LibLazyCrafting.addonInteractionTables
    if type(tables) ~= "table" then return 0 end
    local count = 0
    for _, t in pairs(tables) do
        local pq = t.personalQueue
        local stationQueue = pq and pq[craftingType]
        if type(stationQueue) == "table" then
            -- #-count is exact: LLC removes requests with table.remove (compacting,
            -- no holes) and counts these station queues with # itself, so the
            -- sequence is always gap-free.
            count = count + #stationQueue
        end
    end
    return count
end

-- Close out the research loop: print the summary (only when we actually started
-- something) and hand off to the auto-exit finalizer. slotsRemaining is how many
-- research slots are still free now -- 0 when the loop stopped because slots ran
-- out, the remaining count when it stopped for want of candidates.
local function FinishAutoResearch(visit, started, slotsRemaining)
    if started > 0 then
        RM:Announce(zo_strformat(GetString(SI_RM_AUTO_RESEARCH_SUMMARY), started, slotsRemaining))
    end
    Crafter:OnStationActionsComplete(visit, started)
end

-- ---- Stage 1: wait out LibLazyCrafting --------------------------------------

-- Gate the station's automated actions behind LLC finishing its queued crafts.
-- Polls until the station's queue is empty and ZO_CraftingUtils_IsPerforming-
-- CraftProcess() reports idle, then dispatches via AfterLLCDrained. Used for all
-- automated station types, research-capable or not.
function Crafter:WaitForLLCThenStationActions(visit, stepNum)
    if not RM.db then return end
    -- Superseded by a newer station entry (player left and came back): bail.
    if not VisitIsCurrent(visit) then return end
    local craftingType = visit.craftingType
    -- Will we actually research here? Only on a research station with the toggle
    -- on. If not, auto-exit is the only reason to orchestrate -- bail when it's
    -- off too.
    local willResearch = RESEARCH_CRAFTS[craftingType] and RM.db.autoResearchAtStation
    if not willResearch and not RM.db.autoExitAtStation then return end
    -- Player walked away (or the station closed) before we got here.
    if GetCraftingInteractionType() ~= craftingType then return end

    local pending = CountPendingLLCCrafts(craftingType)
    local crafting = ZO_CraftingUtils_IsPerformingCraftProcess()

    -- Snapshot how many requests were queued for this station when we arrived,
    -- so the finalizer can tell whether LLC actually crafted anything (queue
    -- shrank) versus the queue being empty or stuck-uncraftable all along.
    if stepNum == 1 then visit.pendingAtEntry = pending end

    if pending == 0 and not crafting then
        visit.llcCrafted = visit.pendingAtEntry > 0
        self:AfterLLCDrained(visit)
        return
    end

    if stepNum >= LLC_WAIT_MAX_STEPS then
        -- Timed out waiting for the queue to drain. Only proceed if nothing is
        -- actively animating right now; a stuck-but-idle queue won't collide
        -- with research extraction, whereas an in-progress craft still would.
        if not crafting then
            RM:Log("LLC wait timed out with %d still queued (idle); proceeding", pending)
            visit.llcCrafted = visit.pendingAtEntry > pending
            self:AfterLLCDrained(visit)
        else
            RM:Log("LLC wait timed out while still crafting; skipping this visit")
        end
        return
    end

    zo_callLater(function()
        Crafter:WaitForLLCThenStationActions(visit, stepNum + 1)
    end, LLC_WAIT_INTERVAL_MS)
end

-- Dispatch once LLC has finished its queued crafting for the station. On a
-- research-capable station with auto-research on, hand off to the research loop
-- (its terminal points run the auto-exit finalizer); otherwise -- a non-research
-- station, or research turned off -- jump straight to the finalizer so auto-exit
-- can still fire on the strength of LLC crafting alone.
function Crafter:AfterLLCDrained(visit)
    if RESEARCH_CRAFTS[visit.craftingType] and RM.db.autoResearchAtStation then
        self:AutoResearchAtStation(visit)
    else
        self:OnStationActionsComplete(visit, 0)
    end
end

-- ---- Stage 2: auto-research -------------------------------------------------
-- We walk the player's inventory for items marked with the FCOIS Research icon
-- -- the ones the addon's gifting flow earmarked for research, never random gear
-- -- and start research on as many as free slots allow.
--
-- Multiple research starts must be SERIALIZED across frames. Calling
-- ResearchSmithingTrait consumes the source item and updates slot counts, but
-- those changes don't settle within the same frame -- a pre-built candidate
-- list pointing at "the second item to start" has stale bag/slot indices the
-- moment the first call returns, and subsequent CanItemBeSmithingTraitResearched
-- checks fail. So RunAutoResearchStep is a step machine: refresh state, pick the
-- best candidate, start it, then defer the next attempt with zo_callLater.

function Crafter:AutoResearchAtStation(visit)
    if not RM.db or not RM.db.autoResearchAtStation then return end
    -- Kick off the step machine. Tracking `skippedLines` across steps keeps
    -- us from retrying a line that the game accepted but whose state hasn't
    -- propagated to GetSmithingResearchLineTraitTimes yet.
    self:RunAutoResearchStep(visit, {}, 1, 0)
end

-- Pick the next single research candidate. Returns the best candidate (table
-- with bagId/slotIndex/lineIndex/traitIndex/lineName/traitType) or nil if no
-- valid candidate exists right now. `skippedLines` (set) is updated with any
-- line we attempt so a failed start doesn't get retried this session.
--
-- We scan every bag the inventory index covers -- backpack and (when the user
-- has the includeBank setting on) the player bank and ESO Plus subscriber
-- bank. ESO's smithing research API accepts banked items as research targets
-- from any smithing station, mirroring the game's own "Include banked items"
-- checkbox on the research UI.
function Crafter:FindNextAutoResearchCandidate(craftingType, skippedLines)
    local idx = RM.Scanner:GetInventoryIndex()
    if not idx then return nil end

    local best = nil
    for bagId, slotMap in pairs(idx.bySlot or {}) do
        for slotIndex, match in pairs(slotMap) do
            if match.craftingType == craftingType
                and not skippedLines[match.lineIndex]
                and IsFCOISResearchMarked(bagId, slotIndex)
                and ItemIsForCurrentCharacter(bagId, slotIndex)
            then
                -- Verify the trait isn't known/researching, the LINE isn't busy
                -- researching a different trait, and the item is still a valid
                -- research target right now.
                local _, _, known = GetSmithingResearchLineTraitInfo(craftingType, match.lineIndex, match.traitIndex)
                local duration = GetSmithingResearchLineTraitTimes(craftingType, match.lineIndex, match.traitIndex)
                if not known and not duration
                    and not IsResearchLineBusy(craftingType, match.lineIndex)
                    and CanItemBeSmithingTraitResearched(bagId, slotIndex, craftingType, match.lineIndex, match.traitIndex)
                then
                    local priority = RM.Optimizer:GetPriority(match.traitType)
                    if not best or priority > best.priority then
                        best = {
                            bagId = bagId, slotIndex = slotIndex,
                            lineIndex = match.lineIndex, traitIndex = match.traitIndex,
                            lineName = match.lineName, traitType = match.traitType,
                            priority = priority,
                        }
                    end
                end
            end
        end
    end
    return best
end

-- One step of the serialized auto-research loop. Each terminal path eventually
-- reaches OnStationActionsComplete (directly, or via FinishAutoResearch) so the
-- auto-exit stage always runs -- except when the player left the station.
--
-- `pending` is the candidate we called ResearchSmithingTrait on in the PREVIOUS
-- step (nil on the first step). We confirm it here rather than counting it
-- optimistically at call time: ResearchSmithingTrait can silently no-op (the item
-- became invalid between selection and the call), and `started` gates auto-exit's
-- "did this visit do something" decision -- so it must reflect real starts, not
-- attempts. Confirmation is deferred a step because the start doesn't settle
-- within the calling frame; by now (AUTO_RESEARCH_INTERVAL_MS later) the engine's
-- GetSmithingResearchLineTraitTimes reports the active research reliably.
function Crafter:RunAutoResearchStep(visit, skippedLines, stepNum, started, pending)
    -- Superseded by a newer station entry: abandon the loop, no auto-exit.
    if not VisitIsCurrent(visit) then return end
    local craftingType = visit.craftingType

    -- Confirm the previous step's research actually started before counting it.
    if pending then
        if GetSmithingResearchLineTraitTimes(craftingType, pending.lineIndex, pending.traitIndex) then
            started = started + 1
        else
            RM:Log("Auto-research: start did not take for line %d trait %d; not counting",
                pending.lineIndex, pending.traitIndex)
        end
    end

    -- Hit our safety cap: stop here but still consider auto-exit with whatever
    -- we managed to start.
    if stepNum > AUTO_RESEARCH_MAX_STEPS then
        self:OnStationActionsComplete(visit, started)
        return
    end
    -- Player walked away from the station: abandon the loop, no auto-exit.
    if GetCraftingInteractionType() ~= craftingType then return end

    -- Refresh state so slot counts reflect the previous step's completion.
    RM.Scanner:ScanResearchState()
    RM.Scanner:BuildInventoryIndex()
    local snap = RM.Scanner:GetCurrentSnapshot()
    local craft = snap and snap.crafts[craftingType]
    if not craft then
        self:OnStationActionsComplete(visit, started)
        return
    end
    local freeSlots = RM.Scanner:GetEffectiveFreeSlots(snap, craftingType)

    if freeSlots <= 0 then
        FinishAutoResearch(visit, started, 0)
        return
    end

    local c = self:FindNextAutoResearchCandidate(craftingType, skippedLines)
    if not c then
        FinishAutoResearch(visit, started, freeSlots)
        return
    end

    skippedLines[c.lineIndex] = true  -- never retry the same line in this session
    ResearchSmithingTrait(c.bagId, c.slotIndex)
    local traitName = GetString("SI_ITEMTRAITTYPE", c.traitType) or "?"
    RM:AnnounceGood(
        zo_strformat(GetString(SI_RM_AUTO_RESEARCH_STARTED),
            RM:GetCraftName(craftingType), c.lineName, traitName))

    -- Defer the next step so the game has time to update inventory + slot state.
    -- `started` is NOT incremented here: the next step confirms this start (passed
    -- as `pending`) and counts it only if the engine registered it.
    zo_callLater(function()
        Crafter:RunAutoResearchStep(visit, skippedLines, stepNum + 1, started, c)
    end, AUTO_RESEARCH_INTERVAL_MS)
end

-- ---- Stage 3: auto-exit -----------------------------------------------------
-- Once research (if any) is done, optionally close the station -- but only when
-- the visit actually did something: a research was started OR LLC crafted a
-- queued item. An idle visit (nothing queued/craftable, no new research) leaves
-- the station open so the player isn't kicked out for no reason.

function Crafter:OnStationActionsComplete(visit, researchStarted)
    if not RM.db or not RM.db.autoExitAtStation then return end
    -- Superseded by a newer station entry: don't act on a stale visit.
    if not VisitIsCurrent(visit) then return end
    -- Only exit if this visit accomplished something.
    if not visit.llcCrafted and (researchStarted or 0) <= 0 then
        RM:Log("Auto-exit: nothing crafted or researched this visit; leaving station open")
        return
    end
    self:AutoExitStation(visit, 1)
end

function Crafter:AutoExitStation(visit, stepNum)
    -- Superseded by a newer station entry: bail.
    if not VisitIsCurrent(visit) then return end
    local craftingType = visit.craftingType
    -- Station already closed or the player moved to another interaction.
    if GetCraftingInteractionType() ~= craftingType then return end
    -- Don't pull the station out from under an in-flight craft/extract anim.
    if ZO_CraftingUtils_IsPerformingCraftProcess() then
        if stepNum >= AUTO_EXIT_MAX_STEPS then
            RM:Log("Auto-exit: still animating after %d steps; leaving station open", stepNum)
            return
        end
        zo_callLater(function()
            Crafter:AutoExitStation(visit, stepNum + 1)
        end, AUTO_EXIT_SETTLE_INTERVAL_MS)
        return
    end
    RM:Log("Auto-exit: closing %s station", RM:GetCraftName(craftingType))
    EndInteraction(INTERACTION_CRAFT)
end

-- Cancel every pending request in our LLC queue. Used by the "Clear queue"
-- button in the window. Snapshots references first because cancelItemByReference
-- mutates the queue we'd otherwise be iterating.
function Crafter:CancelAllLLCRequests()
    if not RM.LLC then return 0 end
    -- Snapshot references first: cancelItemByReference mutates the queue
    -- ForEachOwnRequest is walking, so we must not cancel from inside the walk.
    local refs = {}
    self:ForEachOwnRequest(function(_, req)
        if req.reference then refs[#refs + 1] = req.reference end
    end)
    for _, ref in ipairs(refs) do
        RM.LLC:cancelItemByReference(ref)
    end
    return #refs
end

-- =============================================================================
-- LLC queue display
-- =============================================================================

local STATION_NAMES = {
    [CRAFTING_TYPE_BLACKSMITHING]   = "Blacksmithing",
    [CRAFTING_TYPE_CLOTHIER]        = "Clothier",
    [CRAFTING_TYPE_WOODWORKING]     = "Woodworking",
    [CRAFTING_TYPE_JEWELRYCRAFTING] = "Jewelry",
    [CRAFTING_TYPE_ENCHANTING]      = "Enchanting",
    [CRAFTING_TYPE_PROVISIONING]    = "Provisioning",
    [CRAFTING_TYPE_ALCHEMY]         = "Alchemy",
}

local function QualityLabel(q)
    return GetString("SI_ITEMQUALITY", q or ITEM_QUALITY_NORMAL) or tostring(q)
end

function Crafter:PrintQueue()
    if not RM.LLC then
        RM:AnnounceWarn("LibLazyCrafting handle not available.")
        return
    end
    local queue = RM.LLC:getAddonCraftingQueue()  -- nil station = all stations
    if type(queue) ~= "table" then
        CHAT_SYSTEM:AddMessage(GetString(SI_RM_QUEUE_EMPTY))
        return
    end

    -- Flatten and count.
    local entries = {}
    self:ForEachOwnRequest(function(station, req)
        entries[#entries + 1] = { station = station, req = req }
    end)
    -- Group by station type; stable tie-break on the reference string.
    table.sort(entries, function(a, b)
        if a.station ~= b.station then return a.station < b.station end
        return tostring(a.req.reference) < tostring(b.req.reference)
    end)
    if #entries == 0 then
        RM:Announce(GetString(SI_RM_QUEUE_EMPTY))
        return
    end

    RM:AnnounceHeader(zo_strformat(GetString(SI_RM_QUEUE_HEADER), #entries))
    for _, e in ipairs(entries) do
        local r = e.req
        local stationName = STATION_NAMES[e.station] or ("station " .. tostring(e.station))
        local level = r.level or "?"
        local levelTag = (r.isCP and "CP" or "L") .. tostring(level)

        -- The reference carries the (craft, line, trait) we picked at queue
        -- time. Prefer that over GetSmithingPatternInfo, which is
        -- station-context-dependent and returns empty for patterns that don't
        -- belong to the station the player is currently standing at (so a
        -- Clothier pattern 15 looked up from a Woodworking station blanks
        -- out). GetSmithingResearchLineInfo takes craftingType explicitly and
        -- always works.
        local recipient, refCraft, refLine, refTrait = ParseRef(r.reference)
        recipient = recipient or "?"

        local patternName, traitType
        if refCraft and refLine then
            local raw = GetSmithingResearchLineInfo(refCraft, refLine)
            if raw and raw ~= "" then
                patternName = zo_strformat("<<t:1>>", raw)
            end
        end
        if (not patternName or patternName == "") and r.pattern then
            local raw = GetSmithingPatternInfo(r.pattern)
            if raw and raw ~= "" then
                patternName = zo_strformat("<<t:1>>", raw)
            end
        end
        if not patternName or patternName == "" then
            patternName = "pattern " .. tostring(r.pattern or "?")
        end

        if refCraft and refLine and refTrait then
            traitType = GetSmithingResearchLineTraitInfo(refCraft, refLine, refTrait)
        end
        if not traitType then
            -- LLC stores the trait under "trait" (Smithing.lua:741), not
            -- "traitIndex", and the value is ITEM_TRAIT_TYPE_* + 1.
            traitType = (r.trait or 1) - 1
        end
        local traitName = GetString("SI_ITEMTRAITTYPE", traitType) or "?"

        CHAT_SYSTEM:AddMessage(string.format("  %s | %s | %s | %s | %s | -> %s",
            stationName, patternName, traitName, levelTag,
            QualityLabel(r.quality), recipient))
    end
end

-- =============================================================================
-- Reporting helpers
-- =============================================================================

function Crafter:PrintCraftingPlan()
    local plan = RM.Aggregate:CraftingPlanForCurrent()
    if #plan == 0 then
        RM:Announce("No alts need anything you can craft.")
        return
    end
    RM:AnnounceHeader("You can craft for:")
    for _, e in ipairs(plan) do
        local traitName = GetString("SI_ITEMTRAITTYPE", e.traitType) or "?"
        local altNames = {}
        for _, charKey in ipairs(e.recipients) do
            altNames[#altNames + 1] = RM.Aggregate:FormatCharLabel(charKey)
        end
        CHAT_SYSTEM:AddMessage(string.format("  %s / %s / %s -> %s",
            RM:GetCraftName(e.craftingType), e.lineName, traitName,
            table.concat(altNames, ", ")))
    end
end

function Crafter:PrintAltGaps()
    local snapByKey = RM.db.characters or {}
    if next(snapByKey) == nil then
        RM:Announce("No character data saved yet.")
        return
    end
    RM:AnnounceHeader("Gaps your alts have that others on the account already know:")
    for charKey, snap in pairs(snapByKey) do
        local gaps = RM.Aggregate:GapsForCharacter(charKey)
        if #gaps > 0 then
            CHAT_SYSTEM:AddMessage("|cCCCCCC" .. (snap.name or charKey) .. "|r — " .. #gaps .. " fillable")
            for i = 1, math.min(#gaps, 5) do
                local g = gaps[i]
                local traitName = GetString("SI_ITEMTRAITTYPE", g.traitType) or "?"
                local knowers = {}
                for _, k in ipairs(g.knownBy) do
                    knowers[#knowers + 1] = RM.Aggregate:FormatCharLabel(k)
                end
                CHAT_SYSTEM:AddMessage(string.format("    %s / %s / %s <- %s",
                    RM:GetCraftName(g.craftingType), g.lineName, traitName,
                    table.concat(knowers, ", ")))
            end
            if #gaps > 5 then
                CHAT_SYSTEM:AddMessage(string.format("    ... and %d more", #gaps - 5))
            end
        end
    end
end
