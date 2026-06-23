local RM = ResearchManager

-- Build the per-category trait priority submenu controls.
-- Sliders show one row per researchable trait in canonical research-line order
-- so users can scan top-to-bottom and see the same arrangement they see in the
-- research UI in-game.
local function BuildTraitPrioritySubmenu(categoryKey, headerStringId)
    local traits = RM.RESEARCHABLE_TRAITS[categoryKey]
    local controls = {}

    for _, traitType in ipairs(traits) do
        local default = RM.DEFAULT_TRAIT_PRIORITY[traitType] or 0
        local capturedTrait = traitType  -- close over by value for each slider
        controls[#controls + 1] = {
            type = "slider",
            name = GetString("SI_ITEMTRAITTYPE", capturedTrait),
            min = 0, max = 100, step = 5,
            getFunc = function()
                local v = RM.db.traitPriority and RM.db.traitPriority[capturedTrait]
                if v == nil then return default end
                return v
            end,
            setFunc = function(v)
                RM.db.traitPriority = RM.db.traitPriority or {}
                RM.db.traitPriority[capturedTrait] = v
            end,
            default = default,
        }
    end

    controls[#controls + 1] = {
        type = "button",
        name = GetString(SI_RM_SETTINGS_PRIORITY_RESET),
        tooltip = GetString(SI_RM_SETTINGS_PRIORITY_RESET_TT),
        func = function()
            RM.db.traitPriority = RM.db.traitPriority or {}
            for _, traitType in ipairs(traits) do
                RM.db.traitPriority[traitType] = nil
            end
        end,
    }

    return {
        type = "submenu",
        name = GetString(headerStringId),
        controls = controls,
    }
end

function RM:InitSettings()
    local LAM = LibAddonMenu2
    if not LAM then return end

    local panelData = {
        type = "panel",
        name = RM.DISPLAY_NAME,
        displayName = "|c66FFFF" .. RM.DISPLAY_NAME .. "|r",
        author = "zixhwizs",
        version = "0.1.0",
        slashCommand = "/researchmgr",
        registerForRefresh = true,
        registerForDefaults = true,
    }
    LAM:RegisterAddonPanel(RM.ADDON_NAME .. "_Panel", panelData)

    local options = {
        {
            type = "header",
            name = GetString(SI_RM_SETTINGS_GENERAL),
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_INCLUDE_BANK),
            tooltip = GetString(SI_RM_SETTINGS_INCLUDE_BANK_TT),
            getFunc = function() return RM.db.includeBank end,
            setFunc = function(v) RM.db.includeBank = v; RM.Scanner:BuildInventoryIndex() end,
            default = RM.DEFAULTS.includeBank,
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_TOOLTIPS),
            getFunc = function() return RM.db.tooltipBadges end,
            setFunc = function(v) RM.db.tooltipBadges = v end,
            default = RM.DEFAULTS.tooltipBadges,
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_WARN_DECON),
            tooltip = GetString(SI_RM_SETTINGS_PROTECT_TT),
            getFunc = function() return RM.db.warnDeconstruct end,
            setFunc = function(v) RM.db.warnDeconstruct = v end,
            default = RM.DEFAULTS.warnDeconstruct,
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_WARN_SELL),
            getFunc = function() return RM.db.warnSell end,
            setFunc = function(v) RM.db.warnSell = v end,
            default = RM.DEFAULTS.warnSell,
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_CHAT),
            getFunc = function() return RM.db.chatNotifications end,
            setFunc = function(v) RM.db.chatNotifications = v end,
            default = RM.DEFAULTS.chatNotifications,
        },
        {
            type = "header",
            name = GetString(SI_RM_SETTINGS_OPTIMIZER),
        },
        {
            type = "dropdown",
            name = GetString(SI_RM_SETTINGS_OPTIMIZER_MODE),
            tooltip = GetString(SI_RM_SETTINGS_OPTIMIZER_MODE_TT),
            choices = {
                GetString(SI_RM_SETTINGS_MODE_BALANCED),
                GetString(SI_RM_SETTINGS_MODE_SHORTEST),
                GetString(SI_RM_SETTINGS_MODE_PRIORITY),
                GetString(SI_RM_SETTINGS_MODE_FILL_SLOTS),
            },
            choicesValues = { "BALANCED", "SHORTEST_FIRST", "PRIORITY_FIRST", "FILL_SLOTS" },
            getFunc = function() return RM.db.optimizerMode end,
            setFunc = function(v) RM.db.optimizerMode = v end,
            default = RM.DEFAULTS.optimizerMode,
        },
        {
            type = "header",
            name = GetString(SI_RM_SETTINGS_PRIORITIES),
        },
        {
            type = "description",
            text = GetString(SI_RM_SETTINGS_PRIORITIES_HELP),
        },
        BuildTraitPrioritySubmenu("WEAPON",  SI_RM_SETTINGS_PRIORITY_WEAPONS),
        BuildTraitPrioritySubmenu("ARMOR",   SI_RM_SETTINGS_PRIORITY_ARMOR),
        BuildTraitPrioritySubmenu("JEWELRY", SI_RM_SETTINGS_PRIORITY_JEWELRY),
        {
            type = "header",
            name = GetString(SI_RM_SETTINGS_CRAFTING),
        },
        {
            type = "dropdown",
            name = GetString(SI_RM_SETTINGS_CRAFT_QUALITY),
            tooltip = GetString(SI_RM_SETTINGS_CRAFT_QUALITY_TT),
            choices = {
                GetString("SI_ITEMQUALITY", ITEM_QUALITY_NORMAL),
                GetString("SI_ITEMQUALITY", ITEM_QUALITY_MAGIC),
                GetString("SI_ITEMQUALITY", ITEM_QUALITY_ARCANE),
                GetString("SI_ITEMQUALITY", ITEM_QUALITY_ARTIFACT),
                GetString("SI_ITEMQUALITY", ITEM_QUALITY_LEGENDARY),
            },
            choicesValues = {
                ITEM_QUALITY_NORMAL, ITEM_QUALITY_MAGIC, ITEM_QUALITY_ARCANE,
                ITEM_QUALITY_ARTIFACT, ITEM_QUALITY_LEGENDARY,
            },
            getFunc = function() return RM.db.craftQuality end,
            setFunc = function(v) RM.db.craftQuality = v end,
            default = RM.DEFAULTS.craftQuality,
        },
        {
            type = "dropdown",
            name = GetString(SI_RM_SETTINGS_CRAFT_LEVELMODE),
            tooltip = GetString(SI_RM_SETTINGS_CRAFT_LEVELMODE_TT),
            choices = {
                GetString(SI_RM_SETTINGS_CRAFT_LEVELMODE_FIXED),
                GetString(SI_RM_SETTINGS_CRAFT_LEVELMODE_AUTO),
            },
            choicesValues = { "FIXED", "AUTO" },
            getFunc = function() return RM.db.craftLevelMode end,
            setFunc = function(v) RM.db.craftLevelMode = v end,
            default = RM.DEFAULTS.craftLevelMode,
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_CRAFT_ISCP),
            tooltip = GetString(SI_RM_SETTINGS_CRAFT_ISCP_TT),
            getFunc = function() return RM.db.craftFixedIsCP end,
            setFunc = function(v) RM.db.craftFixedIsCP = v end,
            default = RM.DEFAULTS.craftFixedIsCP,
            disabled = function() return RM.db.craftLevelMode ~= "FIXED" end,
        },
        {
            type = "slider",
            name = GetString(SI_RM_SETTINGS_CRAFT_LEVEL),
            tooltip = GetString(SI_RM_SETTINGS_CRAFT_LEVEL_TT),
            min = 1, max = 160, step = 1,
            getFunc = function() return RM.db.craftFixedLevel end,
            setFunc = function(v) RM.db.craftFixedLevel = v end,
            default = RM.DEFAULTS.craftFixedLevel,
            disabled = function() return RM.db.craftLevelMode ~= "FIXED" end,
        },
        {
            type = "header",
            name = GetString(SI_RM_SETTINGS_GIFTING),
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_AUTOMARK),
            tooltip = GetString(SI_RM_SETTINGS_AUTOMARK_TT),
            getFunc = function() return RM.db.autoMarkGiftItems end,
            setFunc = function(v) RM.db.autoMarkGiftItems = v end,
            default = RM.DEFAULTS.autoMarkGiftItems,
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_AUTODEPOSIT),
            tooltip = GetString(SI_RM_SETTINGS_AUTODEPOSIT_TT),
            getFunc = function() return RM.db.autoDepositResearchItems end,
            setFunc = function(v) RM.db.autoDepositResearchItems = v end,
            default = RM.DEFAULTS.autoDepositResearchItems,
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_AUTO_RESEARCH),
            tooltip = GetString(SI_RM_SETTINGS_AUTO_RESEARCH_TT),
            getFunc = function() return RM.db.autoResearchAtStation end,
            setFunc = function(v) RM.db.autoResearchAtStation = v end,
            default = RM.DEFAULTS.autoResearchAtStation,
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_AUTO_EXIT),
            tooltip = GetString(SI_RM_SETTINGS_AUTO_EXIT_TT),
            getFunc = function() return RM.db.autoExitAtStation end,
            setFunc = function(v) RM.db.autoExitAtStation = v end,
            default = RM.DEFAULTS.autoExitAtStation,
        },
        {
            type = "checkbox",
            name = GetString(SI_RM_SETTINGS_DEBUG),
            getFunc = function() return RM.db.debug end,
            setFunc = function(v) RM.db.debug = v end,
            default = RM.DEFAULTS.debug,
        },
    }
    LAM:RegisterOptionControls(RM.ADDON_NAME .. "_Panel", options)
end
