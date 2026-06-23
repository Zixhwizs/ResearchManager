local RM = ResearchManager
RM.Scanner = {}
local Scanner = RM.Scanner

local NUM_BACKPACK = BAG_BACKPACK
local NUM_BANK = BAG_BANK
local NUM_SUBBANK = BAG_SUBSCRIBER_BANK

-- =============================================================================
-- Research state scan
-- =============================================================================
-- Builds a snapshot of the current character's research progress.
-- Shape:
--   characters[charKey] = {
--     name = "...", account = "@...", world = "...", updatedAt = <epoch>,
--     crafts = {
--       [CRAFTING_TYPE_BLACKSMITHING] = {
--         maxSlots = 3,
--         activeSlots = 2,
--         lines = {
--           [1] = {
--             name = "Axe", numTraits = 9,
--             traits = {
--               [1] = { type = ITEM_TRAIT_TYPE_WEAPON_POWERED, known = true, researching = false },
--               [2] = { type = ..., known = false, researching = true, duration = 21600, endsAt = 1716700000 },
--               ...
--             },
--           },
--         },
--       },
--     },
--   }

function Scanner:ScanResearchState()
    local key = RM:GetCharacterKey()
    local now = GetTimeStamp()

    local snapshot = {
        name = GetUnitName("player"),
        account = GetDisplayName(),
        world = GetWorldName(),
        updatedAt = now,
        crafts = {},
    }

    for _, craftingType in ipairs(RM.CRAFTS) do
        local craftEntry = {
            maxSlots = GetMaxSimultaneousSmithingResearch(craftingType) or 0,
            activeSlots = 0,
            lines = {},
        }

        local numLines = GetNumSmithingResearchLines(craftingType)
        for lineIndex = 1, numLines do
            local lineName, _, numTraits = GetSmithingResearchLineInfo(craftingType, lineIndex)
            local lineEntry = { name = lineName, numTraits = numTraits, traits = {} }

            for traitIndex = 1, numTraits do
                local traitType, _, known = GetSmithingResearchLineTraitInfo(craftingType, lineIndex, traitIndex)
                local duration, timeRemaining = GetSmithingResearchLineTraitTimes(craftingType, lineIndex, traitIndex)

                local entry = {
                    type = traitType,
                    known = known,
                    researching = false,
                }

                if duration and timeRemaining and not known then
                    entry.researching = true
                    entry.duration = duration
                    entry.endsAt = now + timeRemaining
                    craftEntry.activeSlots = craftEntry.activeSlots + 1
                end

                lineEntry.traits[traitIndex] = entry
            end
            craftEntry.lines[lineIndex] = lineEntry
        end
        snapshot.crafts[craftingType] = craftEntry
    end

    RM.db.characters[key] = snapshot
    RM:Log("Research state scanned for %s (%d crafts)", snapshot.name, #RM.CRAFTS)
    return snapshot
end

function Scanner:GetCurrentSnapshot()
    return RM.db.characters[RM:GetCharacterKey()]
end

-- Count research slots a character has currently in use, ignoring research that
-- has expired since the snapshot was taken. The snapshot for an alt is frozen
-- at the moment that character last visited a crafting station; if the trait's
-- `endsAt` has since passed, the research is effectively complete -- the alt
-- just hasn't logged in to refresh the saved data. From the queue-planning
-- perspective the slot is free, so don't count it.
--
-- Pass `now` from GetTimeStamp() when iterating multiple crafts so they all
-- evaluate against a single consistent timestamp.
function Scanner:CountActiveSlots(snap, craftingType, now)
    if not snap or not snap.crafts or not snap.crafts[craftingType] then return 0 end
    now = now or GetTimeStamp()
    local active = 0
    for _, line in pairs(snap.crafts[craftingType].lines or {}) do
        for _, trait in pairs(line.traits or {}) do
            if trait.researching and not trait.known
                and (not trait.endsAt or now < trait.endsAt)
            then
                active = active + 1
            end
        end
    end
    return active
end

-- Known/total researchable traits for one craft on a snapshot. Used by the
-- character tree to show a "% researched" figure per skill. Returns 0,0 when
-- the character has no data for that craft (station not yet visited).
function Scanner:CountTraitProgress(snap, craftingType)
    if not snap or not snap.crafts or not snap.crafts[craftingType] then return 0, 0 end
    local known, total = 0, 0
    for _, line in pairs(snap.crafts[craftingType].lines or {}) do
        for _, trait in pairs(line.traits or {}) do
            total = total + 1
            if trait.known then known = known + 1 end
        end
    end
    return known, total
end

-- maxSlots minus CountActiveSlots, floored at 0.
function Scanner:GetEffectiveFreeSlots(snap, craftingType, now)
    if not snap or not snap.crafts or not snap.crafts[craftingType] then return 0 end
    local maxS = snap.crafts[craftingType].maxSlots or 0
    return math.max(0, maxS - self:CountActiveSlots(snap, craftingType, now))
end

-- True iff every researchable (craft, line, trait) on the snapshot is marked
-- known. Snapshots missing a craft entry count as "not done" -- we have no
-- evidence the character has visited that station yet.
function Scanner:IsAllResearched(snap)
    if not snap or not snap.crafts then return false end
    for _, ct in ipairs(RM.CRAFTS) do
        local craft = snap.crafts[ct]
        if not craft or not craft.lines then return false end
        for _, line in pairs(craft.lines) do
            for _, trait in pairs(line.traits or {}) do
                if not trait.known then return false end
            end
        end
    end
    return true
end

-- Estimated wall-clock seconds for a character to finish ALL remaining
-- research, assuming they keep every research slot busy from now on. Returns 0
-- when nothing is left.
--
-- Model: each craft researches independently and in parallel, so the
-- character's finish time is the slowest craft. Within a craft, a line can only
-- research one trait at a time (a sequential "chain"), and only maxSlots lines
-- progress at once. The makespan of that schedule is bounded below by both the
-- total remaining work divided across the slots and the single longest line
-- chain; we estimate it as the max of the two -- the standard parallel-machine
-- lower bound, and tight in practice because the costly late traits dominate.
--
-- Durations: an unstarted trait's time is RM:BaseResearchSecs(researchNumber)
-- scaled by a per-craft `factor` inferred from any trait currently in progress
-- (its real stored duration vs. its base), so the estimate reflects the
-- character's Metallurgy reduction without us hardcoding the passive values.
-- The trait already in progress contributes its actual remaining time.
function Scanner:EstimateTimeToComplete(snap, now)
    if not snap or not snap.crafts then return 0 end
    now = now or GetTimeStamp()

    local function lineKnownCount(line)
        local n = 0
        for _, trait in pairs(line.traits or {}) do
            if trait.known then n = n + 1 end
        end
        return n
    end
    local function lineNumTraits(line)
        if line.numTraits and line.numTraits > 0 then return line.numTraits end
        local n = 0
        for _ in pairs(line.traits or {}) do n = n + 1 end
        return n
    end

    local charMax = 0
    for _, ct in ipairs(RM.CRAFTS) do
        local craft = snap.crafts[ct]
        if craft then
            -- Pass 1: infer the per-craft reduction factor from in-progress
            -- research (actual stored duration vs. unreduced base).
            local facNum, facDen = 0, 0
            for _, line in pairs(craft.lines or {}) do
                local known = lineKnownCount(line)
                for _, trait in pairs(line.traits or {}) do
                    if trait.researching and trait.duration and not trait.known then
                        facNum = facNum + trait.duration
                        facDen = facDen + RM:BaseResearchSecs(known + 1)
                    end
                end
            end
            local factor = (facDen > 0) and (facNum / facDen) or 1.0

            -- Pass 2: sum remaining work and track the longest line chain.
            local craftSum, longestChain = 0, 0
            for _, line in pairs(craft.lines or {}) do
                local known = lineKnownCount(line)
                local total = lineNumTraits(line)
                local remaining = total - known
                if remaining > 0 then
                    -- Remaining time of the trait (if any) in progress in this
                    -- line covers the first remaining research; the rest use
                    -- the scaled base times.
                    local inProgress
                    for _, trait in pairs(line.traits or {}) do
                        if trait.researching and trait.endsAt and not trait.known then
                            inProgress = math.max(0, trait.endsAt - now)
                        end
                    end

                    local chain = 0
                    for i = 1, remaining do
                        local dur
                        if i == 1 and inProgress then
                            dur = inProgress
                        else
                            dur = RM:BaseResearchSecs(known + i) * factor
                        end
                        chain = chain + dur
                    end
                    craftSum = craftSum + chain
                    if chain > longestChain then longestChain = chain end
                end
            end

            local maxSlots = craft.maxSlots or 0
            local makespan
            if maxSlots > 0 then
                makespan = math.max(craftSum / maxSlots, longestChain)
            else
                makespan = longestChain
            end
            if makespan > charMax then charMax = makespan end
        end
    end

    return charMax
end

-- All in-progress research entries on a snapshot, decorated with line/trait
-- metadata and a `ready` boolean (true when the timer has run out). Sorted by
-- remaining time ascending so callers showing "what finishes next" don't have
-- to sort themselves. `now` may be omitted; passing it keeps callers iterating
-- multiple snapshots consistent.
function Scanner:ListActiveResearch(snap, now)
    if not snap or not snap.crafts then return {} end
    now = now or GetTimeStamp()
    local list = {}
    for _, ct in ipairs(RM.CRAFTS) do
        local craft = snap.crafts[ct]
        if craft then
            for lineIndex, line in pairs(craft.lines or {}) do
                for traitIndex, trait in pairs(line.traits or {}) do
                    if trait.researching and not trait.known then
                        local remaining
                        if trait.endsAt then
                            remaining = trait.endsAt - now
                        end
                        list[#list + 1] = {
                            craftingType = ct,
                            lineIndex = lineIndex,
                            traitIndex = traitIndex,
                            lineName = line.name,
                            traitType = trait.type,
                            endsAt = trait.endsAt,
                            remaining = remaining,
                            ready = remaining ~= nil and remaining <= 0,
                        }
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b)
        local ra = a.remaining or math.huge
        local rb = b.remaining or math.huge
        if ra ~= rb then return ra < rb end
        if a.craftingType ~= b.craftingType then return a.craftingType < b.craftingType end
        if a.lineIndex ~= b.lineIndex then return a.lineIndex < b.lineIndex end
        return a.traitIndex < b.traitIndex
    end)
    return list
end

-- Refresh just one slot when a research event fires, instead of rescanning the world.
function Scanner:UpdateTraitState(craftingType, lineIndex, traitIndex)
    local snap = self:GetCurrentSnapshot()
    if not snap then return self:ScanResearchState() end

    local craft = snap.crafts[craftingType]
    if not craft then return self:ScanResearchState() end
    local line = craft.lines[lineIndex]
    if not line then return self:ScanResearchState() end
    local trait = line.traits[traitIndex]
    if not trait then return self:ScanResearchState() end

    local traitType, _, known = GetSmithingResearchLineTraitInfo(craftingType, lineIndex, traitIndex)
    local duration, timeRemaining = GetSmithingResearchLineTraitTimes(craftingType, lineIndex, traitIndex)
    local wasResearching = trait.researching

    trait.type = traitType
    trait.known = known
    trait.researching = (duration and timeRemaining and not known) and true or false
    if trait.researching then
        trait.duration = duration
        trait.endsAt = GetTimeStamp() + timeRemaining
    else
        trait.duration = nil
        trait.endsAt = nil
    end

    -- Recount active slots for the craft.
    local active = 0
    for _, l in pairs(craft.lines) do
        for _, t in pairs(l.traits) do
            if t.researching then active = active + 1 end
        end
    end
    craft.activeSlots = active

    -- A slot freed up: emit chat notification.
    if wasResearching and not trait.researching and known then
        RM:Chat(zo_strformat(GetString(SI_RM_CHAT_RESEARCH_DONE), line.name, RM:GetCraftName(craftingType)))
    end
end

-- =============================================================================
-- Inventory scan
-- =============================================================================
-- Walks backpack (and bank, if enabled) and indexes every slot that matches an
-- unresearched trait for the current character. Result shape:
--
--   {
--     -- For protection / tooltip lookup: by item's unique id.
--     bySlot = {
--       [bag] = { [slot] = { craftingType, lineIndex, traitIndex, lineName, traitType } },
--     },
--     -- For optimizer: bucketed by (craft, line, trait).
--     byBucket = {
--       [craftingType] = {
--         [lineIndex] = {
--           [traitIndex] = {
--             count = N, slots = { {bag, slot}, ... }, lineName, traitType,
--           },
--         },
--       },
--     },
--   }

local function DoesNotBlockResearch(bagId, slotIndex)
    if IsItemPlayerLocked(bagId, slotIndex) then return false end
    local info = GetItemTraitInformation(bagId, slotIndex)
    return info ~= ITEM_TRAIT_INFORMATION_RETRAITED
        and info ~= ITEM_TRAIT_INFORMATION_RECONSTRUCTED
end

local function GetTraitIndexForItem(bagId, slotIndex, craftingType, lineIndex, numTraits)
    for traitIndex = 1, numTraits do
        if CanItemBeSmithingTraitResearched(bagId, slotIndex, craftingType, lineIndex, traitIndex) then
            return traitIndex
        end
    end
    return nil
end

-- Record a matched slot in the byBucket aggregation, hiding the get-or-create
-- bootstrapping of the (craft -> line -> trait) nesting. `match` is the entry
-- returned by ClassifySlot; (bagId, slotIndex) is the slot it came from.
local function AddToBucket(result, match, bagId, slotIndex)
    local cbucket = result.byBucket[match.craftingType] or {}
    local lbucket = cbucket[match.lineIndex] or {}
    local tbucket = lbucket[match.traitIndex] or {
        count = 0, slots = {},
        lineName = match.lineName,
        traitType = match.traitType,
    }
    tbucket.count = tbucket.count + 1
    tbucket.slots[#tbucket.slots + 1] = { bagId, slotIndex }
    lbucket[match.traitIndex] = tbucket
    cbucket[match.lineIndex] = lbucket
    result.byBucket[match.craftingType] = cbucket
end

-- Classify one inventory slot against the needed (craft, line) buckets. Returns
-- the single matching index entry {craftingType,lineIndex,traitIndex,lineName,
-- traitType} or nil when the slot isn't a researchable item we still need.
--
-- First-match-wins: an item maps to at most one line per craft, so we return on
-- the first line that yields a researchable trait (the original loop's `break`).
-- A line that yields a trait the current character already knows or is actively
-- researching is skipped, and we keep looking at the remaining candidate lines --
-- it does NOT short-circuit the slot.
local function ClassifySlot(bagId, slotIndex, linesByCraft, snap)
    local itemLink = GetItemLink(bagId, slotIndex)
    if not itemLink or itemLink == "" then return nil end

    local craftingType = GetItemLinkCraftingSkillType(itemLink)
    -- Set items can't be researched (the engine's CanItemBeSmithingTraitResearched
    -- below already rejects them); skip them up front so the addon never marks,
    -- protects, warns on, or auto-researches a set item -- the player stays free to
    -- deconstruct or use them by hand.
    if not RM.CRAFT_SET[craftingType] or RM:ItemLinkHasSet(itemLink)
        or not DoesNotBlockResearch(bagId, slotIndex)
    then
        return nil
    end

    local lines = linesByCraft[craftingType]
    if not lines then return nil end

    for lineIndex, lineMeta in pairs(lines) do
        local traitIndex = GetTraitIndexForItem(bagId, slotIndex, craftingType, lineIndex, lineMeta.numTraits)
        if traitIndex then
            local _, _, known = GetSmithingResearchLineTraitInfo(craftingType, lineIndex, traitIndex)
            local duration = GetSmithingResearchLineTraitTimes(craftingType, lineIndex, traitIndex)
            local isResearching = duration ~= nil and not known
            if not known and not isResearching then
                local snapTrait = snap.crafts[craftingType].lines[lineIndex].traits[traitIndex]
                return {
                    craftingType = craftingType,
                    lineIndex = lineIndex,
                    traitIndex = traitIndex,
                    lineName = lineMeta.name,
                    traitType = snapTrait.type,
                }
            end
        end
    end
    return nil
end

function Scanner:BuildInventoryIndex()
    local snap = self:GetCurrentSnapshot()
    if not snap then return nil end

    local result = { bySlot = {}, byBucket = {} }

    local bags = { NUM_BACKPACK }
    if RM.db.includeBank then
        table.insert(bags, NUM_BANK)
        table.insert(bags, NUM_SUBBANK)
    end

    -- Precompute the list of (craft, line, trait) tuples we still need.
    local needed = {}
    for craftingType, craftEntry in pairs(snap.crafts) do
        for lineIndex, lineEntry in pairs(craftEntry.lines) do
            for traitIndex, traitEntry in pairs(lineEntry.traits) do
                if not traitEntry.known and not traitEntry.researching then
                    needed[#needed + 1] = {
                        craftingType = craftingType,
                        lineIndex = lineIndex,
                        traitIndex = traitIndex,
                        lineName = lineEntry.name,
                        traitType = traitEntry.type,
                        numTraits = lineEntry.numTraits,
                    }
                end
            end
        end
    end

    if #needed == 0 then
        RM:Log("Inventory scan skipped: nothing left to research on this character")
        return result
    end

    -- Group needed buckets by (craft, line) to avoid repeating the per-trait loop.
    local linesByCraft = {}
    for _, n in ipairs(needed) do
        linesByCraft[n.craftingType] = linesByCraft[n.craftingType] or {}
        local seen = linesByCraft[n.craftingType]
        if not seen[n.lineIndex] then
            seen[n.lineIndex] = { numTraits = n.numTraits, name = n.lineName }
        end
    end

    for _, bagId in ipairs(bags) do
        result.bySlot[bagId] = result.bySlot[bagId] or {}
        local bagSize = GetBagSize(bagId)
        for slotIndex = 0, bagSize - 1 do
            local match = ClassifySlot(bagId, slotIndex, linesByCraft, snap)
            if match then
                result.bySlot[bagId][slotIndex] = match
                AddToBucket(result, match, bagId, slotIndex)
            end
        end
    end

    RM.inventoryIndex = result
    RM:Log("Inventory index built (%d needed buckets, %d bags scanned)", #needed, #bags)
    return result
end

function Scanner:GetInventoryIndex()
    return RM.inventoryIndex
end

function Scanner:GetMatchForSlot(bagId, slotIndex)
    local idx = RM.inventoryIndex
    if not idx or not idx.bySlot[bagId] then return nil end
    return idx.bySlot[bagId][slotIndex]
end
