-- ============================================================================
-- ReciPeek (v1.2.1)
-- Author: Dantigravity
-- Description: Tabbed reagent recipe inspector, custom quantity crafter, and
--              availability highlighter for Recipes and Crafting Orders.
-- ============================================================================

local ADDON_NAME = "ReciPeek"

SLASH_RECIPEEK1 = "/rp"
SLASH_RECIPEEK2 = "/recipeek"

-- Runtime state and caches
local itemToRecipeMap = {}
local recipeNameCache = {}
local lastScannedRecipeCount = 0

-- Active tabs in the ReciPeek window: { recipeID = number, name = string, icon = number, craftQty = number }
local openTabs = {}
local activeTabIndex = 1
local peekFrame = nil

-- Tracked UI frames for overlay cleanup on refresh
local decoratedSlots = {}
local decoratedOrderRows = {}

-- ============================================================================
-- UTILITY & DATA HELPERS
-- ============================================================================

-- Extracts a numeric itemID from an itemLink string or number
local function ExtractItemID(input)
    if type(input) == "number" then
        return input
    elseif type(input) == "string" then
        if C_Item and C_Item.GetItemInfoInstant then
            local id = C_Item.GetItemInfoInstant(input)
            if id then return id end
        end
        local idStr = string.match(input, "item:(%d+)")
        if idStr then return tonumber(idStr) end
    end
    return nil
end

-- Returns total count of an item across bags, reagent bag, character bank, and Warband bank
local function GetPlayerReagentCount(itemID)
    if not itemID then return 0 end
    if C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(itemID, true, false, true, true) or 0
    elseif GetItemCount then
        return GetItemCount(itemID, true) or 0
    end
    return 0
end

-- Indexes all recipes in the currently open profession by their crafted outputItemID
local function RebuildProfessionItemMap()
    wipe(itemToRecipeMap)
    wipe(recipeNameCache)
    lastScannedRecipeCount = 0

    if not C_TradeSkillUI or not C_TradeSkillUI.GetAllRecipeIDs then return end
    local allRecipes = C_TradeSkillUI.GetAllRecipeIDs()
    if not allRecipes then return end
    lastScannedRecipeCount = #allRecipes

    for _, recipeID in ipairs(allRecipes) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if info and info.name then
            recipeNameCache[recipeID] = {
                name = info.name,
                icon = info.icon or 134400,
                learned = info.learned,
            }
        end

        local schematic = C_TradeSkillUI.GetRecipeSchematic and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
        if schematic and schematic.outputItemID and schematic.outputItemID > 0 then
            local existing = itemToRecipeMap[schematic.outputItemID]
            if not existing or (info and info.learned) then
                itemToRecipeMap[schematic.outputItemID] = recipeID
            end
        end

        if C_TradeSkillUI.GetRecipeOutputItemData then
            local ok, outputData = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, {})
            if ok and outputData and outputData.itemID and outputData.itemID > 0 then
                if not itemToRecipeMap[outputData.itemID] then
                    itemToRecipeMap[outputData.itemID] = recipeID
                end
            end
        end

        if info and info.qualityItemIDs then
            for _, qItemID in ipairs(info.qualityItemIDs) do
                if qItemID and qItemID > 0 then
                    itemToRecipeMap[qItemID] = recipeID
                end
            end
        end
    end
end

-- Returns the SchematicForm used by the Crafting Orders tab (OrderView)
local function GetOrderSchematicForm()
    if not ProfessionsFrame or not ProfessionsFrame.OrdersPage then return nil end
    local orderView = ProfessionsFrame.OrdersPage.OrderView
    if orderView and orderView.OrderDetails and orderView.OrderDetails.SchematicForm then
        return orderView.OrderDetails.SchematicForm
    end
    return nil
end

-- Extracts the active recipeID from a Blizzard SchematicForm frame
local function GetRecipeIDFromForm(form)
    if not form then return nil end
    if form.GetRecipeInfo then
        local ok, info = pcall(form.GetRecipeInfo, form)
        if ok and info and info.recipeID then return info.recipeID end
    end
    if form.currentRecipeInfo and form.currentRecipeInfo.recipeID then
        return form.currentRecipeInfo.recipeID
    end
    if form.recipeSchematic and form.recipeSchematic.recipeID then
        return form.recipeSchematic.recipeID
    end
    return nil
end

-- Returns the recipeID currently displayed in either the Crafting Orders tab or the Recipes tab
local function GetCurrentDisplayedRecipeID()
    if not ProfessionsFrame or not ProfessionsFrame:IsShown() then return nil end

    -- 1. Crafting Orders tab (OrderView)
    local orderForm = GetOrderSchematicForm()
    if orderForm and orderForm:IsShown() then
        local orderRecipeID = GetRecipeIDFromForm(orderForm)
        if orderRecipeID then return orderRecipeID end

        local orderView = ProfessionsFrame.OrdersPage and ProfessionsFrame.OrdersPage.OrderView
        if orderView and orderView.order and orderView.order.spellID then
            return orderView.order.spellID
        end
    end

    -- 2. Main Recipes tab (CraftingPage)
    local craftForm = ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
    if craftForm and craftForm:IsShown() then
        local craftRecipeID = GetRecipeIDFromForm(craftForm)
        if craftRecipeID then return craftRecipeID end
    end

    -- 3. Fallback if tab visibility is mid-transition
    return GetRecipeIDFromForm(craftForm) or GetRecipeIDFromForm(orderForm)
end

-- Checks if an itemID is crafted by a recipe in the active profession
local function GetCraftableRecipeForItemID(itemID, allowSameAsMain)
    if not itemID then return nil end
    if not next(itemToRecipeMap) then
        RebuildProfessionItemMap()
    elseif C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
        local allRecipes = C_TradeSkillUI.GetAllRecipeIDs()
        if allRecipes and #allRecipes ~= lastScannedRecipeCount then
            RebuildProfessionItemMap()
        end
    end

    local targetRecipeID = itemToRecipeMap[itemID]
    if not targetRecipeID then return nil end
    if not allowSameAsMain then
        local currentRecipeID = GetCurrentDisplayedRecipeID()
        if targetRecipeID == currentRecipeID then return nil end
    end
    return targetRecipeID
end

-- Returns how many times a recipeID can be crafted using materials currently on hand
local function GetRecipeMaxCraftableCount(recipeID)
    if not recipeID then return 0, false end
    local rInfo = (C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)) or recipeNameCache[recipeID]
    local isLearned = not rInfo or (rInfo.learned ~= false)

    local schematic = C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    if not schematic or not schematic.reagentSlotSchematics then
        return 0, isLearned
    end

    local maxCraftable = 9999
    local foundRequiredSlot = false

    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        local isRequired = (slot.required ~= false) and (slot.reagentType == 1 or slot.reagentType == nil)
        if isRequired and slot.reagents and #slot.reagents > 0 and (slot.quantityRequired or 0) > 0 then
            foundRequiredSlot = true
            local requiredQty = slot.quantityRequired
            local totalOwned = 0
            for _, r in ipairs(slot.reagents) do
                if r.itemID then
                    totalOwned = totalOwned + GetPlayerReagentCount(r.itemID)
                end
            end
            local possibleForSlot = math.floor(totalOwned / requiredQty)
            if possibleForSlot < maxCraftable then
                maxCraftable = possibleForSlot
            end
        end
    end

    if not foundRequiredSlot or maxCraftable == 9999 then
        maxCraftable = 0
    end
    return maxCraftable, isLearned
end

-- ============================================================================
-- CRAFTING ORDERS LIST: COMBINED MATERIALS (PATRON + PLAYER) HIGHLIGHTER
-- ============================================================================

-- Builds a lookup table of reagents provided by the customer/patron for an order
local function ExtractCustomerProvidedMap(order)
    local byItemID = {}

    if not order or not order.reagents then
        return byItemID
    end

    for _, r in ipairs(order.reagents) do
        local isCustomer = true
        if Enum and Enum.CraftingOrderReagentSource and Enum.CraftingOrderReagentSource.Crafter and r.source ~= nil then
            if r.source == Enum.CraftingOrderReagentSource.Crafter then
                isCustomer = false
            end
        end

        if isCustomer then
            local rInfo = r.reagentInfo or r.reagent or r
            local nestedReagent = rInfo.reagent or r.reagent
            local itemID = (nestedReagent and nestedReagent.itemID) or rInfo.itemID or r.itemID
            local qty = rInfo.quantity or r.quantity or (nestedReagent and nestedReagent.quantity) or 0

            if itemID and itemID > 0 and qty > 0 then
                byItemID[itemID] = (byItemID[itemID] or 0) + qty
            end
        end
    end

    return byItemID
end

-- Returns true if the order's recipe is learned and 100% of required reagents are available (Patron + Player)
local function EvaluateOrderCombinedReadiness(order)
    if not order then return false end
    local recipeID = order.spellID or order.recipeID
    if not recipeID or recipeID <= 0 then return false end

    local rInfo = (C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)) or recipeNameCache[recipeID]
    if not rInfo or rInfo.learned == false then
        return false
    end

    local schematic = C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    if not schematic or not schematic.reagentSlotSchematics then
        return false
    end

    local customerByItemID = ExtractCustomerProvidedMap(order)

    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        local isRequired = (slot.required ~= false) and (slot.reagentType == 1 or slot.reagentType == nil)
        if isRequired and slot.reagents and #slot.reagents > 0 and (slot.quantityRequired or 0) > 0 then
            local stillNeeded = slot.quantityRequired

            -- 1. Subtract reagents provided by the patron/customer
            for _, r in ipairs(slot.reagents) do
                local id = r.itemID
                if id and (customerByItemID[id] or 0) > 0 and stillNeeded > 0 then
                    local useCustomerQty = math.min(stillNeeded, customerByItemID[id])
                    customerByItemID[id] = customerByItemID[id] - useCustomerQty
                    stillNeeded = stillNeeded - useCustomerQty
                end
            end

            -- 2. Subtract remaining required reagents from the player's bags/bank
            if stillNeeded > 0 then
                for _, r in ipairs(slot.reagents) do
                    local id = r and r.itemID
                    if id and stillNeeded > 0 then
                        local playerOwned = GetPlayerReagentCount(id)
                        if playerOwned > 0 then
                            local usePlayerQty = math.min(stillNeeded, playerOwned)
                            stillNeeded = stillNeeded - usePlayerQty
                        end
                    end
                end
            end

            if stillNeeded > 0 then
                return false
            end
        end
    end

    return true
end

-- Creates or retrieves the green row highlight overlay for a Crafting Order list row
local function EnsureOrderRowHighlight(row)
    if row.reciPeekOrderHighlight then return row.reciPeekOrderHighlight end

    local hl = CreateFrame("Frame", nil, row, "BackdropTemplate")
    hl:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
    hl:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
    hl:SetFrameLevel(math.max(1, row:GetFrameLevel()))
    hl:EnableMouse(false)

    -- Row background fill (RGBA: emerald green at 20% opacity)
    local bg = hl:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.58, 0.22, 0.20)
    hl.bg = bg

    -- Left-edge accent bar (width: 3px)
    local leftBar = hl:CreateTexture(nil, "OVERLAY")
    leftBar:SetPoint("TOPLEFT", hl, "TOPLEFT", 0, 0)
    leftBar:SetPoint("BOTTOMLEFT", hl, "BOTTOMLEFT", 0, 0)
    leftBar:SetWidth(3)
    leftBar:SetColorTexture(0.10, 1.00, 0.38, 0.95)
    hl.leftBar = leftBar

    -- Row outline border
    hl:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    hl:SetBackdropBorderColor(0.15, 0.90, 0.40, 0.50)

    row.reciPeekOrderHighlight = hl
    return hl
end

-- Extracts the CraftingOrderInfo table from a ScrollBox order row
local function GetOrderInfoFromRow(row)
    if not row then return nil end
    if type(row.option) == "table" and (row.option.spellID or row.option.orderID) then
        return row.option
    end
    if type(row.order) == "table" and (row.order.spellID or row.order.orderID) then
        return row.order
    end
    if row.GetElementData then
        local ok, elem = pcall(row.GetElementData, row)
        if ok and type(elem) == "table" then
            if type(elem.option) == "table" and (elem.option.spellID or elem.option.orderID) then
                return elem.option
            end
            if type(elem.order) == "table" and (elem.order.spellID or elem.order.orderID) then
                return elem.order
            end
            if elem.spellID or elem.orderID then
                return elem
            end
        end
    end
    return nil
end

-- Updates the highlight state for a single Crafting Order row
local function UpdateSingleOrderRowHighlight(row)
    if not row or not row:IsShown() then
        if row and row.reciPeekOrderHighlight then
            row.reciPeekOrderHighlight:Hide()
        end
        return
    end

    local order = GetOrderInfoFromRow(row)
    if not order then
        if row.reciPeekOrderHighlight then
            row.reciPeekOrderHighlight:Hide()
        end
        return
    end

    if EvaluateOrderCombinedReadiness(order) then
        local hl = EnsureOrderRowHighlight(row)
        decoratedOrderRows[row] = true
        hl:Show()
    elseif row.reciPeekOrderHighlight then
        row.reciPeekOrderHighlight:Hide()
    end
end

-- Refreshes highlights across all visible rows in the Crafting Orders BrowseFrame ScrollBox
local function UpdateCraftingOrderBrowseListHighlights()
    if not ProfessionsFrame or not ProfessionsFrame:IsShown() or not ProfessionsFrame.OrdersPage then
        return
    end

    local browseFrame = ProfessionsFrame.OrdersPage.BrowseFrame
    local orderList = browseFrame and browseFrame.OrderList
    local scrollBox = orderList and orderList.ScrollBox

    if not scrollBox or not scrollBox:IsShown() then
        for row in pairs(decoratedOrderRows) do
            if row.reciPeekOrderHighlight then
                row.reciPeekOrderHighlight:Hide()
            end
        end
        return
    end

    if not next(itemToRecipeMap) then
        RebuildProfessionItemMap()
    end

    if scrollBox.GetFrames then
        local frames = scrollBox:GetFrames()
        if frames then
            for _, row in ipairs(frames) do
                UpdateSingleOrderRowHighlight(row)
            end
        end
    elseif scrollBox.ForEachFrame then
        scrollBox:ForEachFrame(function(row)
            UpdateSingleOrderRowHighlight(row)
        end)
    end
end

-- ============================================================================
-- RECIPE NAVIGATION & REAGENT BREAKDOWN
-- ============================================================================

-- Opens targetRecipeID in the main Professions window (switches to Recipes tab if on Crafting Orders)
local function JumpMainWindowToRecipe(targetRecipeID)
    if not targetRecipeID then return end

    if ProfessionsFrame and ProfessionsFrame:IsShown() then
        if ProfessionsFrame.CraftingPage and not ProfessionsFrame.CraftingPage:IsShown() then
            if ProfessionsFrame.SetTab and ProfessionsFrame.recipesTabID then
                pcall(ProfessionsFrame.SetTab, ProfessionsFrame, ProfessionsFrame.recipesTabID)
            end
        end
    end

    if C_TradeSkillUI and C_TradeSkillUI.OpenRecipe then
        pcall(C_TradeSkillUI.OpenRecipe, targetRecipeID)
    end

    if ProfessionsFrame and ProfessionsFrame.CraftingPage then
        local page = ProfessionsFrame.CraftingPage
        local info = C_TradeSkillUI.GetRecipeInfo(targetRecipeID)
        if page.RecipeList and page.RecipeList.SelectRecipe and info then
            pcall(page.RecipeList.SelectRecipe, page.RecipeList, info, false)
        end

        local nowDisplayed = GetCurrentDisplayedRecipeID()
        if nowDisplayed ~= targetRecipeID and page.SchematicForm and page.SchematicForm.Init and info then
            pcall(page.SchematicForm.Init, page.SchematicForm, info)
        end
    end
end

-- Returns the full reagent list, maximum craftable count, and schematic for a recipeID
local function GetRecipeReagentBreakdown(recipeID)
    local reagentsList = {}
    local maxCraftable = 9999

    local schematic = C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    if not schematic or not schematic.reagentSlotSchematics then
        return reagentsList, 0, nil
    end

    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        -- Basic required reagents (ReagentType.Basic == 1, or required == true)
        local isRequired = (slot.required ~= false) and (slot.reagentType == 1 or slot.reagentType == nil)
        if isRequired and slot.reagents and #slot.reagents > 0 and (slot.quantityRequired or 0) > 0 then
            local requiredQty = slot.quantityRequired
            local totalOwned = 0
            local primaryItemID = slot.reagents[1].itemID

            -- Sum across all quality tiers for multi-rank reagents
            for _, r in ipairs(slot.reagents) do
                if r.itemID then
                    totalOwned = totalOwned + GetPlayerReagentCount(r.itemID)
                end
            end

            local itemName = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(primaryItemID)) or ("Item #" .. tostring(primaryItemID))
            local itemIcon = 134400
            if C_Item and C_Item.GetItemInfoInstant then
                local _, _, _, _, tex = C_Item.GetItemInfoInstant(primaryItemID)
                if tex then itemIcon = tex end
            end
            if C_Item and C_Item.RequestLoadItemDataByID then
                C_Item.RequestLoadItemDataByID(primaryItemID)
            end

            local possibleForSlot = math.floor(totalOwned / requiredQty)
            if possibleForSlot < maxCraftable then
                maxCraftable = possibleForSlot
            end

            local subRecipeID = GetCraftableRecipeForItemID(primaryItemID, true)
            if subRecipeID == recipeID then subRecipeID = nil end

            local subMaxCraftable, subIsLearned = 0, false
            if subRecipeID then
                subMaxCraftable, subIsLearned = GetRecipeMaxCraftableCount(subRecipeID)
            end

            table.insert(reagentsList, {
                itemID = primaryItemID,
                name = itemName,
                icon = itemIcon,
                required = requiredQty,
                owned = totalOwned,
                subRecipeID = subRecipeID,
                subMaxCraftable = subMaxCraftable,
                subIsLearned = subIsLearned,
                allReagents = slot.reagents,
            })
        end
    end

    if maxCraftable == 9999 then maxCraftable = 0 end
    return reagentsList, maxCraftable, schematic
end

-- Calculates how many crafts of subRecipeID are needed to cover missing reagents for parentRecipeID
local function GetSuggestedCraftQtyForReagent(parentRecipeID, clickedItemID, subRecipeID)
    if not parentRecipeID or not clickedItemID then return 1 end
    local reagents = GetRecipeReagentBreakdown(parentRecipeID)
    for _, rg in ipairs(reagents) do
        local matches = (rg.itemID == clickedItemID)
        if not matches and rg.allReagents then
            for _, r in ipairs(rg.allReagents) do
                if r.itemID == clickedItemID then
                    matches = true
                    break
                end
            end
        end
        if matches then
            local missingItems = rg.required - rg.owned
            if missingItems > 0 then
                local subSchem = subRecipeID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic and C_TradeSkillUI.GetRecipeSchematic(subRecipeID, false)
                local minYield = (subSchem and subSchem.quantityMin and subSchem.quantityMin > 0) and subSchem.quantityMin or 1
                return math.max(1, math.ceil(missingItems / minYield))
            end
            return 1
        end
    end
    return 1
end

-- ============================================================================
-- SCHEMATIC FORM REAGENT SLOT INDICATORS
-- ============================================================================

-- Creates or retrieves the indicator overlay frame on a Blizzard reagent slot
local function EnsureSlotIndicator(slot)
    if slot.reciPeekIndicator then return slot.reciPeekIndicator end
    local btn = slot.Button or slot

    local ind = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    ind:SetPoint("TOPLEFT", btn, "TOPLEFT", -2, 2)
    ind:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 2, -2)
    ind:SetFrameLevel(btn:GetFrameLevel() + 6)
    ind:EnableMouse(false)

    ind:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })

    -- Background row highlight extending across the reagent label
    local rowGlow = slot:CreateTexture(nil, "BACKGROUND")
    rowGlow:SetPoint("TOPLEFT", btn, "TOPLEFT", -2, 2)
    rowGlow:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -2, -2)
    rowGlow:SetWidth(185)
    rowGlow:SetColorTexture(0.05, 0.55, 0.22, 0.22)
    ind.rowGlow = rowGlow

    -- Status badge anchored to the bottom of the reagent icon ("Craft: X" or "Peek")
    local pill = CreateFrame("Frame", nil, ind, "BackdropTemplate")
    pill:SetHeight(14)
    pill:SetPoint("BOTTOM", btn, "BOTTOM", 0, -4)
    pill:SetFrameLevel(ind:GetFrameLevel() + 2)
    pill:EnableMouse(false)
    pill:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 7,
        insets = { left = 1, right = 1, top = 1, bottom = 1 }
    })
    pill:SetBackdropColor(0.04, 0.06, 0.09, 0.94)

    local label = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local fontPath = label:GetFont()
    if fontPath then
        label:SetFont(fontPath, 9, "OUTLINE")
    end
    label:SetPoint("CENTER", pill, "CENTER", 0, 0)
    pill.label = label
    ind.pill = pill

    slot.reciPeekIndicator = ind
    return ind
end

-- Extracts the primary reagent itemID from a Blizzard ProfessionsReagentSlotTemplate
local function GetPrimaryItemIDFromReagentSlot(slot)
    if not slot then return nil end
    if slot.GetReagentSlotSchematic then
        local ok, slotSchem = pcall(slot.GetReagentSlotSchematic, slot)
        if ok and slotSchem and slotSchem.reagents and slotSchem.reagents[1] then
            local id = slotSchem.reagents[1].itemID
            if id and id > 0 then return id end
        end
    end
    if slot.reagentSlotSchematic and slot.reagentSlotSchematic.reagents and slot.reagentSlotSchematic.reagents[1] then
        local id = slot.reagentSlotSchematic.reagents[1].itemID
        if id and id > 0 then return id end
    end
    if slot.Button then
        if slot.Button.GetItemID then
            local ok, id = pcall(slot.Button.GetItemID, slot.Button)
            if ok and type(id) == "number" and id > 0 then return id end
        end
        if slot.Button.itemID and type(slot.Button.itemID) == "number" and slot.Button.itemID > 0 then
            return slot.Button.itemID
        end
    end
    return nil
end

-- Applies visual indicators to craftable reagent slots in a SchematicForm
local function ApplyIndicatorsToSchematicForm(form)
    if not form or not form:IsShown() then return end

    local slotsToCheck = {}
    if form.reagentSlotPool and form.reagentSlotPool.EnumerateActive then
        for slot in form.reagentSlotPool:EnumerateActive() do
            table.insert(slotsToCheck, slot)
        end
    elseif form.Reagents and form.Reagents.GetChildren then
        local children = { form.Reagents:GetChildren() }
        for _, child in ipairs(children) do
            if child and child:IsShown() and (child.Button or child.GetReagentSlotSchematic) then
                table.insert(slotsToCheck, child)
            end
        end
    end

    for _, slot in ipairs(slotsToCheck) do
        local itemID = GetPrimaryItemIDFromReagentSlot(slot)
        local subRecipeID = itemID and GetCraftableRecipeForItemID(itemID, false) or nil

        if subRecipeID then
            local subMaxCraftable, isLearned = GetRecipeMaxCraftableCount(subRecipeID)
            local ind = EnsureSlotIndicator(slot)
            decoratedSlots[slot] = true

            if isLearned and subMaxCraftable > 0 then
                -- Materials on hand: green border, row highlight, and craftable count
                local countStr = (subMaxCraftable > 99) and "99+" or tostring(subMaxCraftable)
                ind:SetBackdropBorderColor(0.10, 1.00, 0.35, 1.0)
                ind.rowGlow:SetColorTexture(0.05, 0.55, 0.22, 0.24)
                ind.rowGlow:Show()

                ind.pill:SetBackdropBorderColor(0.15, 0.95, 0.40, 1.0)
                ind.pill.label:SetText("|cFF00FF66Craft: " .. countStr .. "|r")
                ind.pill:SetWidth(math.max(42, ind.pill.label:GetStringWidth() + 10))
                ind.pill:Show()
                ind:Show()
            else
                -- Craftable by profession, but missing raw materials (or unlearned): cyan "Peek" tag
                ind:SetBackdropBorderColor(0.20, 0.75, 1.00, 0.65)
                ind.rowGlow:Hide()

                ind.pill:SetBackdropBorderColor(0.25, 0.70, 0.95, 0.85)
                ind.pill.label:SetText("|cFF00CCFFPeek|r")
                ind.pill:SetWidth(math.max(34, ind.pill.label:GetStringWidth() + 10))
                ind.pill:Show()
                ind:Show()
            end
        elseif slot.reciPeekIndicator then
            slot.reciPeekIndicator.rowGlow:Hide()
            slot.reciPeekIndicator:Hide()
        end
    end
end

-- Updates reagent slot indicators on the active SchematicForm (Recipes or Crafting Orders)
local function UpdateMainSchematicFormIndicators()
    for slot in pairs(decoratedSlots) do
        if slot.reciPeekIndicator then
            slot.reciPeekIndicator.rowGlow:Hide()
            slot.reciPeekIndicator:Hide()
        end
    end
    wipe(decoratedSlots)

    if not ProfessionsFrame or not ProfessionsFrame:IsShown() then return end

    local craftForm = ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
    if craftForm and craftForm:IsShown() then
        ApplyIndicatorsToSchematicForm(craftForm)
    end

    local orderForm = GetOrderSchematicForm()
    if orderForm and orderForm:IsShown() then
        ApplyIndicatorsToSchematicForm(orderForm)
    end
end

-- ============================================================================
-- RECIPEEK TABBED SIDE WINDOW
-- ============================================================================

local RefreshPeekWindow

-- Opens or focuses a recipe tab in the ReciPeek side window
local function OpenRecipeInPeekTab(recipeID, suggestedQty)
    if not recipeID then return end
    local defaultQty = (suggestedQty and suggestedQty > 0) and suggestedQty or 1

    for idx, tab in ipairs(openTabs) do
        if tab.recipeID == recipeID then
            activeTabIndex = idx
            if suggestedQty and suggestedQty > 0 then
                tab.craftQty = suggestedQty
            end
            RefreshPeekWindow()
            return
        end
    end

    local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
    local rName = (info and info.name) or (recipeNameCache[recipeID] and recipeNameCache[recipeID].name) or ("Recipe #" .. recipeID)
    local rIcon = (info and info.icon) or (recipeNameCache[recipeID] and recipeNameCache[recipeID].icon) or 134400

    table.insert(openTabs, {
        recipeID = recipeID,
        name = rName,
        icon = rIcon,
        craftQty = defaultQty,
    })
    activeTabIndex = #openTabs
    RefreshPeekWindow()
end

-- Builds (on first call) and refreshes the ReciPeek side panel UI
RefreshPeekWindow = function()
    if not ProfessionsFrame or not ProfessionsFrame:IsShown() then
        if peekFrame then peekFrame:Hide() end
        return
    end

    if not peekFrame then
        -- Main side panel frame (width: 336, height: 444)
        local f = CreateFrame("Frame", "ReciPeekSideFrame", ProfessionsFrame, "BackdropTemplate")
        f:SetSize(336, 444)
        f:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 6, 0)
        f:SetFrameStrata("HIGH")
        f:EnableMouse(true)
        f:SetMovable(true)
        f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)

        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false,
            edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 }
        })
        f:SetBackdropColor(0.06, 0.07, 0.10, 0.96)
        f:SetBackdropBorderColor(0.25, 0.65, 0.90, 0.95)

        -- Window Title
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
        title:SetText("|cFF00CCFFReci|r|cFFFFD100Peek|r  |cFF888888• Recipe Inspector|r")

        -- "+ Pin Main" Button (pins the active recipe from Recipes or Crafting Orders)
        local pinBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        pinBtn:SetSize(82, 20)
        pinBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -32, -7)
        pinBtn:SetText("+ Pin Main")
        pinBtn:SetScript("OnClick", function()
            local curID = GetCurrentDisplayedRecipeID()
            if curID then OpenRecipeInPeekTab(curID, 1) end
        end)

        -- Close Button
        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        -- Tab Bar Container
        local tabBar = CreateFrame("Frame", nil, f)
        tabBar:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -32)
        tabBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -32)
        tabBar:SetHeight(50)
        f.tabBar = tabBar
        f.tabButtons = {}

        -- Horizontal Divider
        local div = f:CreateTexture(nil, "ARTWORK")
        div:SetHeight(1)
        div:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -2)
        div:SetPoint("TOPRIGHT", tabBar, "BOTTOMRIGHT", 0, -2)
        div:SetColorTexture(0.25, 0.55, 0.80, 0.6)

        -- Active Recipe Header
        local rIcon = f:CreateTexture(nil, "ARTWORK")
        rIcon:SetSize(40, 40)
        rIcon:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 6, -10)
        f.rIcon = rIcon

        local rTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        rTitle:SetPoint("TOPLEFT", rIcon, "TOPRIGHT", 10, -1)
        rTitle:SetPoint("RIGHT", f, "RIGHT", -12, 0)
        rTitle:SetJustifyH("LEFT")
        rTitle:SetWordWrap(false)
        f.rTitle = rTitle

        -- "Open Recipe ->" Navigation Button (positioned below the recipe title)
        local jumpBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        jumpBtn:SetSize(106, 20)
        jumpBtn:SetPoint("TOPLEFT", rTitle, "BOTTOMLEFT", 0, -4)
        jumpBtn:SetText("Open Recipe ->")
        f.jumpBtn = jumpBtn

        -- Inventory & Craftable Status Line
        local rStatus = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rStatus:SetPoint("TOPLEFT", rIcon, "BOTTOMLEFT", 0, -8)
        rStatus:SetPoint("RIGHT", f, "RIGHT", -12, 0)
        rStatus:SetJustifyH("LEFT")
        f.rStatus = rStatus

        -- Reagents List Subheader
        local reagHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        reagHeader:SetPoint("TOPLEFT", rStatus, "BOTTOMLEFT", 0, -8)
        reagHeader:SetText("|cFFFFD100Required Materials (Click craftable rows to peek deeper):|r")

        f.reagentRows = {}

        -- Bottom Crafting Controls: [Craft] [<] [Qty] [>]   [Craft All [X]]
        local craftBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        craftBtn:SetSize(68, 24)
        craftBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
        craftBtn:SetText("Craft")
        f.craftBtn = craftBtn

        -- Quantity Decrement Arrow [<]
        local decBtn = CreateFrame("Button", nil, f)
        decBtn:SetSize(22, 22)
        decBtn:SetPoint("LEFT", craftBtn, "RIGHT", 4, 0)
        decBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
        decBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down")
        decBtn:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Disabled")
        decBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        f.decBtn = decBtn

        -- Custom Quantity Input Box
        local qtyBox = CreateFrame("EditBox", "ReciPeekQtyBox", f, "BackdropTemplate")
        qtyBox:SetSize(42, 22)
        qtyBox:SetPoint("LEFT", decBtn, "RIGHT", 2, 0)
        qtyBox:SetFontObject("GameFontHighlightSmall")
        qtyBox:SetJustifyH("CENTER")
        qtyBox:SetAutoFocus(false)
        qtyBox:SetNumeric(true)
        qtyBox:SetMaxLetters(4)
        qtyBox:SetTextInsets(2, 2, 0, 0)
        qtyBox:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false,
            edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        qtyBox:SetBackdropColor(0.03, 0.04, 0.06, 0.95)
        qtyBox:SetBackdropBorderColor(0.35, 0.70, 0.95, 0.90)
        f.qtyBox = qtyBox

        -- Quantity Increment Arrow [>]
        local incBtn = CreateFrame("Button", nil, f)
        incBtn:SetSize(22, 22)
        incBtn:SetPoint("LEFT", qtyBox, "RIGHT", 2, 0)
        incBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
        incBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
        incBtn:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Disabled")
        incBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        f.incBtn = incBtn

        local craftAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        craftAllBtn:SetSize(116, 24)
        craftAllBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
        craftAllBtn:SetText("Craft All")
        f.craftAllBtn = craftAllBtn

        peekFrame = f
    end

    if #openTabs == 0 then
        peekFrame:Hide()
        return
    end

    if activeTabIndex > #openTabs then activeTabIndex = #openTabs end
    if activeTabIndex < 1 then activeTabIndex = 1 end

    peekFrame:Show()

    -- 1. Render Tab Buttons (wraps up to 2 rows)
    for _, b in ipairs(peekFrame.tabButtons) do b:Hide() end

    local xOff = 0
    local yOff = 0
    local maxRowWidth = 316

    for idx, tab in ipairs(openTabs) do
        local btn = peekFrame.tabButtons[idx]
        if not btn then
            btn = CreateFrame("Button", nil, peekFrame.tabBar, "BackdropTemplate")
            btn:SetHeight(22)
            btn:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = false,
                edgeSize = 8,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })
            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.label:SetPoint("LEFT", btn, "LEFT", 6, 0)

            -- Individual tab close button ("x")
            btn.closeTab = CreateFrame("Button", nil, btn)
            btn.closeTab:SetSize(14, 14)
            btn.closeTab:SetPoint("RIGHT", btn, "RIGHT", -3, 0)
            btn.closeTab.txt = btn.closeTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.closeTab.txt:SetPoint("CENTER")
            btn.closeTab.txt:SetText("|cFF888888x|r")

            peekFrame.tabButtons[idx] = btn
        end

        local isSelected = (idx == activeTabIndex)
        local shortName = tab.name or "Recipe"
        if string.len(shortName) > 14 then
            shortName = string.sub(shortName, 1, 13) .. ".."
        end

        btn.label:SetText(string.format("|T%d:13:13:0:0|t %s", tab.icon or 134400, shortName))
        local btnWidth = math.min(152, btn.label:GetStringWidth() + 26)
        btn:SetWidth(btnWidth)

        if xOff + btnWidth > maxRowWidth and xOff > 0 then
            xOff = 0
            yOff = yOff - 24
        end

        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", peekFrame.tabBar, "TOPLEFT", xOff, yOff)
        xOff = xOff + btnWidth + 4

        if isSelected then
            btn:SetBackdropColor(0.14, 0.30, 0.46, 1.0)
            btn:SetBackdropBorderColor(0.40, 0.85, 1.0, 1.0)
            btn.label:SetTextColor(1, 0.85, 0)
        else
            btn:SetBackdropColor(0.09, 0.10, 0.14, 0.9)
            btn:SetBackdropBorderColor(0.28, 0.30, 0.38, 0.8)
            btn.label:SetTextColor(0.75, 0.75, 0.75)
        end

        btn:SetScript("OnClick", function()
            if peekFrame.qtyBox then peekFrame.qtyBox:ClearFocus() end
            activeTabIndex = idx
            RefreshPeekWindow()
        end)

        btn.closeTab:SetScript("OnClick", function()
            if peekFrame.qtyBox then peekFrame.qtyBox:ClearFocus() end
            table.remove(openTabs, idx)
            if activeTabIndex >= idx and activeTabIndex > 1 then
                activeTabIndex = activeTabIndex - 1
            end
            RefreshPeekWindow()
        end)

        btn:Show()
    end

    -- 2. Render Active Tab Recipe Details & Reagent List
    local activeTab = openTabs[activeTabIndex]
    if not activeTab then return end

    local recipeID = activeTab.recipeID
    local rInfo = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
    local reagents, maxCraftable, schematic = GetRecipeReagentBreakdown(recipeID)

    peekFrame.rIcon:SetTexture((rInfo and rInfo.icon) or activeTab.icon or 134400)
    peekFrame.rTitle:SetText((rInfo and rInfo.name) or activeTab.name or "Recipe")

    local outItemID = schematic and schematic.outputItemID
    local ownedOutput = outItemID and GetPlayerReagentCount(outItemID) or 0
    local learnedStatus = (rInfo and rInfo.learned == false) and "|cFFFF4444(Unlearned)|r  •  " or ""
    local craftableColor = (maxCraftable > 0) and "|cFF00FF66" or "|cFFFF6666"
    peekFrame.rStatus:SetText(string.format("%sIn Bags: |cFFFFFFFF%d|r  •  Can Craft: %s%d|r", learnedStatus, ownedOutput, craftableColor, maxCraftable))

    peekFrame.jumpBtn:SetScript("OnClick", function()
        if peekFrame.qtyBox then peekFrame.qtyBox:ClearFocus() end
        JumpMainWindowToRecipe(recipeID)
    end)

    for _, row in ipairs(peekFrame.reagentRows) do row:Hide() end

    local rowStartY = -180
    for i, rg in ipairs(reagents) do
        local row = peekFrame.reagentRows[i]
        if not row then
            row = CreateFrame("Button", nil, peekFrame, "BackdropTemplate")
            row:SetHeight(28)
            row:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(22, 22)
            row.icon:SetPoint("LEFT", row, "LEFT", 6, 0)

            row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
            row.nameText:SetPoint("RIGHT", row, "RIGHT", -68, 0)
            row.nameText:SetJustifyH("LEFT")
            row.nameText:SetWordWrap(false)

            row.countText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.countText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
            row.countText:SetJustifyH("RIGHT")

            row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
            row.highlight:SetAllPoints()
            row.highlight:SetColorTexture(0.2, 0.7, 1.0, 0.18)

            peekFrame.reagentRows[i] = row
        end

        row:SetPoint("TOPLEFT", peekFrame, "TOPLEFT", 12, rowStartY - ((i - 1) * 30))
        row:SetPoint("TOPRIGHT", peekFrame, "TOPRIGHT", -12, rowStartY - ((i - 1) * 30))

        local hasEnough = (rg.owned >= rg.required)
        row.icon:SetTexture(rg.icon)

        local subBadge = ""
        if rg.subRecipeID then
            if rg.subIsLearned and (rg.subMaxCraftable or 0) > 0 then
                subBadge = string.format(" |cFF00FF66[Craft: %d ->]|r", rg.subMaxCraftable)
                row:SetBackdropColor(0.08, 0.22, 0.14, 0.90)
                row:SetBackdropBorderColor(0.15, 0.85, 0.35, 0.90)
            else
                subBadge = " |cFF00CCFF[Peek ->]|r"
                row:SetBackdropColor(0.11, 0.13, 0.18, 0.85)
                row:SetBackdropBorderColor(0.22, 0.50, 0.75, 0.65)
            end
        else
            row:SetBackdropColor(0.11, 0.13, 0.18, 0.85)
            row:SetBackdropBorderColor(0.20, 0.22, 0.28, 0.50)
        end

        row.nameText:SetText(rg.name .. subBadge)

        local countColor = hasEnough and "|cFF00FF66" or "|cFFFF5555"
        row.countText:SetText(string.format("%s%d / %d|r", countColor, rg.owned, rg.required))

        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if rg.itemID then
                GameTooltip:SetItemByID(rg.itemID)
                if rg.subRecipeID then
                    GameTooltip:AddLine(" ")
                    if rg.subIsLearned and (rg.subMaxCraftable or 0) > 0 then
                        GameTooltip:AddLine(string.format("|cFF00FF66Ready to Craft: Materials on hand for %d|r", rg.subMaxCraftable))
                    else
                        GameTooltip:AddLine("|cFFFF6666Missing raw materials to craft right now|r")
                    end
                    GameTooltip:AddLine("|cFF00FF66<Left-Click to Peek Recipe in New Tab>|r")
                    GameTooltip:AddLine("|cFF00CCFF<Ctrl + Left-Click to Open Full Recipe Page>|r")
                end
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row:SetScript("OnClick", function()
            if IsShiftKeyDown() and rg.itemID then
                local _, itemLink = C_Item.GetItemInfo(rg.itemID)
                if itemLink and ChatEdit_InsertLink then ChatEdit_InsertLink(itemLink) end
                return
            end
            if rg.subRecipeID then
                if IsControlKeyDown() then
                    JumpMainWindowToRecipe(rg.subRecipeID)
                else
                    local suggested = GetSuggestedCraftQtyForReagent(recipeID, rg.itemID, rg.subRecipeID)
                    OpenRecipeInPeekTab(rg.subRecipeID, suggested)
                end
            end
        end)

        row:Show()
    end

    -- 3. Configure Bottom Crafting Controls ([Craft] [<] [Qty] [>]   [Craft All [X]])
    local canCraftNow = (maxCraftable > 0) and (not rInfo or rInfo.learned ~= false)
    local maxAllowedQty = (maxCraftable > 0) and maxCraftable or 999
    local currentQty = math.max(1, math.min(activeTab.craftQty or 1, maxAllowedQty))
    activeTab.craftQty = currentQty

    if not peekFrame.qtyBox:HasFocus() then
        peekFrame.qtyBox:SetText(tostring(currentQty))
    end

    local function UpdateArrowStates(val)
        if val <= 1 then
            peekFrame.decBtn:Disable()
        else
            peekFrame.decBtn:Enable()
        end
        if val >= maxAllowedQty then
            peekFrame.incBtn:Disable()
        else
            peekFrame.incBtn:Enable()
        end
    end

    local function SetCustomQuantity(newVal)
        local clamped = math.max(1, math.min(maxAllowedQty, tonumber(newVal) or 1))
        activeTab.craftQty = clamped
        peekFrame.qtyBox:SetText(tostring(clamped))
        UpdateArrowStates(clamped)
    end

    UpdateArrowStates(currentQty)

    peekFrame.decBtn:SetScript("OnClick", function()
        peekFrame.qtyBox:ClearFocus()
        local cur = tonumber(peekFrame.qtyBox:GetText()) or activeTab.craftQty or 1
        SetCustomQuantity(cur - 1)
    end)

    peekFrame.incBtn:SetScript("OnClick", function()
        peekFrame.qtyBox:ClearFocus()
        local cur = tonumber(peekFrame.qtyBox:GetText()) or activeTab.craftQty or 1
        SetCustomQuantity(cur + 1)
    end)

    peekFrame.qtyBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    peekFrame.qtyBox:SetScript("OnEditFocusGained", function(self)
        self:HighlightText()
        self:SetBackdropBorderColor(1.0, 0.82, 0.0, 1.0)
    end)
    peekFrame.qtyBox:SetScript("OnEditFocusLost", function(self)
        self:HighlightText(0, 0)
        self:SetBackdropBorderColor(0.35, 0.70, 0.95, 0.90)
        SetCustomQuantity(self:GetText())
    end)
    peekFrame.qtyBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            local val = tonumber(self:GetText())
            if val and val >= 1 then
                local clamped = math.min(maxAllowedQty, val)
                activeTab.craftQty = clamped
                UpdateArrowStates(clamped)
            end
        end
    end)
    peekFrame.qtyBox:EnableMouseWheel(true)
    peekFrame.qtyBox:SetScript("OnMouseWheel", function(self, delta)
        local cur = tonumber(self:GetText()) or activeTab.craftQty or 1
        SetCustomQuantity(cur + (delta > 0 and 1 or -1))
    end)
    peekFrame.qtyBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Custom Craft Quantity", 1, 0.82, 0)
        GameTooltip:AddLine("Use the arrow buttons, type an amount, or scroll the mousewheel.", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Press |cFF00FF66Enter|r or click |cFF00FF66Craft|r to begin.", 0.75, 0.75, 0.75)
        GameTooltip:Show()
    end)
    peekFrame.qtyBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local function ExecuteCustomQtyCraft()
        peekFrame.qtyBox:ClearFocus()
        if not canCraftNow then return end
        local requested = tonumber(peekFrame.qtyBox:GetText()) or activeTab.craftQty or 1
        local countToCraft = math.max(1, math.min(requested, maxCraftable))
        SetCustomQuantity(countToCraft)
        if C_TradeSkillUI and C_TradeSkillUI.CraftRecipe then
            C_TradeSkillUI.CraftRecipe(recipeID, countToCraft)
        end
    end

    if canCraftNow then
        peekFrame.craftBtn:Enable()
        peekFrame.craftAllBtn:Enable()
        peekFrame.craftAllBtn:SetText("Craft All [" .. maxCraftable .. "]")
    else
        peekFrame.craftBtn:Disable()
        peekFrame.craftAllBtn:Disable()
        peekFrame.craftAllBtn:SetText("Craft All [0]")
    end

    peekFrame.craftBtn:SetScript("OnClick", ExecuteCustomQtyCraft)
    peekFrame.qtyBox:SetScript("OnEnterPressed", ExecuteCustomQtyCraft)

    peekFrame.craftAllBtn:SetScript("OnClick", function()
        peekFrame.qtyBox:ClearFocus()
        if maxCraftable > 0 and C_TradeSkillUI and C_TradeSkillUI.CraftRecipe then
            C_TradeSkillUI.CraftRecipe(recipeID, maxCraftable)
        end
    end)
end

-- ============================================================================
-- FRAME INSPECTION, HOOKS & EVENTS
-- ============================================================================

-- Extracts a reagent itemID from a hovered or clicked UI frame inside SchematicForm
local function ExtractReagentItemIDFromFrame(frame)
    local cur = frame
    local depth = 0
    while cur and depth < 8 do
        if cur.GetItemID then
            local ok, id = pcall(cur.GetItemID, cur)
            if ok and type(id) == "number" and id > 0 then return id end
        end
        if cur.itemID and type(cur.itemID) == "number" and cur.itemID > 0 then
            return cur.itemID
        end
        if cur.GetItemLink then
            local ok, link = pcall(cur.GetItemLink, cur)
            if ok and link then
                local id = ExtractItemID(link)
                if id then return id end
            end
        end
        if cur.GetReagentSlotSchematic then
            local ok, slotSchem = pcall(cur.GetReagentSlotSchematic, cur)
            if ok and slotSchem and slotSchem.reagents and slotSchem.reagents[1] then
                local r = slotSchem.reagents[1]
                if r.itemID and r.itemID > 0 then return r.itemID end
            end
        end
        if cur.reagentSlotSchematic and cur.reagentSlotSchematic.reagents and cur.reagentSlotSchematic.reagents[1] then
            local r = cur.reagentSlotSchematic.reagents[1]
            if r.itemID and r.itemID > 0 then return r.itemID end
        end

        cur = cur.GetParent and cur:GetParent() or nil
        depth = depth + 1
    end

    if GameTooltip and GameTooltip:IsShown() then
        if GameTooltip.GetPrimaryTooltipData then
            local data = GameTooltip:GetPrimaryTooltipData()
            if data and data.id then return data.id end
        end
        if TooltipUtil and TooltipUtil.GetDisplayedItem then
            local _, link, id = TooltipUtil.GetDisplayedItem(GameTooltip)
            if id then return id end
            if link then return ExtractItemID(link) end
        end
    end
    return nil
end

-- Returns true if the given frame is inside either the Recipes or Crafting Orders SchematicForm
local function IsInsideSchematicForm(frame)
    if not ProfessionsFrame or not ProfessionsFrame:IsShown() then return false end

    local craftForm = ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
    local orderForm = GetOrderSchematicForm()
    local orderView = ProfessionsFrame.OrdersPage and ProfessionsFrame.OrdersPage.OrderView

    local cur = frame
    while cur do
        -- Ignore clicks inside the ReciPeek side window
        if peekFrame and cur == peekFrame then
            return false
        end
        -- Main Recipes tab SchematicForm
        if craftForm and craftForm:IsShown() and cur == craftForm then
            return true
        end
        -- Crafting Orders tab SchematicForm
        if orderForm and orderForm:IsShown() and cur == orderForm then
            return true
        end
        if orderView and orderView:IsShown() and cur == orderView.OrderDetails then
            return true
        end
        cur = cur.GetParent and cur:GetParent() or nil
    end
    return false
end

-- Hooks ProfessionsFrame, SchematicForms, and the Crafting Orders ScrollBox
local isProfessionsHooked = false
local isCraftFormHooked = false
local isOrderFormHooked = false
local isOrderListHooked = false

local function TryHookProfessionsFrame()
    if not ProfessionsFrame then return end

    if not isProfessionsHooked then
        isProfessionsHooked = true

        ProfessionsFrame:HookScript("OnShow", function()
            C_Timer.After(0.1, function()
                RebuildProfessionItemMap()
                UpdateMainSchematicFormIndicators()
                UpdateCraftingOrderBrowseListHighlights()
                if #openTabs > 0 then RefreshPeekWindow() end
            end)
        end)

        ProfessionsFrame:HookScript("OnHide", function()
            if peekFrame then peekFrame:Hide() end
        end)
    end

    local craftForm = ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
    if craftForm and not isCraftFormHooked and craftForm.Init then
        isCraftFormHooked = true
        hooksecurefunc(craftForm, "Init", function()
            C_Timer.After(0.02, UpdateMainSchematicFormIndicators)
        end)
    end

    local orderForm = GetOrderSchematicForm()
    if orderForm and not isOrderFormHooked and orderForm.Init then
        isOrderFormHooked = true
        hooksecurefunc(orderForm, "Init", function()
            C_Timer.After(0.02, UpdateMainSchematicFormIndicators)
        end)
    end

    local browseFrame = ProfessionsFrame.OrdersPage and ProfessionsFrame.OrdersPage.BrowseFrame
    local orderList = browseFrame and browseFrame.OrderList
    local scrollBox = orderList and orderList.ScrollBox

    if scrollBox and not isOrderListHooked then
        isOrderListHooked = true

        if ScrollUtil and ScrollUtil.AddInitializedFrameCallback then
            ScrollUtil.AddInitializedFrameCallback(scrollBox, function(row)
                UpdateSingleOrderRowHighlight(row)
            end, nil, true)
        end

        if scrollBox.Update then
            hooksecurefunc(scrollBox, "Update", function()
                UpdateCraftingOrderBrowseListHighlights()
            end)
        end
    end
end

-- Main Event Dispatcher
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("CRAFTINGORDERS_CAN_REQUEST")
eventFrame:RegisterEvent("CRAFTINGORDERS_ORDER_PLACEMENT_RESPONSE")
eventFrame:RegisterEvent("GLOBAL_MOUSE_DOWN")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            print("|cFF00CCFFReci|r|cFFFFD100Peek|r v1.2.0 loaded! Craftable reagents and Crafting Orders with combined materials on hand are highlighted in green.")
        elseif arg1 == "Blizzard_Professions" then
            TryHookProfessionsFrame()
        end
    elseif event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
        TryHookProfessionsFrame()
        RebuildProfessionItemMap()
        UpdateMainSchematicFormIndicators()
        UpdateCraftingOrderBrowseListHighlights()
        if peekFrame and peekFrame:IsShown() then RefreshPeekWindow() end
    elseif event == "BAG_UPDATE_DELAYED" or event == "CRAFTINGORDERS_CAN_REQUEST" or event == "CRAFTINGORDERS_ORDER_PLACEMENT_RESPONSE" then
        if ProfessionsFrame and ProfessionsFrame:IsShown() then
            TryHookProfessionsFrame()
            UpdateMainSchematicFormIndicators()
            UpdateCraftingOrderBrowseListHighlights()
        end
        if peekFrame and peekFrame:IsShown() then
            RefreshPeekWindow()
        end
    elseif event == "GLOBAL_MOUSE_DOWN" then
        if arg1 ~= "LeftButton" then return end
        if IsShiftKeyDown() then return end -- Preserve Shift + Left-Click for chat item linking
        if not ProfessionsFrame or not ProfessionsFrame:IsShown() then return end

        local focus = GetMouseFoci and GetMouseFoci()[1] or (GetMouseFocus and GetMouseFocus())
        if not focus or not IsInsideSchematicForm(focus) then return end

        local itemID = ExtractReagentItemIDFromFrame(focus)
        local targetRecipeID = GetCraftableRecipeForItemID(itemID, false)
        if targetRecipeID then
            if IsControlKeyDown() then
                JumpMainWindowToRecipe(targetRecipeID)
            else
                local parentID = GetCurrentDisplayedRecipeID()
                local suggested = GetSuggestedCraftQtyForReagent(parentID, itemID, targetRecipeID)
                OpenRecipeInPeekTab(targetRecipeID, suggested)
            end
        end
    end
end)

if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_Professions") then
    TryHookProfessionsFrame()
end

-- Tooltip Hook: Appends craftable status and click shortcuts when hovering over craftable reagents
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip ~= GameTooltip then return end
        if not ProfessionsFrame or not ProfessionsFrame:IsShown() then return end

        local focus = GetMouseFoci and GetMouseFoci()[1] or (GetMouseFocus and GetMouseFocus())
        if not focus or not IsInsideSchematicForm(focus) then return end

        if data and data.id then
            local targetRecipeID = GetCraftableRecipeForItemID(data.id, false)
            if targetRecipeID then
                local rInfo = recipeNameCache[targetRecipeID] or (C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo(targetRecipeID))
                local rName = (rInfo and rInfo.name) or "Recipe"
                local subMaxCraftable, isLearned = GetRecipeMaxCraftableCount(targetRecipeID)
                tooltip:AddLine(" ")
                if isLearned and subMaxCraftable > 0 then
                    tooltip:AddLine(string.format("|cFF00FF66Ready to Craft: Materials on hand for %d|r", subMaxCraftable))
                else
                    tooltip:AddLine("|cFFFF6666Missing raw materials to craft right now|r")
                end
                tooltip:AddLine("|cFF00FF66<Left-Click to Peek Recipe: " .. rName .. ">|r")
                tooltip:AddLine("|cFF00CCFF<Ctrl + Left-Click to Jump to Recipe Page>|r")
            end
        end
    end)
end

-- Slash Command Handler (/rp or /recipeek)
SlashCmdList["RECIPEEK"] = function()
    RebuildProfessionItemMap()
    UpdateMainSchematicFormIndicators()
    UpdateCraftingOrderBrowseListHighlights()
    local curID = GetCurrentDisplayedRecipeID()
    if curID then
        OpenRecipeInPeekTab(curID, 1)
    else
        print("|cFF00CCFFReciPeek:|r Open a Profession window and click any craftable reagent (or type /rp to pin the active recipe).")
    end
end