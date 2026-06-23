local RM = ResearchManager
RM.Aggregate = {}
local Agg = RM.Aggregate

-- Walks every saved character snapshot and returns the cross-character
-- knowledge map:
--   knowersByBucket[craftingType][lineIndex][traitIndex] = { charKey, charKey, ... }
function Agg:BuildKnowersByBucket()
    local out = {}
    for charKey, snap in pairs(RM.db.characters or {}) do
        for ct, craft in pairs(snap.crafts or {}) do
            out[ct] = out[ct] or {}
            for lineIndex, line in pairs(craft.lines or {}) do
                out[ct][lineIndex] = out[ct][lineIndex] or {}
                for traitIndex, trait in pairs(line.traits or {}) do
                    if trait.known then
                        local bucket = out[ct][lineIndex][traitIndex] or {}
                        bucket[#bucket + 1] = charKey
                        out[ct][lineIndex][traitIndex] = bucket
                    end
                end
            end
        end
    end
    return out
end

-- For a given character key, return the list of (craftingType, lineIndex,
-- traitIndex) that the character doesn't know but at least one other character
-- on the account does.
--   gaps = { { craftingType, lineIndex, traitIndex, lineName, traitType, knownBy={charKey,...} }, ... }
function Agg:GapsForCharacter(charKey)
    local snap = RM.db.characters and RM.db.characters[charKey]
    if not snap then return {} end
    local knowers = self:BuildKnowersByBucket()
    local gaps = {}
    for ct, craft in pairs(snap.crafts or {}) do
        for lineIndex, line in pairs(craft.lines or {}) do
            for traitIndex, trait in pairs(line.traits or {}) do
                if not trait.known then
                    local others = knowers[ct] and knowers[ct][lineIndex] and knowers[ct][lineIndex][traitIndex]
                    if others and #others > 0 then
                        -- Exclude self from knowers list (the character is in the
                        -- map only when they've researched it — they haven't here).
                        local cleaned = {}
                        for _, k in ipairs(others) do
                            if k ~= charKey then cleaned[#cleaned + 1] = k end
                        end
                        if #cleaned > 0 then
                            gaps[#gaps + 1] = {
                                craftingType = ct,
                                lineIndex = lineIndex,
                                traitIndex = traitIndex,
                                lineName = line.name,
                                traitType = trait.type,
                                knownBy = cleaned,
                            }
                        end
                    end
                end
            end
        end
    end
    return gaps
end

-- For the *current* character, return what they can craft that fills a gap on
-- at least one other character.
--   plan = { { craftingType, lineIndex, traitIndex, lineName, traitType, recipients={charKey,...} }, ... }
function Agg:CraftingPlanForCurrent()
    local myKey = RM:GetCharacterKey()
    local mySnap = RM.db.characters and RM.db.characters[myKey]
    if not mySnap then return {} end

    local plan = {}
    for charKey, snap in pairs(RM.db.characters or {}) do
        if charKey ~= myKey then
            for ct, craft in pairs(snap.crafts or {}) do
                for lineIndex, line in pairs(craft.lines or {}) do
                    for traitIndex, trait in pairs(line.traits or {}) do
                        if not trait.known then
                            -- Does the current character know this combo?
                            local mine = mySnap.crafts[ct] and mySnap.crafts[ct].lines[lineIndex]
                                and mySnap.crafts[ct].lines[lineIndex].traits[traitIndex]
                            if mine and mine.known then
                                local key = ct .. ":" .. lineIndex .. ":" .. traitIndex
                                local entry = plan[key]
                                if not entry then
                                    entry = {
                                        craftingType = ct,
                                        lineIndex = lineIndex,
                                        traitIndex = traitIndex,
                                        lineName = line.name,
                                        traitType = trait.type,
                                        recipients = {},
                                    }
                                    plan[key] = entry
                                end
                                entry.recipients[#entry.recipients + 1] = charKey
                            end
                        end
                    end
                end
            end
        end
    end

    -- Flatten to a sorted list (by craft, then line, then trait).
    local list = {}
    for _, e in pairs(plan) do list[#list + 1] = e end
    table.sort(list, function(a, b)
        if a.craftingType ~= b.craftingType then return a.craftingType < b.craftingType end
        if a.lineIndex ~= b.lineIndex then return a.lineIndex < b.lineIndex end
        return a.traitIndex < b.traitIndex
    end)
    return list
end

-- Lookup helper used by Crafter: given an item that was just produced, who on
-- the account needs it?
--   matches an entry from CraftingPlanForCurrent, or nil if no recipients.
function Agg:RecipientsForCraftedItem(craftingType, lineIndex, traitIndex)
    local myKey = RM:GetCharacterKey()
    local recipients = {}
    for charKey, snap in pairs(RM.db.characters or {}) do
        if charKey ~= myKey then
            local trait = snap.crafts and snap.crafts[craftingType]
                and snap.crafts[craftingType].lines[lineIndex]
                and snap.crafts[craftingType].lines[lineIndex].traits[traitIndex]
            if trait and not trait.known and not trait.researching then
                recipients[#recipients + 1] = snap.name or charKey
            end
        end
    end
    return recipients
end

-- Pretty-print a charKey ("@account/CharName/world") down to a short label.
function Agg:FormatCharLabel(charKey)
    local snap = RM.db.characters and RM.db.characters[charKey]
    if snap and snap.name then return snap.name end
    -- fallback: parse from the key
    local _, _, name = string.find(charKey, "^[^/]+/([^/]+)/")
    return name or charKey
end
