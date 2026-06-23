local RM = ResearchManager
RM.Optimizer = {}
local Opt = RM.Optimizer

-- ESO research durations follow a strict doubling per researched trait:
--   trait #N in a line, where K traits are already known, takes BASE * 2^K hours
-- BASE = 6 hours, capped at 30 days (which kicks in once K >= 7).
-- We don't need to hit the exact number — GetSmithingResearchLineTraitTimes
-- gives the precise value for the trait we'd actually start (the next unknown
-- one in the line). For ranking purposes we ask the game for it directly.

local SECONDS_PER_HOUR = 3600
local SECONDS_PER_DAY  = 86400
-- The longest research in the game caps at 30 days; SHORTEST_FIRST normalizes
-- against that. The "fill slot" scorers normalize duration against a wider
-- 60-day spread so it only ever acts as a sub-1.0 tiebreaker, never flipping
-- the ranking between two otherwise-equal candidates.
local RESEARCH_CAP_SECS  = 30 * SECONDS_PER_DAY
local DURATION_SPREAD_SECS = 60 * SECONDS_PER_DAY

function Opt:GetPriority(traitType)
    local user = RM.db.traitPriority and RM.db.traitPriority[traitType]
    if user ~= nil then return user end
    return RM.DEFAULT_TRAIT_PRIORITY[traitType] or 0
end
local function GetPriority(traitType) return Opt:GetPriority(traitType) end

local function ProjectedDurationSecs(craftingType, lineIndex)
    -- The duration of starting the NEXT research in a line equals
    -- `timeRequiredForNextResearchSecs` returned by GetSmithingResearchLineInfo.
    local _, _, _, timeRequiredForNextResearchSecs = GetSmithingResearchLineInfo(craftingType, lineIndex)
    return timeRequiredForNextResearchSecs or 0
end

local function CountKnownTraitsInLine(snap, craftingType, lineIndex)
    local line = snap.crafts[craftingType] and snap.crafts[craftingType].lines[lineIndex]
    if not line then return 0, 0 end
    local known, total = 0, 0
    for _, t in pairs(line.traits) do
        total = total + 1
        if t.known then known = known + 1 end
    end
    return known, total
end

local SCORERS = {}

SCORERS.FILL_SLOTS = function(ctx)
    -- Any candidate scores ~1; ties broken by shorter duration.
    return 1 - (ctx.durationSecs / DURATION_SPREAD_SECS)
end

SCORERS.SHORTEST_FIRST = function(ctx)
    -- Larger score for shorter research. Normalize against the 30-day cap.
    return 1 - math.min(ctx.durationSecs, RESEARCH_CAP_SECS) / RESEARCH_CAP_SECS
end

SCORERS.PRIORITY_FIRST = function(ctx)
    return ctx.priority + (1 - ctx.durationSecs / DURATION_SPREAD_SECS)
end

SCORERS.BALANCED = function(ctx)
    -- Combined heuristic:
    --   + priority of the trait (0..100 normally)
    --   + bonus if this would complete a line (jewelry/armor mastery)
    --   + small bonus per known-trait-in-line (research the deep lines so a
    --     30-day slot finishes alongside the rest)
    --   - cost in days (so 30-day starts lose to 6-hour starts when priority
    --     and depth are equal)
    local days = ctx.durationSecs / SECONDS_PER_DAY
    local depthBonus = ctx.knownInLine * 3
    local completeBonus = (ctx.knownInLine + 1 == ctx.totalInLine) and 25 or 0
    return ctx.priority + depthBonus + completeBonus - days
end

local function Score(mode, ctx)
    local scorer = SCORERS[mode] or SCORERS.BALANCED
    return scorer(ctx)
end

local function HumanDuration(secs)
    if secs < SECONDS_PER_HOUR then return string.format("%dm", math.floor(secs / 60)) end
    if secs < SECONDS_PER_DAY  then return string.format("%.1fh", secs / SECONDS_PER_HOUR) end
    return string.format("%.1fd", secs / SECONDS_PER_DAY)
end

function Opt:Recommend(maxResults)
    maxResults = maxResults or 10
    local snap = RM.Scanner:GetCurrentSnapshot()
    local idx = RM.Scanner:GetInventoryIndex()
    if not snap or not idx then return {} end

    local mode = RM.db.optimizerMode or "BALANCED"
    local candidates = {}

    local now = GetTimeStamp()
    for craftingType, lineMap in pairs(idx.byBucket) do
        local craft = snap.crafts[craftingType]
        if craft then
            local freeSlots = RM.Scanner:GetEffectiveFreeSlots(snap, craftingType, now)
            for lineIndex, traitMap in pairs(lineMap) do
                for traitIndex, bucket in pairs(traitMap) do
                    local sampleSlot = bucket.slots[1]
                    local known, total = CountKnownTraitsInLine(snap, craftingType, lineIndex)
                    local duration = ProjectedDurationSecs(craftingType, lineIndex)
                    local ctx = {
                        durationSecs = duration,
                        priority = GetPriority(bucket.traitType),
                        knownInLine = known,
                        totalInLine = total,
                        freeSlots = freeSlots,
                    }
                    candidates[#candidates + 1] = {
                        craftingType = craftingType,
                        lineIndex = lineIndex,
                        traitIndex = traitIndex,
                        lineName = bucket.lineName,
                        traitType = bucket.traitType,
                        bagId = sampleSlot[1],
                        slotIndex = sampleSlot[2],
                        itemCount = bucket.count,
                        durationSecs = duration,
                        durationText = HumanDuration(duration),
                        score = Score(mode, ctx),
                        knownInLine = known,
                        totalInLine = total,
                        canStartNow = freeSlots > 0,
                    }
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.canStartNow ~= b.canStartNow then return a.canStartNow end
        return a.score > b.score
    end)

    -- One recommendation per (craft, line). Researching two traits of the same
    -- line in parallel isn't possible.
    local seenLine = {}
    local trimmed = {}
    for _, c in ipairs(candidates) do
        local k = c.craftingType .. ":" .. c.lineIndex
        if not seenLine[k] then
            seenLine[k] = true
            trimmed[#trimmed + 1] = c
            if #trimmed >= maxResults then break end
        end
    end
    return trimmed
end

function Opt:Summary()
    local snap = RM.Scanner:GetCurrentSnapshot()
    if not snap then return nil end
    local now = GetTimeStamp()
    local out = {}
    for _, ct in ipairs(RM.CRAFTS) do
        local c = snap.crafts[ct]
        if c then
            local knownTotal, traitTotal = 0, 0
            for _, l in pairs(c.lines) do
                for _, t in pairs(l.traits) do
                    traitTotal = traitTotal + 1
                    if t.known then knownTotal = knownTotal + 1 end
                end
            end
            out[#out + 1] = {
                craftingType = ct,
                name = RM:GetCraftName(ct),
                activeSlots = RM.Scanner:CountActiveSlots(snap, ct, now),
                maxSlots = c.maxSlots,
                knownTraits = knownTotal,
                totalTraits = traitTotal,
            }
        end
    end
    return out
end
