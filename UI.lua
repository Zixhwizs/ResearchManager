local RM = ResearchManager
RM.UI = {}
local UI = RM.UI

-- =============================================================================
-- Tooltip badges
-- =============================================================================
-- Append a "needed for research" line to inventory tooltips. ItemTooltip is a
-- userdata control, so SecurePostHook (strict-table) doesn't work on it; we
-- use ZO_PostHook, which is Lua-side and walks the control's metatable.
-- Tooltip rendering doesn't call secure functions, so taint isn't a concern.

-- Bags that our inventory scanner indexes -- the only bags an item can come
-- from and meaningfully be researchable. Equipped items (BAG_WORN /
-- BAG_COMPANION_WORN) are never research candidates and would crash some
-- equipment-pane tooltip code paths if we tried to mutate them.
local SCANNED_BAGS = {
    [BAG_BACKPACK] = true,
    [BAG_BANK] = true,
    [BAG_SUBSCRIBER_BANK] = true,
}

local function GetMatchLine(bagId, slotIndex)
    if not RM.db or not RM.db.tooltipBadges then return nil end
    if not SCANNED_BAGS[bagId] then return nil end
    local match = RM.Scanner:GetMatchForSlot(bagId, slotIndex)
    if not match then return nil end
    local traitName = GetString("SI_ITEMTRAITTYPE", match.traitType) or "?"
    return zo_strformat(GetString(SI_RM_TOOLTIP_NEEDED), traitName, match.lineName)
end

local function AddBadgeToTooltip(tooltip, bagId, slotIndex)
    local line = GetMatchLine(bagId, slotIndex)
    if not line then return end
    -- Some tooltip code paths swap ItemTooltip's contents around and may not
    -- expose the section API in the same way (the character equipment pane
    -- has tripped this with "function expected instead of nil"). Guard
    -- explicitly, then pcall the mutation so a future ESO refactor can't
    -- crash the game from our cosmetic badge.
    if type(tooltip.AcquireSection) ~= "function"
        or type(tooltip.GetStyle) ~= "function"
        or type(tooltip.AddSection) ~= "function" then
        return
    end
    local ok, err = pcall(function()
        local section = tooltip:AcquireSection(tooltip:GetStyle("bodySection"))
        if not section or type(section.AddLine) ~= "function" then return end
        section:AddLine("|cFFCC33[" .. GetString(SI_RM_BADGE_NEEDED) .. "]|r " .. line,
            tooltip:GetStyle("bodyDescription"))
        tooltip:AddSection(section)
    end)
    if not ok then
        RM:Log("Tooltip badge skipped (bag=%s slot=%s): %s",
            tostring(bagId), tostring(slotIndex), tostring(err))
    end
end

function UI:InstallTooltipHooks()
    ZO_PostHook(ItemTooltip, "SetBagItem", function(tooltip, bagId, slotIndex)
        AddBadgeToTooltip(tooltip, bagId, slotIndex)
    end)
    if PopupTooltip then
        ZO_PostHook(PopupTooltip, "SetBagItem", function(tooltip, bagId, slotIndex)
            AddBadgeToTooltip(tooltip, bagId, slotIndex)
        end)
    end
end

-- =============================================================================
-- Deconstruct / sell warnings
-- =============================================================================
-- Both APIs eventually call AddItemToDeconstructMessage / SellInventoryItem.
-- We pre-hook these to print a chat warning when a needed-for-research item is
-- being acted on. We never suppress the original — the user stays in control.

local function MaybeWarn(bagId, slotIndex, kind)
    if not RM.db then return end
    if kind == "decon" and not RM.db.warnDeconstruct then return end
    if kind == "sell" and not RM.db.warnSell then return end
    local match = RM.Scanner:GetMatchForSlot(bagId, slotIndex)
    if not match then return end
    local traitName = GetString("SI_ITEMTRAITTYPE", match.traitType) or "?"
    local fmt = (kind == "decon") and SI_RM_CONFIRM_DECON or SI_RM_CONFIRM_SELL
    CHAT_SYSTEM:AddMessage("|cFF6600[Research Warning]|r " ..
        zo_strformat(GetString(fmt), traitName .. " (" .. match.lineName .. ")"))
end

function UI:InstallActionHooks()
    if AddItemToDeconstructMessage then
        ZO_PreHook("AddItemToDeconstructMessage", function(bagId, slotIndex)
            MaybeWarn(bagId, slotIndex, "decon")
        end)
    end
    if SellInventoryItem then
        ZO_PreHook("SellInventoryItem", function(bagId, slotIndex)
            MaybeWarn(bagId, slotIndex, "sell")
        end)
    end
end

-- =============================================================================
-- Status / recommendations to chat
-- =============================================================================

local function FormatRemaining(secs)
    if secs < 60 then return string.format("%ds", secs) end
    if secs < 3600 then return string.format("%dm", math.floor(secs / 60)) end
    if secs < 86400 then return string.format("%dh %dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60)) end
    return string.format("%dd %dh", math.floor(secs / 86400), math.floor((secs % 86400) / 3600))
end

function UI:PrintStatus()
    local summary = RM.Optimizer:Summary()
    if not summary then
        CHAT_SYSTEM:AddMessage(GetString(SI_RM_STATUS_NO_DATA))
        return
    end
    CHAT_SYSTEM:AddMessage("|c66FFFF" .. GetString(SI_RM_STATUS_HEADER) .. "|r")
    for _, s in ipairs(summary) do
        CHAT_SYSTEM:AddMessage(string.format("  %s: slots %d/%d, traits %d/%d",
            s.name, s.activeSlots, s.maxSlots, s.knownTraits, s.totalTraits))
    end

    -- List active research with completion times.
    local snap = RM.Scanner:GetCurrentSnapshot()
    if not snap then return end
    local now = GetTimeStamp()
    for _, ct in ipairs(RM.CRAFTS) do
        local c = snap.crafts[ct]
        if c then
            for lineIndex, line in pairs(c.lines) do
                for traitIndex, trait in pairs(line.traits) do
                    if trait.researching and trait.endsAt then
                        local remaining = trait.endsAt - now
                        local traitName = GetString("SI_ITEMTRAITTYPE", trait.type) or "?"
                        CHAT_SYSTEM:AddMessage(string.format("  %s / %s / %s — %s",
                            RM:GetCraftName(ct), line.name, traitName, FormatRemaining(remaining)))
                    end
                end
            end
        end
    end
end

-- =============================================================================
-- Research Manager window (XML: ResearchManager.xml)
-- =============================================================================
-- Three side-by-side ZO_ScrollContainers populated independently each refresh:
--   Left:   character tree -- per-character / per-skill / per-slot rows with
--           inline Queue buttons and a top "Queue All Characters" button
--   Middle: the LibLazyCrafting pending-craft queue with per-row Remove and a
--           top "Clear Queue" button
--   Right:  the research queue (craftedFor bindings), grouped by recipient,
--           default expanded, per-binding Remove plus per-recipient Clear
--
-- ESO controls aren't reusable across SetParent cleanly, so we hide + drop
-- on each refresh and rebuild from scratch. Volume per pane is in the tens
-- of rows, so the leak is harmless.
--
-- All Add* helpers read self.scrollChild and append to self._rows. UsePane
-- swaps both to the active pane before each render, so the helpers stay
-- pane-agnostic.

local SECTION_HEADER_COLOR = "|c66FFFF"
local SECTION_FOOTER_COLOR = "|r"

-- Smithing "refine" tab icon used as the "Queue crafting for this character"
-- button in the character tree. This path is one ZOS ships with the smithing
-- station tab strip (verified usable by other addons like FCOIS); it shows a
-- forging/anvil glyph that reads as "kick off a crafting action."
local QUEUE_ICON_PATH = "/esoui/art/crafting/smithing_tabicon_refine_up.dds"

-- Minimum / maximum window size in UI units. Min is wider than before so the
-- panes stay legible; max keeps the window from going full-screen.
local WINDOW_MIN_W, WINDOW_MIN_H = 900, 460
local WINDOW_MAX_W, WINDOW_MAX_H = 1800, 1200

-- Layout constants used by LayoutPanes. Top margin leaves room for title +
-- Refresh/Close. SPLITTER_WIDTH controls how wide the drag handles between
-- panes are; MIN_PANE_W keeps a pane from being dragged to zero.
local PANE_TOP_MARGIN = 56
local PANE_SIDE_MARGIN = 16
local PANE_BOTTOM_MARGIN = 16
local SPLITTER_WIDTH = 8
local MIN_PANE_W = 150

-- The window is laid out as N panes separated by N-1 draggable splitters.
-- PANE_ORDER fixes their left-to-right order; every layout/drag/persist path
-- iterates this list so adding or reordering a pane is a one-line change here
-- plus a render function. The LAST pane is the "remainder" -- it absorbs
-- whatever width the others don't claim, so only the first N-1 panes store a
-- fraction. "stats" (research statistics) is leftmost; "left" is the character
-- tree, "middle" the crafting queue, "right" the research queue.
local PANE_ORDER = { "stats", "left", "middle", "right" }
local DEFAULT_PANE_FRACS = { stats = 1/4, left = 1/4, middle = 1/4 }

-- Width available for a row inside the currently-active pane's scroll
-- viewport. Reads the live container width on every call so a window resize
-- flows through to row sizes the next time RefreshWindow rebuilds.
local function ContentWidth(self)
    if self._activeScroll then
        local w = self._activeScroll:GetWidth()
        if w and w > 0 then return w - 24 end  -- gutter for the scrollbar
    end
    return 320
end

function UI:InitWindow()
    self.window = ResearchManagerWindow
    if not self.window then return end

    self._statsScroll  = self.window:GetNamedChild("StatsScroll")
    self._leftScroll   = self.window:GetNamedChild("LeftScroll")
    self._middleScroll = self.window:GetNamedChild("MiddleScroll")
    self._rightScroll  = self.window:GetNamedChild("RightScroll")
    self._statsChild   = self._statsScroll  and self._statsScroll:GetNamedChild("ScrollChild")  or nil
    self._leftChild    = self._leftScroll   and self._leftScroll:GetNamedChild("ScrollChild")   or nil
    self._middleChild  = self._middleScroll and self._middleScroll:GetNamedChild("ScrollChild") or nil
    self._rightChild   = self._rightScroll  and self._rightScroll:GetNamedChild("ScrollChild")  or nil

    self._rowsStats = {}
    self._rowsLeft = {}
    self._rowsMiddle = {}
    self._rowsRight = {}

    -- Pane width state. Stored as fractions of the available pane width so
    -- they survive window resizes; the last pane in PANE_ORDER is the
    -- remainder and stores no fraction. Restored from SavedVars; falls back to
    -- the even-split defaults.
    local saved = RM.db and RM.db.windowState and RM.db.windowState.paneFracs
    self._paneFracs = {}
    for i = 1, #PANE_ORDER - 1 do
        local name = PANE_ORDER[i]
        self._paneFracs[name] = (saved and saved[name]) or DEFAULT_PANE_FRACS[name]
    end

    -- Create splitters once. There is one between each adjacent pair of panes
    -- (PANE_ORDER[i] / PANE_ORDER[i+1]); each splitter's "which" is the name of
    -- the pane on its left, whose right edge it drags. LayoutPanes anchors and
    -- sizes them on every resize.
    if not self._splitters then
        self._splitters = {}
        for i = 1, #PANE_ORDER - 1 do
            self._splitters[i] = self:CreateSplitter(
                "ResearchManagerWindowSplitter" .. i, PANE_ORDER[i])
        end
    end

    self.window:SetDimensionConstraints(WINDOW_MIN_W, WINDOW_MIN_H, WINDOW_MAX_W, WINDOW_MAX_H)

    -- Restore the last saved size and position, if any.
    local s = RM.db and RM.db.windowState
    if s then
        if s.width and s.height then
            self.window:SetDimensions(s.width, s.height)
        end
        if s.left and s.top then
            self.window:ClearAnchors()
            self.window:SetAnchor(TOPLEFT, GuiRoot, TOPLEFT, s.left, s.top)
        end
    end

    self:LayoutPanes()
end

-- Build a draggable vertical splitter. `which` is the name of the pane on the
-- splitter's left (the pane whose right edge it drags); during a drag we update
-- self._paneFracs[which] and relayout. CT_BACKDROP renders a solid
-- center color, which gives us a visible thin bar without needing a texture
-- asset; SetEdgeTexture("",...) is the no-op edge that addons commonly use to
-- get center-only fills.
function UI:CreateSplitter(name, which)
    local splitter = WINDOW_MANAGER:CreateControl(name, self.window, CT_BACKDROP)
    splitter:SetCenterColor(0.35, 0.35, 0.25, 0.7)
    splitter:SetEdgeColor(0.6, 0.55, 0.3, 0.9)
    splitter:SetEdgeTexture("", 1, 1, 0, 0)
    splitter:SetMouseEnabled(true)
    splitter:SetDrawTier(DT_HIGH)
    splitter._dragging = false
    splitter._which = which

    splitter:SetHandler("OnMouseEnter", function()
        if not splitter._dragging then
            splitter:SetCenterColor(0.55, 0.55, 0.3, 0.85)
        end
    end)
    splitter:SetHandler("OnMouseExit", function()
        if not splitter._dragging then
            splitter:SetCenterColor(0.35, 0.35, 0.25, 0.7)
        end
    end)
    splitter:SetHandler("OnMouseDown", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then
            splitter._dragging = true
            splitter:SetCenterColor(0.85, 0.75, 0.3, 1.0)
        end
    end)
    splitter:SetHandler("OnMouseUp", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT and splitter._dragging then
            splitter._dragging = false
            splitter:SetCenterColor(0.35, 0.35, 0.25, 0.7)
            self:PersistPaneFractions()
            -- Rebuild rows at the new pane widths. LayoutPanes (run every
            -- frame during the drag) only resizes the scroll containers; the
            -- row labels keep their creation-time width, so text wraps at the
            -- old column width until we re-render. Done on release, not during
            -- the drag, to avoid rebuilding every frame.
            self:RefreshWindow()
        end
    end)
    -- OnUpdate fires every frame; we only do work while a drag is in
    -- progress. GetUIMousePosition returns mouse coords in UI units, same
    -- coordinate space as control:GetLeft()/GetTop().
    splitter:SetHandler("OnUpdate", function()
        if splitter._dragging then
            local mx = GetUIMousePosition()
            self:UpdatePaneFractionFromDrag(which, mx)
        end
    end)
    return splitter
end

-- Map self._paneScrolls names to the live scroll controls. Built lazily so it
-- always reflects whatever InitWindow grabbed.
function UI:PaneScroll(name)
    if name == "stats"  then return self._statsScroll end
    if name == "left"   then return self._leftScroll end
    if name == "middle" then return self._middleScroll end
    if name == "right"  then return self._rightScroll end
end

-- Resolve the pixel width of every pane from the stored fractions. The first
-- N-1 panes take floor(panesAvail * frac) clamped to MIN_PANE_W; the last pane
-- absorbs the remainder. If that remainder would fall below MIN_PANE_W we claw
-- width back from the earlier panes (right-to-left) so every pane keeps its
-- minimum where the window is wide enough; on a too-narrow window the last
-- pane is the one that ends up sub-minimum. Returns a name->width map.
function UI:ComputePaneWidths(panesAvail)
    local fracs = self._paneFracs or DEFAULT_PANE_FRACS
    local widths = {}
    for i = 1, #PANE_ORDER - 1 do
        local name = PANE_ORDER[i]
        local frac = fracs[name] or DEFAULT_PANE_FRACS[name] or (1 / #PANE_ORDER)
        widths[name] = math.max(MIN_PANE_W, math.floor(panesAvail * frac))
    end

    local lastName = PANE_ORDER[#PANE_ORDER]
    local function sumFixed()
        local s = 0
        for i = 1, #PANE_ORDER - 1 do s = s + widths[PANE_ORDER[i]] end
        return s
    end

    local deficit = MIN_PANE_W - (panesAvail - sumFixed())
    for i = #PANE_ORDER - 1, 1, -1 do
        if deficit <= 0 then break end
        local name = PANE_ORDER[i]
        local canTake = widths[name] - MIN_PANE_W
        if canTake > 0 then
            local take = math.min(canTake, deficit)
            widths[name] = widths[name] - take
            deficit = deficit - take
        end
    end

    widths[lastName] = panesAvail - sumFixed()
    return widths
end

-- Map a raw mouse X coordinate to a new fraction for the dragged splitter and
-- relayout. `which` is the pane on the splitter's left; we set its width to the
-- distance from its left edge to the mouse, clamped so it and every pane to its
-- right keep MIN_PANE_W. Panes to the left keep their widths; the remainder
-- (last) pane shrinks/grows to absorb the change.
function UI:UpdatePaneFractionFromDrag(which, mouseX)
    if not self.window then return end
    local winLeft = self.window:GetLeft() or 0
    local winW = self.window:GetWidth() or 0
    local nSplit = #PANE_ORDER - 1
    local panesAvail = winW - 2 * PANE_SIDE_MARGIN - nSplit * SPLITTER_WIDTH
    if panesAvail <= 0 then return end

    local widths = self:ComputePaneWidths(panesAvail)

    -- Left edge (screen X) of the dragged pane, and width reserved to its
    -- right: fixed-fraction panes keep their current width, the remainder pane
    -- reserves MIN_PANE_W.
    local paneLeftX = winLeft + PANE_SIDE_MARGIN
    local leftFixed = 0
    local seen = false
    local rightReserve = 0
    for i, name in ipairs(PANE_ORDER) do
        if not seen and name ~= which then
            paneLeftX = paneLeftX + widths[name] + SPLITTER_WIDTH
            leftFixed = leftFixed + widths[name]
        end
        if seen then
            rightReserve = rightReserve + (i == #PANE_ORDER and MIN_PANE_W or widths[name])
        end
        if name == which then seen = true end
    end

    local newW = mouseX - paneLeftX
    local maxW = panesAvail - leftFixed - rightReserve
    newW = math.max(MIN_PANE_W, math.min(maxW, newW))
    self._paneFracs[which] = newW / panesAvail

    self:LayoutPanes()
end

-- Snapshot the current fractions into SavedVars so a /reloadui or relogin
-- preserves the layout. Only the first N-1 panes carry a fraction.
function UI:PersistPaneFractions()
    if not RM.db then return end
    RM.db.windowState = RM.db.windowState or {}
    local saved = {}
    for i = 1, #PANE_ORDER - 1 do
        local name = PANE_ORDER[i]
        saved[name] = self._paneFracs[name]
    end
    RM.db.windowState.paneFracs = saved
end

-- Recompute pane positions/dimensions from the current window size and the
-- stored fractions. Layout is the PANE_ORDER panes interleaved with splitters:
--
--   [pane1][splitter1][pane2][splitter2]...[paneN]
--
-- All controls extend from PANE_TOP_MARGIN down to PANE_BOTTOM_MARGIN above the
-- window's bottom. Widths come from ComputePaneWidths.
function UI:LayoutPanes()
    if not self.window or not self._leftScroll then return end
    local winW = self.window:GetWidth() or 0
    local winH = self.window:GetHeight() or 0
    if winW <= 0 or winH <= 0 then return end
    local availH = winH - PANE_TOP_MARGIN - PANE_BOTTOM_MARGIN
    local nSplit = #PANE_ORDER - 1
    local panesAvail = winW - 2 * PANE_SIDE_MARGIN - nSplit * SPLITTER_WIDTH
    if panesAvail <= 0 then return end

    local widths = self:ComputePaneWidths(panesAvail)

    local prev = nil  -- the control the next one anchors to the right of
    for i, name in ipairs(PANE_ORDER) do
        local scroll = self:PaneScroll(name)
        if scroll then
            scroll:ClearAnchors()
            if prev then
                scroll:SetAnchor(TOPLEFT, prev, TOPRIGHT, 0, 0)
            else
                scroll:SetAnchor(TOPLEFT, self.window, TOPLEFT, PANE_SIDE_MARGIN, PANE_TOP_MARGIN)
            end
            scroll:SetDimensions(widths[name], availH)
            prev = scroll
        end

        local splitter = self._splitters and self._splitters[i]
        if i < #PANE_ORDER and splitter then
            splitter:ClearAnchors()
            splitter:SetAnchor(TOPLEFT, prev or self.window, TOPRIGHT, 0, 0)
            splitter:SetDimensions(SPLITTER_WIDTH, availH)
            prev = splitter
        end
    end
end

-- Point the Add* helpers at one of the panes. The helpers read
-- self.scrollChild and self._rows, so a UsePane call before a render
-- function is the only thing they need to target the right column.
function UI:UsePane(name)
    if name == "stats" then
        self.scrollChild = self._statsChild
        self._rows = self._rowsStats
        self._activeScroll = self._statsScroll
    elseif name == "left" then
        self.scrollChild = self._leftChild
        self._rows = self._rowsLeft
        self._activeScroll = self._leftScroll
    elseif name == "middle" then
        self.scrollChild = self._middleChild
        self._rows = self._rowsMiddle
        self._activeScroll = self._middleScroll
    elseif name == "right" then
        self.scrollChild = self._rightChild
        self._rows = self._rowsRight
        self._activeScroll = self._rightScroll
    end
end

-- Persist position. Wired from XML OnMoveStop.
function UI:OnWindowMoved()
    if not self.window or not RM.db then return end
    RM.db.windowState = RM.db.windowState or {}
    RM.db.windowState.left = self.window:GetLeft()
    RM.db.windowState.top  = self.window:GetTop()
end

-- Persist size, update saved top-left so the window doesn't jump next session,
-- relay out the panes at the new width, and rebuild rows. Wired from XML
-- OnResizeStop.
function UI:OnWindowResized()
    if not self.window or not RM.db then return end
    RM.db.windowState = RM.db.windowState or {}
    RM.db.windowState.width, RM.db.windowState.height = self.window:GetDimensions()
    RM.db.windowState.left = self.window:GetLeft()
    RM.db.windowState.top  = self.window:GetTop()
    self:LayoutPanes()
    self:RefreshWindow()
end

function UI:ShowWindow()
    if not self.window then self:InitWindow() end
    if not self.window then return end
    self:RefreshWindow()
    self.window:SetHidden(false)
    self.window:BringWindowToTop()
    -- Free the mouse cursor so the window's buttons, splitters, and rows are
    -- clickable even when opened from the HUD (reticle / mouse-look) rather than
    -- from an already-open menu. Track whether we were the ones to enter UI mode
    -- so HideWindow only hands the reticle back if we took it (don't yank the
    -- cursor out from under an inventory/station the player already had open).
    if not SCENE_MANAGER:IsInUIMode() then
        SCENE_MANAGER:SetInUIMode(true)
        self._tookUIMode = true
    end
end

function UI:HideWindow()
    if self.window then self.window:SetHidden(true) end
    if self._tookUIMode then
        self._tookUIMode = false
        SCENE_MANAGER:SetInUIMode(false)
    end
end

function UI:ToggleWindow()
    if not self.window then self:InitWindow() end
    if not self.window then return end
    if self.window:IsHidden() then
        self:ShowWindow()
    else
        self:HideWindow()
    end
end

local function ClearRowList(rows)
    for _, row in ipairs(rows or {}) do
        row:SetHidden(true)
        row:ClearAnchors()
    end
end

-- Anchor every row's LEFT to the scrollChild (so X offsets don't cascade) and
-- only use the previous row for vertical positioning. ESO controls accept
-- multiple SetAnchor calls -- each combination of (anchorPoint, relativeTo)
-- replaces a prior anchor with the same anchorPoint.

local function AddHeader(self, text, prev)
    local label = WINDOW_MANAGER:CreateControl(nil, self.scrollChild, CT_LABEL)
    label:SetFont("ZoFontWinH3")
    label:SetText(SECTION_HEADER_COLOR .. text .. SECTION_FOOTER_COLOR)
    label:SetDimensions(ContentWidth(self), 28)
    label:SetAnchor(LEFT, self.scrollChild, LEFT, 0, 0)
    if prev then
        label:SetAnchor(TOP, prev, BOTTOM, 0, 12)
    else
        label:SetAnchor(TOP, self.scrollChild, TOP, 0, 0)
    end
    self._rows[#self._rows + 1] = label
    return label
end

local function AddTextRow(self, text, prev, indent, color)
    indent = indent or 0
    local row = WINDOW_MANAGER:CreateControl(nil, self.scrollChild, CT_LABEL)
    row:SetFont("ZoFontGame")
    row:SetText((color or "|cCCCCCC") .. text .. "|r")
    row:SetDimensions(ContentWidth(self) - indent, 22)
    row:SetAnchor(LEFT, self.scrollChild, LEFT, indent, 0)
    row:SetAnchor(TOP, prev, BOTTOM, 0, 2)
    self._rows[#self._rows + 1] = row
    return row
end

-- Short labels for each craft used in the per-alt free-slot summary.
local CRAFT_SHORT = {
    [CRAFTING_TYPE_BLACKSMITHING]   = "BS",
    [CRAFTING_TYPE_CLOTHIER]        = "CL",
    [CRAFTING_TYPE_WOODWORKING]     = "WW",
    [CRAFTING_TYPE_JEWELRYCRAFTING] = "JC",
}

local function BuildSlotInfo(snap, now)
    if not snap or not snap.crafts then return "" end
    now = now or GetTimeStamp()
    local parts = {}
    for _, ct in ipairs(RM.CRAFTS) do
        local craft = snap.crafts[ct]
        if craft then
            local maxS = craft.maxSlots or 0
            -- Routes through Scanner so research that finished while the alt
            -- was offline doesn't get counted as occupying a slot.
            local active = RM.Scanner:CountActiveSlots(snap, ct, now)
            local free = math.max(0, maxS - active)
            parts[#parts + 1] = string.format("%s:%d/%d", CRAFT_SHORT[ct] or "?", free, maxS)
        end
    end
    return table.concat(parts, "  ")
end

-- Full-width button at the top of a pane. Used for "Queue All Characters" and
-- "Clear Queue". The button stretches to fill the pane's content width minus
-- a small margin, so it stays prominent at the top regardless of pane width.
local function AddButtonRow(self, label, prev, onClick)
    local row = WINDOW_MANAGER:CreateControl(nil, self.scrollChild, CT_CONTROL)
    row:SetDimensions(ContentWidth(self), 32)
    row:SetAnchor(LEFT, self.scrollChild, LEFT, 0, 0)
    if prev then
        row:SetAnchor(TOP, prev, BOTTOM, 0, 8)
    else
        row:SetAnchor(TOP, self.scrollChild, TOP, 0, 0)
    end

    local btn = WINDOW_MANAGER:CreateControlFromVirtual(nil, row, "ZO_DefaultButton")
    btn:SetDimensions(ContentWidth(self) - 16, 28)
    btn:SetAnchor(CENTER, row, CENTER, 0, 0)
    btn:SetText(label)
    btn:SetHandler("OnClicked", onClick)

    self._rows[#self._rows + 1] = row
    self._rows[#self._rows + 1] = btn
    return row
end

-- Header row that combines a click-to-toggle label and a small action button.
-- `buttonOnLeft` is optional: when true the button is anchored to the row's
-- left edge and the label fills the remaining space to its right (used by
-- the left-pane tree so Queue buttons aren't visually buried under varying-
-- length character names). When false/nil the layout is the legacy one --
-- label on the left, button pinned to the row's right edge -- used by the
-- right-pane bindings where the Clear button conventionally hangs off the
-- end of the row.
local function AddExpanderWithActionRow(self, text, prev, indent, color, onClickHeader, buttonLabel, onClickButton, buttonOnLeft)
    indent = indent or 0
    local row = WINDOW_MANAGER:CreateControl(nil, self.scrollChild, CT_CONTROL)
    row:SetDimensions(ContentWidth(self) - indent, 26)
    row:SetAnchor(LEFT, self.scrollChild, LEFT, indent, 0)
    row:SetAnchor(TOP, prev, BOTTOM, 0, 2)

    local btn = WINDOW_MANAGER:CreateControlFromVirtual(nil, row, "ZO_DefaultButton")
    btn:SetDimensions(70, 22)
    btn:SetText(buttonLabel)
    btn:SetHandler("OnClicked", onClickButton)

    local label = WINDOW_MANAGER:CreateControl(nil, row, CT_LABEL)
    label:SetFont("ZoFontGame")
    label:SetText((color or "|cCCCCCC") .. text .. "|r")
    label:SetVerticalAlignment(TEXT_ALIGN_CENTER)
    label:SetMouseEnabled(true)
    label:SetHandler("OnMouseUp", function(_, button, upInside)
        if button == MOUSE_BUTTON_INDEX_LEFT and upInside then onClickHeader() end
    end)

    if buttonOnLeft then
        btn:SetAnchor(LEFT, row, LEFT, 0, 0)
        label:SetAnchor(LEFT, btn, RIGHT, 6, 0)
        label:SetAnchor(RIGHT, row, RIGHT, -4, 0)
    else
        btn:SetAnchor(RIGHT, row, RIGHT, -4, 0)
        label:SetAnchor(LEFT, row, LEFT, 0, 0)
        label:SetAnchor(RIGHT, row, RIGHT, -80, 0)
    end

    self._rows[#self._rows + 1] = row
    self._rows[#self._rows + 1] = label
    self._rows[#self._rows + 1] = btn
    return row
end

-- Compact variant of AddExpanderWithActionRow: 24px icon button on the
-- left, label fills the rest of the row, tooltip on the icon explains
-- the action. Used by the character tree to free horizontal space (the
-- old 70px text button dominated narrow panes).
local function AddExpanderWithIconButton(self, text, prev, indent, color, onClickHeader, iconPath, tooltipText, onClickButton)
    indent = indent or 0
    local row = WINDOW_MANAGER:CreateControl(nil, self.scrollChild, CT_CONTROL)
    row:SetDimensions(ContentWidth(self) - indent, 26)
    row:SetAnchor(LEFT, self.scrollChild, LEFT, indent, 0)
    row:SetAnchor(TOP, prev, BOTTOM, 0, 2)

    -- CT_BUTTON renders just the texture set via SetNormalTexture (no
    -- ESO button chrome), giving us an icon button. Slight alpha lift on
    -- hover makes the affordance discoverable without needing a separate
    -- hover-state texture asset.
    local btn = WINDOW_MANAGER:CreateControl(nil, row, CT_BUTTON)
    btn:SetDimensions(24, 24)
    btn:SetNormalTexture(iconPath)
    btn:SetMouseOverTexture(iconPath)
    btn:SetPressedTexture(iconPath)
    btn:SetClickSound("Click")
    btn:SetAnchor(LEFT, row, LEFT, 0, 0)
    btn:SetAlpha(0.75)
    btn:SetHandler("OnMouseEnter", function(c)
        c:SetAlpha(1.0)
        if tooltipText then
            InitializeTooltip(InformationTooltip, c, BOTTOM, 0, -4)
            SetTooltipText(InformationTooltip, tooltipText)
        end
    end)
    btn:SetHandler("OnMouseExit", function(c)
        c:SetAlpha(0.75)
        ClearTooltip(InformationTooltip)
    end)
    btn:SetHandler("OnClicked", onClickButton)

    local label = WINDOW_MANAGER:CreateControl(nil, row, CT_LABEL)
    label:SetFont("ZoFontGame")
    label:SetText((color or "|cCCCCCC") .. text .. "|r")
    label:SetVerticalAlignment(TEXT_ALIGN_CENTER)
    label:SetMouseEnabled(true)
    label:SetHandler("OnMouseUp", function(_, button, upInside)
        if button == MOUSE_BUTTON_INDEX_LEFT and upInside then onClickHeader() end
    end)
    label:SetAnchor(LEFT, btn, RIGHT, 6, 0)
    label:SetAnchor(RIGHT, row, RIGHT, -4, 0)

    self._rows[#self._rows + 1] = row
    self._rows[#self._rows + 1] = label
    self._rows[#self._rows + 1] = btn
    return row
end

-- A label row that responds to left-click. Used for the per-character
-- collapsible group headers in the gaps section.
local function AddClickableRow(self, text, prev, indent, color, onClick)
    indent = indent or 0
    local row = WINDOW_MANAGER:CreateControl(nil, self.scrollChild, CT_LABEL)
    row:SetFont("ZoFontGame")
    row:SetText((color or "|cCCCCCC") .. text .. "|r")
    row:SetDimensions(ContentWidth(self) - indent, 22)
    row:SetAnchor(LEFT, self.scrollChild, LEFT, indent, 0)
    row:SetAnchor(TOP, prev, BOTTOM, 0, 2)
    row:SetMouseEnabled(true)
    row:SetHandler("OnMouseUp", function(_, button, upInside)
        if button == MOUSE_BUTTON_INDEX_LEFT and upInside then onClick() end
    end)
    self._rows[#self._rows + 1] = row
    return row
end

local function AddRowWithRemoveButton(self, text, prev, reference)
    local row = WINDOW_MANAGER:CreateControl(nil, self.scrollChild, CT_CONTROL)
    row:SetDimensions(ContentWidth(self), 26)
    row:SetAnchor(LEFT, self.scrollChild, LEFT, 0, 0)
    row:SetAnchor(TOP, prev, BOTTOM, 0, 4)

    local label = WINDOW_MANAGER:CreateControl(nil, row, CT_LABEL)
    label:SetFont("ZoFontGame")
    label:SetText("|cCCCCCC" .. text .. "|r")
    label:SetAnchor(LEFT, row, LEFT, 8, 0)
    label:SetAnchor(RIGHT, row, RIGHT, -100, 0)
    label:SetVerticalAlignment(TEXT_ALIGN_CENTER)

    local btn = WINDOW_MANAGER:CreateControlFromVirtual(nil, row, "ZO_DefaultButton")
    btn:SetDimensions(86, 24)
    btn:SetAnchor(RIGHT, row, RIGHT, -4, 0)
    btn:SetText(GetString(SI_RM_WINDOW_REMOVE))
    btn:SetHandler("OnClicked", function()
        if RM.LLC and reference then
            RM.LLC:cancelItemByReference(reference)
            UI:RefreshWindow()
        end
    end)

    self._rows[#self._rows + 1] = row
    self._rows[#self._rows + 1] = label
    self._rows[#self._rows + 1] = btn
    return row
end

-- Indented text row with a small Remove button on the right. Used inside the
-- bindings section so a single binding can be dropped without nuking every
-- binding for that recipient. The Remove handler is supplied by the caller
-- since the action (drop a craftedFor entry vs cancel an LLC queue request)
-- differs between sections.
local function AddIndentedRowWithRemove(self, text, prev, indent, onRemove)
    indent = indent or 24
    local row = WINDOW_MANAGER:CreateControl(nil, self.scrollChild, CT_CONTROL)
    row:SetDimensions(ContentWidth(self) - indent, 24)
    row:SetAnchor(LEFT, self.scrollChild, LEFT, indent, 0)
    row:SetAnchor(TOP, prev, BOTTOM, 0, 2)

    local label = WINDOW_MANAGER:CreateControl(nil, row, CT_LABEL)
    label:SetFont("ZoFontGame")
    label:SetText("|cCCCCCC" .. text .. "|r")
    label:SetAnchor(LEFT, row, LEFT, 0, 0)
    label:SetAnchor(RIGHT, row, RIGHT, -80, 0)
    label:SetVerticalAlignment(TEXT_ALIGN_CENTER)

    local btn = WINDOW_MANAGER:CreateControlFromVirtual(nil, row, "ZO_DefaultButton")
    btn:SetDimensions(70, 22)
    btn:SetAnchor(RIGHT, row, RIGHT, -4, 0)
    btn:SetText(GetString(SI_RM_WINDOW_REMOVE))
    btn:SetHandler("OnClicked", onRemove)

    self._rows[#self._rows + 1] = row
    self._rows[#self._rows + 1] = label
    self._rows[#self._rows + 1] = btn
    return row
end

-- Reuse the queue parser from Crafter.lua's PrintQueue. Kept inline here so
-- the window doesn't depend on Crafter internals.
local function ParseRef(ref)
    if type(ref) ~= "string" then return nil end
    local name, ct, line, trait = ref:match("^RM:(.-):(%d+):(%d+):(%d+)$")
    if not name then return nil end
    return name, tonumber(ct), tonumber(line), tonumber(trait)
end

local STATION_NAME_BY_TYPE = {
    [CRAFTING_TYPE_BLACKSMITHING]   = "Blacksmithing",
    [CRAFTING_TYPE_CLOTHIER]        = "Clothier",
    [CRAFTING_TYPE_WOODWORKING]     = "Woodworking",
    [CRAFTING_TYPE_JEWELRYCRAFTING] = "Jewelry",
}

-- Per-character research stats rolled up across all four crafts: known/total
-- traits, fully-completed research lines, active research slots, and a
-- per-craft known/total breakdown. One pass over the snapshot feeds every
-- figure the stats pane shows.
local function ComputeCharStats(snap, now)
    local s = {
        known = 0, total = 0,
        linesDone = 0, linesTotal = 0,
        slotsUsed = 0, slotsMax = 0,
        perCraft = {},
    }
    if not snap or not snap.crafts then return s end
    now = now or GetTimeStamp()
    for _, ct in ipairs(RM.CRAFTS) do
        local craft = snap.crafts[ct]
        if craft then
            local cKnown, cTotal = 0, 0
            for _, line in pairs(craft.lines or {}) do
                local lineTraits, lineKnown = 0, 0
                for _, trait in pairs(line.traits or {}) do
                    lineTraits = lineTraits + 1
                    if trait.known then lineKnown = lineKnown + 1 end
                end
                if lineTraits > 0 then
                    s.linesTotal = s.linesTotal + 1
                    if lineKnown == lineTraits then s.linesDone = s.linesDone + 1 end
                end
                cKnown = cKnown + lineKnown
                cTotal = cTotal + lineTraits
            end
            s.known = s.known + cKnown
            s.total = s.total + cTotal
            s.slotsMax = s.slotsMax + (craft.maxSlots or 0)
            s.slotsUsed = s.slotsUsed + RM.Scanner:CountActiveSlots(snap, ct, now)
            s.perCraft[ct] = { known = cKnown, total = cTotal }
        end
    end
    return s
end

local function Pct(known, total)
    return total > 0 and math.floor(known / total * 100) or 0
end

-- ETA seconds -> display string. Zero (or less) means there's nothing left to
-- research, shown as "Complete" rather than "0s".
local function FormatEta(secs)
    if not secs or secs <= 0 then return GetString(SI_RM_WINDOW_STATS_ETA_DONE) end
    return FormatRemaining(secs)
end

-- Leftmost pane: research statistics. An account-wide rollup at the top, then
-- one block per character (sorted by name) with overall %, completed lines,
-- active slots, and a per-craft % line. Read-only -- no buttons.
function UI:RenderStats()
    local snapByKey = RM.db.characters or {}
    local now = GetTimeStamp()

    local last = AddHeader(self, GetString(SI_RM_WINDOW_STATS_HEADER), nil)

    local charKeys = {}
    for k, snap in pairs(snapByKey) do
        if type(snap) == "table" and snap.crafts then
            charKeys[#charKeys + 1] = k
        end
    end
    if #charKeys == 0 then
        AddTextRow(self, GetString(SI_RM_WINDOW_NO_CHARS), last, 8, "|c888888")
        return
    end
    table.sort(charKeys, function(a, b)
        local na = (snapByKey[a] and snapByKey[a].name) or a
        local nb = (snapByKey[b] and snapByKey[b].name) or b
        return na < nb
    end)

    local myKey = RM:GetCharacterKey()

    -- Compute per-character stats once and accumulate account totals. Each
    -- character researches in parallel, so the account-wide finish time is the
    -- slowest character's ETA, not the sum.
    local statsByKey = {}
    local etaByKey = {}
    local accKnown, accTotal, accLinesDone, accLinesTotal, accEta = 0, 0, 0, 0, 0
    for _, k in ipairs(charKeys) do
        local st = ComputeCharStats(snapByKey[k], now)
        statsByKey[k] = st
        etaByKey[k] = RM.Scanner:EstimateTimeToComplete(snapByKey[k], now)
        accKnown = accKnown + st.known
        accTotal = accTotal + st.total
        accLinesDone = accLinesDone + st.linesDone
        accLinesTotal = accLinesTotal + st.linesTotal
        if etaByKey[k] > accEta then accEta = etaByKey[k] end
    end

    -- Account-wide rollup.
    last = AddTextRow(self, GetString(SI_RM_WINDOW_STATS_ACCOUNT), last, 0, "|cFFCC66")
    last = AddTextRow(self, string.format("%s %d%%  (%d/%d)",
        GetString(SI_RM_WINDOW_STATS_OVERALL), Pct(accKnown, accTotal), accKnown, accTotal),
        last, 16, "|cCCCCCC")
    last = AddTextRow(self, string.format("%s %d/%d",
        GetString(SI_RM_WINDOW_STATS_LINES), accLinesDone, accLinesTotal),
        last, 16, "|c888888")
    last = AddTextRow(self, string.format("%s %s",
        GetString(SI_RM_WINDOW_STATS_ETA), FormatEta(accEta)),
        last, 16, "|cCCCCCC")

    -- Per-character blocks.
    for _, k in ipairs(charKeys) do
        local snap = snapByKey[k]
        local st = statsByKey[k]
        local name = snap.name or k
        local currentTag = (k == myKey) and "  |c66FF66(current)|r" or ""

        last = AddTextRow(self, name .. currentTag, last, 0, "|cFFCC66")
        last = AddTextRow(self, string.format("%s %d%%  (%d/%d)",
            GetString(SI_RM_WINDOW_STATS_OVERALL), Pct(st.known, st.total), st.known, st.total),
            last, 16, "|cCCCCCC")
        last = AddTextRow(self, string.format("%s %d/%d",
            GetString(SI_RM_WINDOW_STATS_LINES), st.linesDone, st.linesTotal),
            last, 16, "|cCCCCCC")
        last = AddTextRow(self, string.format("%s %d/%d",
            GetString(SI_RM_WINDOW_STATS_SLOTS), st.slotsUsed, st.slotsMax),
            last, 16, "|cCCCCCC")
        last = AddTextRow(self, string.format("%s %s",
            GetString(SI_RM_WINDOW_STATS_ETA), FormatEta(etaByKey[k])),
            last, 16, "|cCCCCCC")

        local parts = {}
        for _, ct in ipairs(RM.CRAFTS) do
            local pc = st.perCraft[ct]
            if pc and pc.total > 0 then
                parts[#parts + 1] = string.format("%s %d%%",
                    CRAFT_SHORT[ct] or "?", Pct(pc.known, pc.total))
            end
        end
        if #parts > 0 then
            last = AddTextRow(self, table.concat(parts, "  "), last, 16, "|c888888")
        end
    end
end

-- Full refresh: clear each pane's row list, then UsePane + render per pane.
-- A render method only needs to read RM state and append rows via the Add*
-- helpers -- those write to whichever pane UsePane last selected.
function UI:RefreshWindow()
    if not self._leftChild then self:InitWindow() end
    if not self._leftChild then return end

    ClearRowList(self._rowsStats)
    ClearRowList(self._rowsLeft)
    ClearRowList(self._rowsMiddle)
    ClearRowList(self._rowsRight)
    self._rowsStats = {}
    self._rowsLeft = {}
    self._rowsMiddle = {}
    self._rowsRight = {}

    self:UsePane("stats")
    self:RenderStats()

    self:UsePane("left")
    self:RenderCharacterTree()

    self:UsePane("middle")
    self:RenderCraftingQueue()

    self:UsePane("right")
    self:RenderResearchQueue()
end

-- Left pane: collapsible character tree.
--
-- Tree state is held on self._treeCollapsed keyed by a tag like "char:<key>"
-- or "skill:<key>:<ct>". Character rows default to COLLAPSED (nil => collapsed)
-- so the pane opens as a scannable one-line-per-character overview; the inline
-- synopsis beside the name surfaces the key numbers without expanding. Skill
-- rows still default expanded once a character is opened. Click toggles state.
function UI:RenderCharacterTree()
    local snapByKey = RM.db.characters or {}
    self._treeCollapsed = self._treeCollapsed or {}

    -- Top button: queue crafts for every alt at once.
    local last = AddButtonRow(self, GetString(SI_RM_WINDOW_QUEUE_ALL_CHARS), nil, function()
        RM.Crafter:QueueForAll()
        self:RefreshWindow()
    end)

    last = AddHeader(self, GetString(SI_RM_WINDOW_CHARS_HEADER), last)

    -- Sort by character name so order is stable across refreshes.
    local charKeys = {}
    for k, snap in pairs(snapByKey) do
        if type(snap) == "table" and snap.crafts then
            charKeys[#charKeys + 1] = k
        end
    end
    if #charKeys == 0 then
        last = AddTextRow(self, GetString(SI_RM_WINDOW_NO_CHARS), last, 8, "|c888888")
        return
    end
    table.sort(charKeys, function(a, b)
        local na = (snapByKey[a] and snapByKey[a].name) or a
        local nb = (snapByKey[b] and snapByKey[b].name) or b
        return na < nb
    end)

    local myKey = RM:GetCharacterKey()
    local now = GetTimeStamp()

    for _, charKey in ipairs(charKeys) do
        local snap = snapByKey[charKey]
        local charName = snap.name or charKey
        local isCurrent = (charKey == myKey)
        local charTag = "char:" .. charKey
        -- Character rows default to collapsed (nil => collapsed). Explicit user
        -- toggles override: once the user clicks the row, self._treeCollapsed
        -- holds a concrete true/false that wins over the default.
        local explicit = self._treeCollapsed[charTag]
        local allDone = RM.Scanner:IsAllResearched(snap)
        local charCollapsed
        if explicit == nil then
            charCollapsed = true
        else
            charCollapsed = explicit and true or false
        end
        local charMarker = charCollapsed and "[+] " or "[-] "
        local doneTag = allDone and "  |c66FF66(all researched)|r" or ""
        local currentTag = isCurrent and "  |c66FF66(current)|r" or ""

        -- Inline synopsis of active research slots per craft, e.g.
        -- "BS 1/3, CL 1/2". Lets the collapsed row convey current state at a
        -- glance. Skips crafts with no data (station not yet visited), and the
        -- whole synopsis is dropped for fully-researched characters -- the
        -- "(all researched)" tag already says everything there is to say.
        local synopsis = ""
        if not allDone then
            local synParts = {}
            for _, ct in ipairs(RM.CRAFTS) do
                local craft = snap.crafts[ct]
                if craft then
                    local maxS = craft.maxSlots or 0
                    local active = RM.Scanner:CountActiveSlots(snap, ct, now)
                    synParts[#synParts + 1] =
                        string.format("%s %d/%d", CRAFT_SHORT[ct] or "?", active, maxS)
                end
            end
            if #synParts > 0 then
                synopsis = "  |c888888" .. table.concat(synParts, ", ") .. "|r"
            end
        end

        local charHeader = charMarker .. charName .. currentTag .. doneTag .. synopsis

        local capturedCharKey = charKey
        local capturedCollapsed = charCollapsed
        last = AddExpanderWithIconButton(self, charHeader, last, 0, "|cFFCC66",
            function()
                -- Toggle off the currently *effective* state so a click on an
                -- auto-collapsed row expands it (rather than re-applying the
                -- auto-collapse).
                self._treeCollapsed[charTag] = not capturedCollapsed
                self:RefreshWindow()
            end,
            QUEUE_ICON_PATH,
            GetString(SI_RM_WINDOW_QUEUE_CHAR_TOOLTIP),
            function()
                if isCurrent then
                    RM:AnnounceWarn(GetString(SI_RM_WINDOW_CURRENT_NO_QUEUE))
                else
                    RM.Crafter:QueueForRecipient(capturedCharKey)
                    self:RefreshWindow()
                end
            end)

        if not charCollapsed then
            for _, ct in ipairs(RM.CRAFTS) do
                local craft = snap.crafts[ct]
                if craft then
                    local skillTag = "skill:" .. charKey .. ":" .. ct
                    local skillCollapsed = self._treeCollapsed[skillTag]  -- nil => expanded
                    local skillMarker = skillCollapsed and "[+] " or "[-] "
                    local maxS = craft.maxSlots or 0
                    local active = RM.Scanner:CountActiveSlots(snap, ct, now)
                    local known, total = RM.Scanner:CountTraitProgress(snap, ct)
                    local pct = total > 0 and math.floor(known / total * 100) or 0
                    local skillHeader = string.format(
                        "%s%s  |c888888(%d%% researched, %d/%d slots used)|r",
                        skillMarker, RM:GetCraftName(ct), pct, active, maxS)

                    -- Skill rows are buttonless: per-skill queueing is a
                    -- rare action and the four per-char buttons it would add
                    -- crowd the pane. The character-level Queue button covers
                    -- the common case; the chat command "/research craft
                    -- <name>" handles a single recipient when needed.
                    --
                    -- Indent 60 puts the skill name well past the parent
                    -- row's 24+6=30px icon footprint, so it reads as
                    -- visually nested rather than just-past-the-icon.
                    last = AddClickableRow(self, skillHeader, last, 60, "|cCCCCCC",
                        function()
                            local cur = self._treeCollapsed[skillTag] and true or false
                            self._treeCollapsed[skillTag] = not cur
                            self:RefreshWindow()
                        end)

                    if not skillCollapsed then
                        -- Each slot row: filled with active research (sorted
                        -- soonest-first) or "Empty" once the active entries
                        -- run out. maxSlots determines how many rows show.
                        local active_list = {}
                        for lineIndex, line in pairs(craft.lines or {}) do
                            for traitIndex, trait in pairs(line.traits or {}) do
                                if trait.researching and not trait.known then
                                    active_list[#active_list + 1] = {
                                        lineName = line.name,
                                        traitType = trait.type,
                                        endsAt = trait.endsAt,
                                        remaining = trait.endsAt and (trait.endsAt - now) or nil,
                                        ready = trait.endsAt and (trait.endsAt - now <= 0) or false,
                                    }
                                end
                            end
                        end
                        table.sort(active_list, function(a, b)
                            local ra = a.remaining or math.huge
                            local rb = b.remaining or math.huge
                            return ra < rb
                        end)

                        -- Skill row sits at indent 60. Slot text at 84 lands
                        -- one clear visual step past the skill name's left
                        -- edge while still leaving room for line + trait +
                        -- remaining-time text in a narrow pane.
                        local SLOT_INDENT = 84
                        local rowCount = math.max(maxS, #active_list)
                        -- Coalesce consecutive empty slots into one "N empty
                        -- slots" row -- a column of three "Empty" lines under
                        -- every untouched skill made the pane feel busier
                        -- than it was. flushEmpty() writes the run and resets.
                        local emptyRun = 0
                        local function flushEmpty()
                            if emptyRun > 0 then
                                local text
                                if emptyRun == 1 then
                                    text = GetString(SI_RM_WINDOW_SLOT_EMPTY)
                                else
                                    text = zo_strformat(
                                        GetString(SI_RM_WINDOW_SLOT_EMPTY_PLURAL), emptyRun)
                                end
                                last = AddTextRow(self, text, last, SLOT_INDENT, "|c666666")
                                emptyRun = 0
                            end
                        end

                        if rowCount == 0 then
                            last = AddTextRow(self, GetString(SI_RM_WINDOW_SLOT_EMPTY),
                                last, SLOT_INDENT, "|c666666")
                        else
                            for i = 1, rowCount do
                                local r = active_list[i]
                                if r then
                                    flushEmpty()
                                    local traitName = GetString("SI_ITEMTRAITTYPE", r.traitType) or "?"
                                    local lineName = r.lineName or "?"
                                    if lineName ~= "" then
                                        lineName = zo_strformat("<<t:1>>", lineName)
                                    end
                                    local timeText
                                    if r.ready then
                                        timeText = GetString(SI_RM_WINDOW_RESEARCH_READY)
                                    elseif r.remaining then
                                        timeText = FormatRemaining(r.remaining)
                                    else
                                        timeText = GetString(SI_RM_WINDOW_RESEARCH_NO_TIMER)
                                    end
                                    local color = r.ready and "|c66FF66" or "|cCCCCCC"
                                    local text = string.format("%s / %s -- %s",
                                        lineName, traitName, timeText)
                                    last = AddTextRow(self, text, last, SLOT_INDENT, color)
                                else
                                    emptyRun = emptyRun + 1
                                end
                            end
                            flushEmpty()
                        end
                    end
                end
            end
        end
    end
end

-- Middle pane: the LibLazyCrafting pending-craft queue.
-- "Clear Queue" at the top cancels every pending request in one go.
-- Per-row Remove cancels a single request.
function UI:RenderCraftingQueue()
    local queueEntries = {}
    if RM.LLC then
        local queue = RM.LLC:getAddonCraftingQueue()
        if type(queue) == "table" then
            for station, stationQueue in pairs(queue) do
                if type(stationQueue) == "table" then
                    for _, req in ipairs(stationQueue) do
                        queueEntries[#queueEntries + 1] = { station = station, req = req }
                    end
                end
            end
        end
    end

    -- Group the flattened queue by station type so all Blacksmithing requests
    -- sit together, then Clothier, etc. pairs() over the station map above is
    -- undefined-order; tie-break on the reference string for a stable render.
    table.sort(queueEntries, function(a, b)
        if a.station ~= b.station then return a.station < b.station end
        return tostring(a.req.reference) < tostring(b.req.reference)
    end)

    local last = AddButtonRow(self, GetString(SI_RM_WINDOW_CLEAR_QUEUE), nil, function()
        local cancelled = RM.Crafter:CancelAllLLCRequests()
        RM:Announce(zo_strformat(GetString(SI_RM_WINDOW_QUEUE_CLEARED), cancelled))
        self:RefreshWindow()
    end)

    last = AddHeader(self,
        zo_strformat(GetString(SI_RM_WINDOW_QUEUE_HEADER), #queueEntries), last)

    if #queueEntries == 0 then
        last = AddTextRow(self, GetString(SI_RM_WINDOW_EMPTY_QUEUE), last, 8, "|c888888")
        return
    end

    -- Per-station item counts so each station heading can show "Name (n)".
    local countByStation = {}
    for _, entry in ipairs(queueEntries) do
        countByStation[entry.station] = (countByStation[entry.station] or 0) + 1
    end

    -- Entries are sorted by station (see the table.sort above), so emit a
    -- station heading each time the station changes as we walk the list.
    local currentStation = nil
    for _, entry in ipairs(queueEntries) do
        local r = entry.req
        if entry.station ~= currentStation then
            currentStation = entry.station
            local stationName = STATION_NAME_BY_TYPE[entry.station]
                or ("Station " .. tostring(entry.station))
            last = AddHeader(self, string.format("%s (%d)",
                stationName, countByStation[entry.station]), last)
        end
        local recipient, refCraft, refLine, refTrait = ParseRef(r.reference)
        local itemName
        if refCraft and refLine then
            local raw = GetSmithingResearchLineInfo(refCraft, refLine)
            if raw and raw ~= "" then
                itemName = zo_strformat("<<t:1>>", raw)
            end
        end
        if not itemName or itemName == "" then
            itemName = "pattern " .. tostring(r.pattern or "?")
        end
        local traitType
        if refCraft and refLine and refTrait then
            traitType = GetSmithingResearchLineTraitInfo(refCraft, refLine, refTrait)
        end
        if not traitType then traitType = (r.trait or 1) - 1 end
        local traitName = GetString("SI_ITEMTRAITTYPE", traitType) or "?"
        local text = string.format("%s / %s -> %s",
            itemName, traitName, recipient or "?")
        last = AddRowWithRemoveButton(self, text, last, r.reference)
    end
end

-- Right pane: the research queue (crafted items awaiting research). Groups
-- by recipient with per-recipient Clear and per-binding Remove. Recipient
-- groups default to EXPANDED per the redesign -- the user almost always
-- wants to see what's sitting where.
function UI:RenderResearchQueue()
    local bindings = RM.db and RM.db.craftedFor or {}
    local byRecipient = {}
    local bindingsTotal = 0
    for uuidKey, info in pairs(bindings) do
        if type(info) == "table" and info.recipient then
            local key = info.recipient
            byRecipient[key] = byRecipient[key] or {}
            byRecipient[key][#byRecipient[key] + 1] = {
                uuidKey = uuidKey, when = info.when,
                itemLink = info.itemLink, craftingType = info.craftingType,
                lineIndex = info.lineIndex, traitIndex = info.traitIndex,
            }
            bindingsTotal = bindingsTotal + 1
        end
    end

    local last = AddHeader(self,
        zo_strformat(GetString(SI_RM_WINDOW_BINDINGS_HEADER), bindingsTotal), nil)

    if bindingsTotal == 0 then
        last = AddTextRow(self, GetString(SI_RM_WINDOW_EMPTY_BINDINGS), last, 8, "|c888888")
        return
    end

    -- nil default => collapsed, EXCEPT the current character's own group, which
    -- defaults expanded: if items are sitting in the research queue bound to the
    -- character you just logged in on, that's exactly what you opened the window
    -- to act on, so surface it without a click. The bindings list can otherwise
    -- grow long, so a fresh /reloadui shows a compact list of recipient headers;
    -- the user opens the ones they care about. Explicit user toggles override
    -- (true = collapsed, false = expanded).
    self._bindingsCollapsed = self._bindingsCollapsed or {}
    local myKey = RM:GetCharacterKey()

    local recipientKeys = {}
    for k in pairs(byRecipient) do recipientKeys[#recipientKeys + 1] = k end
    table.sort(recipientKeys, function(a, b)
        return (RM.Aggregate:FormatCharLabel(a) or a) < (RM.Aggregate:FormatCharLabel(b) or b)
    end)

    for _, recipientKey in ipairs(recipientKeys) do
        local entries = byRecipient[recipientKey]
        local displayName = RM.Aggregate:FormatCharLabel(recipientKey) or recipientKey
        local explicit = self._bindingsCollapsed[recipientKey]
        local collapsedState
        if explicit == nil then
            -- Current character expands by default; everyone else collapses.
            collapsedState = (recipientKey ~= myKey)
        else
            collapsedState = explicit and true or false
        end
        local marker = collapsedState and "[+] " or "[-] "
        local headerText = marker .. displayName .. " (" .. #entries .. " bound)"

        local capturedRecipient = recipientKey
        last = AddExpanderWithActionRow(self, headerText, last, 0, "|cCCCC99",
            function()
                self._bindingsCollapsed[capturedRecipient] = not collapsedState
                self:RefreshWindow()
            end,
            GetString(SI_RM_WINDOW_CLEAR_BINDINGS),
            function()
                local removed = 0
                if RM.db.craftedFor then
                    for k, v in pairs(RM.db.craftedFor) do
                        if type(v) == "table" and v.recipient == capturedRecipient then
                            RM.db.craftedFor[k] = nil
                            removed = removed + 1
                        end
                    end
                end
                RM:Announce(zo_strformat(GetString(SI_RM_WINDOW_BINDINGS_CLEARED),
                    removed, displayName))
                self:RefreshWindow()
            end)

        if not collapsedState then
            -- Most recent first so freshly-queued items rise to the top.
            table.sort(entries, function(a, b) return (a.when or 0) > (b.when or 0) end)
            for _, e in ipairs(entries) do
                local itemName
                -- zo_strformat resolves the ^n/^m/^p/^a gender/article markers
                -- that GetItemLinkName / GetSmithingResearchLineInfo return raw.
                if e.itemLink and e.itemLink ~= "" then
                    itemName = zo_strformat(SI_TOOLTIP_ITEM_NAME, e.itemLink)
                    if not itemName or itemName == "" then itemName = e.itemLink end
                end
                if not itemName and e.craftingType and e.lineIndex then
                    local raw = GetSmithingResearchLineInfo(e.craftingType, e.lineIndex)
                    if raw and raw ~= "" then
                        itemName = zo_strformat("<<t:1>>", raw)
                    end
                end
                if not itemName or itemName == "" then itemName = "?" end

                local traitName = "?"
                if e.craftingType and e.lineIndex and e.traitIndex then
                    local traitType = GetSmithingResearchLineTraitInfo(
                        e.craftingType, e.lineIndex, e.traitIndex)
                    if traitType then
                        traitName = GetString("SI_ITEMTRAITTYPE", traitType) or "?"
                    end
                end

                local text = string.format("%s | %s", itemName, traitName)
                local capturedUuid = e.uuidKey
                last = AddIndentedRowWithRemove(self, text, last, 16, function()
                    if RM.db.craftedFor and capturedUuid then
                        RM.db.craftedFor[capturedUuid] = nil
                    end
                    self:RefreshWindow()
                end)
            end
        end
    end
end

function UI:PrintRecommendations(maxResults)
    RM.Scanner:ScanResearchState()
    RM.Scanner:BuildInventoryIndex()
    local recs = RM.Optimizer:Recommend(maxResults or 5)
    if #recs == 0 then
        RM:Announce("No researchable items found in inventory.")
        return
    end
    RM:AnnounceHeader("Recommendations:")
    for i, r in ipairs(recs) do
        local traitName = GetString("SI_ITEMTRAITTYPE", r.traitType) or "?"
        local marker = r.canStartNow and "|c66FF66*|r " or "  "
        CHAT_SYSTEM:AddMessage(string.format("%s%d. %s / %s / %s — %s (%d in bag, line %d/%d)",
            marker, i, RM:GetCraftName(r.craftingType), r.lineName, traitName,
            r.durationText, r.itemCount, r.knownInLine, r.totalInLine))
    end
end
