ResearchManager = ResearchManager or {}
local RM = ResearchManager

RM.ADDON_NAME = "ResearchManager"
RM.DISPLAY_NAME = "Research Manager"
RM.VERSION = 1

RM.CRAFTS = {
    CRAFTING_TYPE_BLACKSMITHING,
    CRAFTING_TYPE_CLOTHIER,
    CRAFTING_TYPE_WOODWORKING,
    CRAFTING_TYPE_JEWELRYCRAFTING,
}

-- The nine researchable traits per category, in canonical research-line order.
-- Used both by the settings UI to lay out sliders and by code that needs to
-- iterate "all valid trait keys for category X".
RM.RESEARCHABLE_TRAITS = {
    WEAPON = {
        ITEM_TRAIT_TYPE_WEAPON_POWERED,
        ITEM_TRAIT_TYPE_WEAPON_CHARGED,
        ITEM_TRAIT_TYPE_WEAPON_PRECISE,
        ITEM_TRAIT_TYPE_WEAPON_INFUSED,
        ITEM_TRAIT_TYPE_WEAPON_DEFENDING,
        ITEM_TRAIT_TYPE_WEAPON_TRAINING,
        ITEM_TRAIT_TYPE_WEAPON_SHARPENED,
        ITEM_TRAIT_TYPE_WEAPON_DECISIVE,
        ITEM_TRAIT_TYPE_WEAPON_NIRNHONED,
    },
    ARMOR = {
        ITEM_TRAIT_TYPE_ARMOR_STURDY,
        ITEM_TRAIT_TYPE_ARMOR_IMPENETRABLE,
        ITEM_TRAIT_TYPE_ARMOR_REINFORCED,
        ITEM_TRAIT_TYPE_ARMOR_WELL_FITTED,
        ITEM_TRAIT_TYPE_ARMOR_TRAINING,
        ITEM_TRAIT_TYPE_ARMOR_INFUSED,
        ITEM_TRAIT_TYPE_ARMOR_PROSPEROUS,  -- displays as "Invigorating"
        ITEM_TRAIT_TYPE_ARMOR_DIVINES,
        ITEM_TRAIT_TYPE_ARMOR_NIRNHONED,
    },
    JEWELRY = {
        ITEM_TRAIT_TYPE_JEWELRY_HEALTHY,
        ITEM_TRAIT_TYPE_JEWELRY_ARCANE,
        ITEM_TRAIT_TYPE_JEWELRY_ROBUST,
        ITEM_TRAIT_TYPE_JEWELRY_PROTECTIVE,
        ITEM_TRAIT_TYPE_JEWELRY_INFUSED,
        ITEM_TRAIT_TYPE_JEWELRY_SWIFT,
        ITEM_TRAIT_TYPE_JEWELRY_HARMONY,
        ITEM_TRAIT_TYPE_JEWELRY_TRIUNE,
        ITEM_TRAIT_TYPE_JEWELRY_BLOODTHIRSTY,
    },
}

-- Default 0..100 priority per trait, used by the optimizer when the user hasn't
-- overridden it in settings. Higher = research first.
RM.DEFAULT_TRAIT_PRIORITY = {
    -- Weapons
    [ITEM_TRAIT_TYPE_WEAPON_NIRNHONED]   = 100,
    [ITEM_TRAIT_TYPE_WEAPON_SHARPENED]   = 85,
    [ITEM_TRAIT_TYPE_WEAPON_INFUSED]     = 80,
    [ITEM_TRAIT_TYPE_WEAPON_PRECISE]     = 65,
    [ITEM_TRAIT_TYPE_WEAPON_CHARGED]     = 50,
    [ITEM_TRAIT_TYPE_WEAPON_DECISIVE]    = 50,
    [ITEM_TRAIT_TYPE_WEAPON_POWERED]     = 35,
    [ITEM_TRAIT_TYPE_WEAPON_DEFENDING]   = 25,
    [ITEM_TRAIT_TYPE_WEAPON_TRAINING]    = 10,

    -- Armor
    [ITEM_TRAIT_TYPE_ARMOR_DIVINES]      = 100,
    [ITEM_TRAIT_TYPE_ARMOR_INFUSED]      = 85,
    [ITEM_TRAIT_TYPE_ARMOR_IMPENETRABLE] = 70,
    [ITEM_TRAIT_TYPE_ARMOR_REINFORCED]   = 60,
    [ITEM_TRAIT_TYPE_ARMOR_WELL_FITTED]  = 55,
    [ITEM_TRAIT_TYPE_ARMOR_STURDY]       = 45,
    [ITEM_TRAIT_TYPE_ARMOR_PROSPEROUS]   = 40,
    [ITEM_TRAIT_TYPE_ARMOR_NIRNHONED]    = 30,
    [ITEM_TRAIT_TYPE_ARMOR_TRAINING]     = 10,

    -- Jewelry
    [ITEM_TRAIT_TYPE_JEWELRY_BLOODTHIRSTY] = 100,
    [ITEM_TRAIT_TYPE_JEWELRY_INFUSED]      = 90,
    [ITEM_TRAIT_TYPE_JEWELRY_SWIFT]        = 80,
    [ITEM_TRAIT_TYPE_JEWELRY_PROTECTIVE]   = 65,
    [ITEM_TRAIT_TYPE_JEWELRY_TRIUNE]       = 55,
    [ITEM_TRAIT_TYPE_JEWELRY_HARMONY]      = 55,
    [ITEM_TRAIT_TYPE_JEWELRY_HEALTHY]      = 45,
    [ITEM_TRAIT_TYPE_JEWELRY_ROBUST]       = 45,
    [ITEM_TRAIT_TYPE_JEWELRY_ARCANE]       = 35,
}

RM.DEFAULTS = {
    -- Per-character cache of research state. Key: "@account/CharName/serverWorld".
    characters = {},

    -- Cross-character behavior toggles.
    includeBank = true,
    protectResearchItems = true,
    warnDeconstruct = true,
    warnSell = true,
    tooltipBadges = true,
    chatNotifications = true,

    -- Optimizer behavior.
    optimizerMode = "BALANCED",  -- "FILL_SLOTS", "SHORTEST_FIRST", "PRIORITY_FIRST", "BALANCED"
    traitPriority = {},          -- user overrides; merged over DEFAULT_TRAIT_PRIORITY

    -- Cross-character gifting.
    autoMarkGiftItems = true,    -- on craft, mark items destined for an alt that needs the trait

    -- When the bank opens, automatically deposit backpack items that are bound
    -- (in craftedFor) to a DIFFERENT character so they reach the recipient via
    -- the account bank. Items bound to the current character are left alone.
    autoDepositResearchItems = true,

    -- LibLazyCrafting queueing.
    craftQuality = ITEM_QUALITY_NORMAL,  -- white; player can bump it
    craftLevelMode = "FIXED",            -- "FIXED" or "AUTO"
    craftFixedLevel = 1,
    craftFixedIsCP = false,

    -- Auto-research on station entry: when the player walks up to a smithing
    -- station, automatically start research on any FCOIS-research-marked items
    -- in their backpack that match an unresearched trait, up to free slots.
    autoResearchAtStation = true,

    -- Auto-exit the crafting station once all auto-research and queued
    -- LibLazyCrafting crafting for the station has finished -- but only if at
    -- least one research was started or one queued item was actually crafted
    -- this visit. A station with nothing to do is left open. Off by default.
    autoExitAtStation = false,

    -- Persisted research-manager window geometry. left/top are in UI units
    -- relative to GuiRoot's TOPLEFT; nil values mean "use the XML default".
    windowState = {
        width = nil,
        height = nil,
        left = nil,
        top = nil,
    },

    -- Map of item-unique-id (string form, via Id64ToString) -> {
    --   recipient = charKey, when = epoch
    -- }
    -- Populated when LibLazyCrafting reports a successful craft for one of
    -- our requests. Items in this map should only ever be researched by
    -- their named recipient, even if they end up in someone else's inventory.
    craftedFor = {},

    -- Debug.
    debug = false,
}

-- Crafting types as a set (for quick membership check on item links).
RM.CRAFT_SET = {}
for _, ct in ipairs(RM.CRAFTS) do RM.CRAFT_SET[ct] = true end

-- The three trait categories that can carry a researchable trait: weapon,
-- armor, and jewelry gear. Consumables, glyphs, etc. cannot be researched.
function RM:IsResearchableTraitCategory(category)
    return category == ITEM_TRAIT_TYPE_CATEGORY_WEAPON
        or category == ITEM_TRAIT_TYPE_CATEGORY_ARMOR
        or category == ITEM_TRAIT_TYPE_CATEGORY_JEWELRY
end

-- Flat set of every researchable trait TYPE across all three categories. Trait
-- type enums are distinct per category (a weapon's Infused differs from jewelry's),
-- so one flat set is unambiguous. Use this -- not just the category -- to tell
-- whether a specific item's trait can actually be researched: it excludes the
-- non-researchable traits a researchable category still carries (Ornate,
-- Intricate, and companion traits), which a category-only check would let through.
RM.RESEARCHABLE_TRAIT_SET = {}
for _, traits in pairs(RM.RESEARCHABLE_TRAITS) do
    for _, traitType in ipairs(traits) do
        RM.RESEARCHABLE_TRAIT_SET[traitType] = true
    end
end

function RM:IsResearchableTrait(traitType)
    return self.RESEARCHABLE_TRAIT_SET[traitType] == true
end

-- Items belonging to an item set can never have their traits researched in any
-- craft. The addon must therefore never claim, gift, mark, or auto-research a
-- set item -- but it deliberately does NOT lock them either, so the player stays
-- free to deconstruct, sell, or otherwise use them by hand. GetItemLinkSetInfo's
-- first return is the hasSet flag.
function RM:ItemLinkHasSet(itemLink)
    if not itemLink or itemLink == "" then return false end
    return GetItemLinkSetInfo(itemLink) == true
end

function RM:GetCharacterKey()
    local account = GetDisplayName()
    local character = GetUnitName("player")
    local world = GetWorldName()
    return string.format("%s/%s/%s", account, character, world)
end

function RM:GetCraftName(craftingType)
    return GetCraftingSkillName(craftingType) or tostring(craftingType)
end

-- Base research duration (seconds) for the Nth trait researched in a line,
-- before any Metallurgy / passive reduction. ESO doubles the time each step:
-- 6h, 12h, 24h, 2d, 4d, ... up to 64 days for the 9th trait. researchNumber is
-- 1-based (1 = first trait researched in the line, when none are yet known).
-- Used by the completion-time estimate, which scales these by a per-craft
-- factor inferred from in-progress research so it matches the character's
-- actual passives instead of assuming the unreduced maximum.
RM.RESEARCH_BASE_SECS = 6 * 3600
function RM:BaseResearchSecs(researchNumber)
    if researchNumber < 1 then researchNumber = 1 end
    return self.RESEARCH_BASE_SECS * (2 ^ (researchNumber - 1))
end

-- =============================================================================
-- Chat & log output
-- =============================================================================
-- Every addon chat line is branded "[Research]"; the color conveys tone. These
-- wrap CHAT_SYSTEM:AddMessage so the brand string and colors live in exactly one
-- place. Callers pass an already-formatted message (doing their own zo_strformat
-- / string.format, so ESO's <<1>> parameter substitution keeps working) -- the
-- helpers only add the colored prefix.
local CHAT_BRAND    = "[Research]"
local COLOR_INFO    = "66FFFF"  -- cyan:   neutral info / status
local COLOR_SUCCESS = "66FF66"  -- green:  something was done
local COLOR_WARNING = "FF6600"  -- orange: caution / failure / unavailable

local function emitChat(color, msg)
    CHAT_SYSTEM:AddMessage(string.format("|c%s%s|r %s", color, CHAT_BRAND, msg))
end

-- Branded prefix + the message. Pick the variant by tone.
function RM:Announce(msg)     emitChat(COLOR_INFO, msg) end
function RM:AnnounceGood(msg) emitChat(COLOR_SUCCESS, msg) end
function RM:AnnounceWarn(msg) emitChat(COLOR_WARNING, msg) end

-- Whole line colored, e.g. "[Research] Recommendations:" entirely in cyan.
-- Used as the heading above a multi-line chat listing.
function RM:AnnounceHeader(msg)
    CHAT_SYSTEM:AddMessage(string.format("|c%s%s %s|r", COLOR_INFO, CHAT_BRAND, msg))
end

-- Passive notification, gated by the chatNotifications setting (e.g. "research
-- finished"). Same styling as Announce; silently suppressed when the user opts
-- out, unlike the Announce* helpers which always print.
function RM:Chat(fmt, ...)
    if not (self.db and self.db.chatNotifications) then return end
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    emitChat(COLOR_INFO, msg)
end

-- Debug trace, gated by the debug setting. Goes to the dev log (d()), not chat.
function RM:Log(fmt, ...)
    if not (self.db and self.db.debug) then return end
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    d("|c" .. COLOR_INFO .. "[RM]|r " .. msg)
end
