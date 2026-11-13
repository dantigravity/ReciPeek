-- ============================================================================
-- ReciPeek (v1.5.0)
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
local lastScannedProfessionID = nil

-- Per-profession cache of each recipe's required reagent slots (used by the Recipes tab materials filter)
local recipeRequirementCache = {}

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
    wipe(recipeRequirementCache)
    lastScannedRecipeCount = 0
    lastScannedProfessionID = nil

    if not C_TradeSkillUI or not C_TradeSkillUI.GetAllRecipeIDs then return end
    if C_TradeSkillUI.GetBaseProfessionInfo then
        local baseInfo = C_TradeSkillUI.GetBaseProfessionInfo()
        lastScannedProfessionID = baseInfo and baseInfo.professionID
    end
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

-- Rebuilds the item -> recipe index if it is empty, stale, or belongs to a different profession
local function EnsureProfessionItemMap()
    if not next(itemToRecipeMap) then
        RebuildProfessionItemMap()
        return
    end
    if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
        local baseInfo = C_TradeSkillUI.GetBaseProfessionInfo()
        if baseInfo and baseInfo.professionID and baseInfo.professionID ~= lastScannedProfessionID then
            RebuildProfessionItemMap()
            return
        end
    end
    if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
        local allRecipes = C_TradeSkillUI.GetAllRecipeIDs()
        if allRecipes and #allRecipes ~= lastScannedRecipeCount then
            RebuildProfessionItemMap()
        end
    end
end

-- Checks if an itemID is crafted by a recipe in the active profession
local function GetCraftableRecipeForItemID(itemID, allowSameAsMain)
    if not itemID then return nil end
    EnsureProfessionItemMap()

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
-- RECIPES TAB FILTER: "HAVE MATERIALS (INCL. SUB-CRAFTS)"
-- ----------------------------------------------------------------------------
-- Hides every recipe the player cannot craft right now, counting reagents they
-- could craft first from materials on hand. All reagents for one recipe come
-- from a single shared pool, so if a recipe needs 2x a craftable reagent and the
-- player only has base materials for 1, that recipe stays hidden.
-- ============================================================================

local MATERIALS_FILTER_MAX_DEPTH = 6
local BASIC_REAGENT_TYPE = (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 1
local SALVAGE_RECIPE_TYPE = Enum and Enum.TradeskillRecipeType and Enum.TradeskillRecipeType.Salvage

local materialsFilterEnabled = false
local materialsFilterRecheckPending = false
local listBuiltWithFilter = false  -- whether the currently displayed list was built with the filter on
local lastFilterCandidates = {}   -- recipeID -> true for every learned recipe in the last unfiltered list
local lastFilterResults = {}      -- recipeID -> boolean result from the last filter pass

-- Returns (and caches) the required reagent slots and output yield for a recipe
local function GetRecipeRequirements(recipeID)
    local cached = recipeRequirementCache[recipeID]
    if cached ~= nil then return cached or nil end

    local schematic = C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    if not schematic or not schematic.reagentSlotSchematics then
        recipeRequirementCache[recipeID] = false
        return nil
    end

    local isSalvage = (SALVAGE_RECIPE_TYPE ~= nil and schematic.recipeType == SALVAGE_RECIPE_TYPE) or false
    local req = {
        slots = {},
        isSalvage = isSalvage,
        -- For salvage recipes quantityMax is the number of items consumed, not the output yield
        salvageQuantity = math.max(1, schematic.quantityMax or 1),
        yield = isSalvage and 1 or math.max(1, schematic.quantityMin or 1),
    }

    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        local qty = slot.quantityRequired or 0
        local isBasic = (slot.reagentType == BASIC_REAGENT_TYPE or slot.reagentType == nil)
        -- Basic reagents, plus any slot Blizzard flags as mandatory (e.g. Sparks on crafted gear)
        local isRequired = (isBasic and slot.required ~= false) or slot.required == true
        if isRequired and qty > 0 and slot.reagents and #slot.reagents > 0 then
            local entry = { quantity = qty, reagents = {} }
            for _, r in ipairs(slot.reagents) do
                if r.itemID and r.itemID > 0 then
                    table.insert(entry.reagents, { key = r.itemID, itemID = r.itemID })
                elseif r.currencyID and r.currencyID > 0 then
                    table.insert(entry.reagents, { key = "c" .. r.currencyID, currencyID = r.currencyID })
                end
            end
            if #entry.reagents > 0 then
                table.insert(req.slots, entry)
            end
        end
    end

    req.evaluable = isSalvage or #req.slots > 0
    recipeRequirementCache[recipeID] = req
    return req
end

-- Returns the on-hand count of a reagent (item or currency), cached for the current filter pass.
-- Items count bags, reagent bag, character bank and Warband bank, since crafting draws from all of them.
local function GetFilterReagentCount(ctx, reagent)
    local count = ctx.counts[reagent.key]
    if count == nil then
        if reagent.itemID then
            count = GetPlayerReagentCount(reagent.itemID)
        elseif reagent.currencyID and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
            local info = C_CurrencyInfo.GetCurrencyInfo(reagent.currencyID)
            count = (info and info.quantity) or 0
        else
            count = 0
        end
        ctx.counts[reagent.key] = count
    end
    return count
end

-- Returns a learned recipe in this profession that crafts any of the slot's reagent variants
local function FindLearnedSubRecipe(reagents)
    for _, r in ipairs(reagents) do
        local subRecipeID = r.itemID and itemToRecipeMap[r.itemID]
        if subRecipeID then
            local cached = recipeNameCache[subRecipeID]
            local learned = cached and cached.learned
            if learned == nil and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
                local info = C_TradeSkillUI.GetRecipeInfo(subRecipeID)
                learned = info and info.learned
            end
            if learned then return subRecipeID end
        end
    end
    return nil
end

-- Reserves materials for `crafts` executions of recipeID from the shared pool, crafting any
-- missing intermediate reagents recursively. Returns false if materials run out at any depth.
-- If `steps` is given, every craft involved is appended to it in the order it must happen
-- (intermediate reagents first, recipeID itself last).
local function ReserveCraftMaterials(recipeID, crafts, pool, ctx, depth, visiting, steps)
    if depth > MATERIALS_FILTER_MAX_DEPTH or visiting[recipeID] then return false end

    local req = GetRecipeRequirements(recipeID)
    if not req or req.isSalvage or not req.evaluable then return false end

    visiting[recipeID] = true
    local ok = true

    for _, slot in ipairs(req.slots) do
        local need = slot.quantity * crafts

        -- 1. Use what is already on hand (any quality tier / accepted variant)
        for _, r in ipairs(slot.reagents) do
            if need <= 0 then break end
            local have = pool[r.key]
            if have == nil then have = GetFilterReagentCount(ctx, r) end
            if have > 0 then
                local use = math.min(have, need)
                pool[r.key] = have - use
                need = need - use
            else
                pool[r.key] = 0
            end
        end

        -- 2. Craft the shortfall from base materials, drawing from the same pool
        if need > 0 then
            local subRecipeID = FindLearnedSubRecipe(slot.reagents)
            local subReq = subRecipeID and GetRecipeRequirements(subRecipeID)
            if not subReq or subReq.isSalvage or not subReq.evaluable then
                ok = false
                break
            end

            local subCrafts = math.ceil(need / subReq.yield)
            if not ReserveCraftMaterials(subRecipeID, subCrafts, pool, ctx, depth + 1, visiting, steps) then
                ok = false
                break
            end

            -- Leftover output (e.g. recipe yields 2, only 1 needed) stays available for other slots
            local surplus = (subCrafts * subReq.yield) - need
            if surplus > 0 then
                local key = slot.reagents[1].key
                pool[key] = (pool[key] or 0) + surplus
            end
        end
    end

    visiting[recipeID] = nil
    if ok and steps then
        table.insert(steps, { recipeID = recipeID, count = crafts })
    end
    return ok
end

-- Salvage recipes (Prospecting, Milling, etc.) pass if any accepted item has a full stack in bags
local function HasSalvageMaterials(recipeID, req)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetSalvagableItemIDs then return false end
    local ok, itemIDs = pcall(C_TradeSkillUI.GetSalvagableItemIDs, recipeID)
    if not ok or type(itemIDs) ~= "table" then return false end
    for _, itemID in ipairs(itemIDs) do
        local count = 0
        if C_Item and C_Item.GetItemCount then
            count = C_Item.GetItemCount(itemID, false, false, false, false) or 0
        end
        if count >= req.salvageQuantity then return true end
    end
    return false
end

-- Returns true if a recipe from the native list can be crafted at least once (including sub-crafts)
local function RecipePassesMaterialsFilter(recipeInfo, ctx)
    if not recipeInfo or not recipeInfo.learned then return false end
    if recipeInfo.isDummyRecipe or recipeInfo.isGatheringRecipe then return false end

    local listRecipeID = recipeInfo.recipeID
    local cached = ctx.results[listRecipeID]
    if cached ~= nil then return cached end

    local result = false
    if (recipeInfo.numAvailable or 0) > 0 then
        -- Blizzard already confirms the materials are on hand
        result = true
    else
        -- Ranked recipes are listed by rank 1 but crafted with the highest learned rank
        local craftInfo = recipeInfo
        if recipeInfo.nextRecipeID and Professions and Professions.GetHighestLearnedRecipe then
            craftInfo = Professions.GetHighestLearnedRecipe(recipeInfo) or recipeInfo
        end

        if craftInfo ~= recipeInfo and (craftInfo.numAvailable or 0) > 0 then
            result = true
        else
            local req = GetRecipeRequirements(craftInfo.recipeID)
            if req and req.isSalvage then
                result = HasSalvageMaterials(craftInfo.recipeID, req)
            elseif req and req.evaluable then
                result = ReserveCraftMaterials(craftInfo.recipeID, 1, {}, ctx, 0, {})
            end
        end
    end

    ctx.results[listRecipeID] = result
    return result
end

local function NewMaterialsFilterContext()
    return { counts = {}, results = {} }
end

-- Recursively removes recipes that fail the filter, then any categories left empty
local function PruneRecipeTreeNode(node, ctx)
    local children = node:GetNodes()
    local keptAnyRecipe = false
    local keptDirectRecipe = false

    for i = #children, 1, -1 do
        local child = children[i]
        local data = child:GetData()
        if type(data) == "table" then
            if data.recipeInfo then
                local info = data.recipeInfo
                local passes = RecipePassesMaterialsFilter(info, ctx)
                if info.learned and info.recipeID then
                    lastFilterCandidates[info.recipeID] = true
                    lastFilterResults[info.recipeID] = passes
                end
                if passes then
                    keptAnyRecipe = true
                    keptDirectRecipe = true
                else
                    node:Remove(child, true)
                end
            elseif data.categoryInfo then
                if PruneRecipeTreeNode(child, ctx) then
                    keptAnyRecipe = true
                else
                    node:Remove(child, true)
                end
            end
        end
    end

    -- Drop the spacer rows of categories that no longer list any recipes directly
    if not keptDirectRecipe then
        for i = #children, 1, -1 do
            local data = children[i]:GetData()
            if type(data) == "table" and (data.topPadding or data.bottomPadding) then
                node:Remove(children[i], true)
            end
        end
    end

    return keptAnyRecipe
end

-- Filters the Recipes tab TreeDataProvider in place (called right after Blizzard assigns it)
local function ApplyMaterialsFilterToDataProvider(dataProvider)
    listBuiltWithFilter = materialsFilterEnabled
    if not materialsFilterEnabled then return end
    if type(dataProvider) ~= "table" or not dataProvider.GetRootNode or not dataProvider.Invalidate then return end
    local root = dataProvider:GetRootNode()
    if not root or not root.GetNodes then return end

    EnsureProfessionItemMap()
    wipe(lastFilterCandidates)
    wipe(lastFilterResults)

    local ok, err = pcall(function()
        PruneRecipeTreeNode(root, NewMaterialsFilterContext())

        -- Unlearned recipes are always filtered out, so the "Unlearned" divider is no longer needed
        local rootChildren = root:GetNodes()
        for i = #rootChildren, 1, -1 do
            local data = rootChildren[i]:GetData()
            if type(data) == "table" and data.isDivider then
                root:Remove(rootChildren[i], true)
            end
        end
    end)

    dataProvider:Invalidate()

    if not ok then
        geterrorhandler()(err)
    end
end

-- Returns the Recipes tab page if it exists
local function GetCraftingPage()
    return ProfessionsFrame and ProfessionsFrame.CraftingPage
end

-- Asks Blizzard to rebuild the Recipes tab list (our SetDataProvider hook re-applies the filter)
local function RefreshNativeRecipeList()
    local page = GetCraftingPage()
    if not page or not page:IsVisible() or not page.Init then return end
    if C_TradeSkillUI and C_TradeSkillUI.IsDataSourceChanging and C_TradeSkillUI.IsDataSourceChanging() then return end
    if not Professions or not Professions.GetProfessionInfo then return end

    local professionInfo = Professions.GetProfessionInfo()
    if not professionInfo or not professionInfo.professionID or professionInfo.professionID == 0 then return end
    page:Init(professionInfo)
end

local function UpdateFilterDropdownResetState()
    local page = GetCraftingPage()
    local dropdown = page and page.RecipeList and page.RecipeList.FilterDropdown
    if dropdown and dropdown.ValidateResetState then
        dropdown:ValidateResetState()
    end
end

local function SetMaterialsFilterEnabled(enabled)
    enabled = enabled and true or false
    if materialsFilterEnabled == enabled then return end
    materialsFilterEnabled = enabled
    if not enabled then
        wipe(lastFilterCandidates)
        wipe(lastFilterResults)
    end
    -- Defer so the rebuild does not run inside the open filter menu's click handler
    C_Timer.After(0, function()
        RefreshNativeRecipeList()
        UpdateFilterDropdownResetState()
    end)
end

-- Returns true while the player is casting / repeating a craft
local function IsPlayerCrafting()
    if UnitCastingInfo and UnitCastingInfo("player") then return true end
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeRepeatCount then
        local ok, count = pcall(C_TradeSkillUI.GetRecipeRepeatCount)
        if ok and type(count) == "number" and count > 0 then return true end
    end
    return false
end

-- Returns true if inventory changes would add or remove any recipe from the filtered list
local function MaterialsFilterResultsChanged()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeInfo then return false end
    EnsureProfessionItemMap()
    local ctx = NewMaterialsFilterContext()
    for recipeID in pairs(lastFilterCandidates) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if info and RecipePassesMaterialsFilter(info, ctx) ~= (lastFilterResults[recipeID] or false) then
            return true
        end
    end
    return false
end

-- Debounced re-check after bag changes; only rebuilds the list when its contents would change.
-- Skipped mid-craft so Blizzard's reagent allocations are not reset; re-run on cast stop.
local function ScheduleMaterialsFilterRecheck(delay)
    if not materialsFilterEnabled or materialsFilterRecheckPending then return end
    materialsFilterRecheckPending = true
    C_Timer.After(delay or 0.4, function()
        materialsFilterRecheckPending = false
        if not materialsFilterEnabled then return end
        local page = GetCraftingPage()
        if not page or not page:IsVisible() then return end
        if IsPlayerCrafting() then return end
        if MaterialsFilterResultsChanged() then
            RefreshNativeRecipeList()
        end
    end)
end

-- ============================================================================
-- CRAFTING ORDERS: COMBINED MATERIALS (CUSTOMER + PLAYER) HIGHLIGHT & FILTER
-- ----------------------------------------------------------------------------
-- An order row turns green when the customer's reagents plus the player's own
-- cover it right now, and teal when they cover it once the player crafts some
-- reagents first from base materials on hand (same shared pool as the Recipes
-- filter). The "Have Materials" option in the Crafting Orders tab's Filter menu
-- hides every other order.
-- ============================================================================

local ORDERS_FILTER_MAX_AUTO_REQUESTS = 20  -- extra result pages fetched per search while the filter hides rows
local ORDERS_FILTER_MIN_ROWS = 12           -- keep fetching pages while fewer rows than this are shown

local ordersFilterEnabled = false
local ordersFilterRecheckPending = false
local ordersListBuiltWithFilter = false  -- whether the currently displayed order list was built with the filter on
local ordersAutoRequestCount = 0
local lastShownOrdersBucketed = nil      -- nil: nothing shown; true: recipe buckets; false: individual orders
local lastOrdersFilterResults = {}       -- order/bucket table -> boolean verdict from the last filter pass
local ordersRangeCallbackOwner = {}
local lastOrdersFilterError = nil        -- error text from the last filter pass, shown by /rp why

-- Builds a lookup table of reagents provided by the customer for an order
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

-- Returns "direct" if the customer's plus the player's materials cover the order right now,
-- "subcraft" if they cover it once missing reagents are crafted from base materials on hand,
-- or false. Bucket rows (public orders grouped by recipe) carry no customer reagents.
local function EvaluateOrderReadiness(order, ctx)
    if type(order) ~= "table" then return false end
    local recipeID = order.spellID or order.recipeID
    if not recipeID or recipeID <= 0 then return false end

    local rInfo = (C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)) or recipeNameCache[recipeID]
    if not rInfo or rInfo.learned == false then return false end

    local req = GetRecipeRequirements(recipeID)
    if not req or req.isSalvage or not req.evaluable then return false end

    ctx = ctx or NewMaterialsFilterContext()
    local customer = ExtractCustomerProvidedMap(order)

    -- Everything usable for this order: the player's stock plus what the customer supplied
    local function SeedPool()
        local pool = {}
        for _, slot in ipairs(req.slots) do
            for _, r in ipairs(slot.reagents) do
                if pool[r.key] == nil then
                    pool[r.key] = GetFilterReagentCount(ctx, r) + ((r.itemID and customer[r.itemID]) or 0)
                end
            end
        end
        return pool
    end

    -- 1. Covered by materials on hand (any accepted quality tier / variant)
    local pool = SeedPool()
    local direct = true
    for _, slot in ipairs(req.slots) do
        local need = slot.quantity
        for _, r in ipairs(slot.reagents) do
            if need <= 0 then break end
            local use = math.min(pool[r.key], need)
            pool[r.key] = pool[r.key] - use
            need = need - use
        end
        if need > 0 then
            direct = false
            break
        end
    end
    if direct then return "direct" end

    -- 2. Covered once the shortfall is crafted from base materials (one shared pool, like the Recipes filter)
    if ReserveCraftMaterials(recipeID, 1, SeedPool(), ctx, 0, {}) then
        return "subcraft"
    end
    return false
end

-- Row colors: green = ready now, teal = ready after crafting some reagents first
local ORDER_HIGHLIGHT_STYLES = {
    direct = {
        bg     = { 0.04, 0.58, 0.22, 0.20 },
        bar    = { 0.10, 1.00, 0.38, 0.95 },
        border = { 0.15, 0.90, 0.40, 0.50 },
    },
    subcraft = {
        bg     = { 0.03, 0.42, 0.46, 0.20 },
        bar    = { 0.20, 0.88, 0.90, 0.95 },
        border = { 0.22, 0.80, 0.84, 0.50 },
    },
}

-- Creates or retrieves the row highlight overlay for a Crafting Order list row
local function EnsureOrderRowHighlight(row)
    if row.reciPeekOrderHighlight then return row.reciPeekOrderHighlight end

    local hl = CreateFrame("Frame", nil, row, "BackdropTemplate")
    hl:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
    hl:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
    hl:SetFrameLevel(math.max(1, row:GetFrameLevel()))
    hl:EnableMouse(false)

    -- Row background fill
    local bg = hl:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    hl.bg = bg

    -- Left-edge accent bar (width: 3px)
    local leftBar = hl:CreateTexture(nil, "OVERLAY")
    leftBar:SetPoint("TOPLEFT", hl, "TOPLEFT", 0, 0)
    leftBar:SetPoint("BOTTOMLEFT", hl, "BOTTOMLEFT", 0, 0)
    leftBar:SetWidth(3)
    hl.leftBar = leftBar

    -- Row outline border
    hl:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })

    row.reciPeekOrderHighlight = hl
    return hl
end

local function ApplyOrderHighlightStyle(hl, state)
    local style = ORDER_HIGHLIGHT_STYLES[state] or ORDER_HIGHLIGHT_STYLES.direct
    if hl.reciPeekState == state then return end
    hl.reciPeekState = state
    hl.bg:SetColorTexture(unpack(style.bg))
    hl.leftBar:SetColorTexture(unpack(style.bar))
    hl:SetBackdropBorderColor(unpack(style.border))
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
local function UpdateSingleOrderRowHighlight(row, ctx)
    if not row or not row:IsShown() then
        if row and row.reciPeekOrderHighlight then
            row.reciPeekOrderHighlight:Hide()
        end
        return
    end

    local order = GetOrderInfoFromRow(row)
    local state = order and EvaluateOrderReadiness(order, ctx)
    if state then
        local hl = EnsureOrderRowHighlight(row)
        ApplyOrderHighlightStyle(hl, state)
        decoratedOrderRows[row] = true
        hl:Show()
    elseif row.reciPeekOrderHighlight then
        row.reciPeekOrderHighlight:Hide()
    end
end

local function GetOrdersPage()
    return ProfessionsFrame and ProfessionsFrame.OrdersPage
end

-- Returns the Crafting Orders tab's order list ScrollBox and its parent list frame
local function GetOrdersScrollBox()
    local page = GetOrdersPage()
    local orderList = page and page.BrowseFrame and page.BrowseFrame.OrderList
    return orderList and orderList.ScrollBox, orderList
end

-- Refreshes highlights across all visible rows in the Crafting Orders BrowseFrame ScrollBox
local function UpdateCraftingOrderBrowseListHighlights()
    if not ProfessionsFrame or not ProfessionsFrame:IsShown() or not ProfessionsFrame.OrdersPage then
        return
    end

    local scrollBox = GetOrdersScrollBox()
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

    local ctx = NewMaterialsFilterContext()
    if scrollBox.GetFrames then
        local frames = scrollBox:GetFrames()
        if frames then
            for _, row in ipairs(frames) do
                UpdateSingleOrderRowHighlight(row, ctx)
            end
        end
    elseif scrollBox.ForEachFrame then
        scrollBox:ForEachFrame(function(row)
            UpdateSingleOrderRowHighlight(row, ctx)
        end)
    end
end

-- Filter verdict for one list row. A bucket (public orders grouped by recipe) can't be judged,
-- since each order inside brings its own reagents, so it stays unless the recipe is unlearned;
-- opening it lists its orders, and those are filtered.
local function OrderPassesFilter(option, ctx)
    if type(option) ~= "table" then return true end
    if not option.orderID then
        local recipeID = option.spellID
        local rInfo = recipeID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
        return not (rInfo and rInfo.learned == false)
    end
    return EvaluateOrderReadiness(option, ctx) and true or false
end

-- Fetches another page of orders while the filter leaves the list short or the player scrolls
-- near its end. Blizzard's own paging counts the hidden rows, so on its own it stops too early.
local function MaybeRequestMoreOrders()
    if not ordersFilterEnabled then return end
    local page = GetOrdersPage()
    local scrollBox = GetOrdersScrollBox()
    if not page or not scrollBox or not scrollBox:IsVisible() then return end
    if not page.expectMoreRows or page.requestCallback or not page.RequestMoreOrders then return end
    if ordersAutoRequestCount >= ORDERS_FILTER_MAX_AUTO_REQUESTS then return end

    local dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    local shown = (dataProvider and dataProvider.GetSize and dataProvider:GetSize()) or 0
    local nearEnd = shown < ORDERS_FILTER_MIN_ROWS
    if not nearEnd and scrollBox.HasScrollableExtent and not scrollBox:HasScrollableExtent() then
        nearEnd = true
    end
    if not nearEnd and scrollBox.GetScrollPercentage and scrollBox:GetScrollPercentage() >= 0.85 then
        nearEnd = true
    end
    if not nearEnd then return end

    ordersAutoRequestCount = ordersAutoRequestCount + 1
    local ok, err = pcall(page.RequestMoreOrders, page)
    if not ok then geterrorhandler()(err) end
end

-- Removes rows that fail the filter from the order list (runs right after Blizzard's ShowGeneric fills it)
local function ApplyOrdersFilterToList(orders, offset)
    local isFirstPage = (offset or 0) == 0
    if isFirstPage then
        ordersAutoRequestCount = 0
        wipe(lastOrdersFilterResults)
        if type(orders) == "table" and orders[1] then
            lastShownOrdersBucketed = (orders[1].orderID == nil)
        else
            lastShownOrdersBucketed = nil
        end
    end
    ordersListBuiltWithFilter = ordersFilterEnabled
    if not ordersFilterEnabled then return end

    local scrollBox, orderList = GetOrdersScrollBox()
    local dataProvider = scrollBox and scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if not dataProvider or not dataProvider.Enumerate then return end

    EnsureProfessionItemMap()
    local ctx = NewMaterialsFilterContext()

    local ok, err = pcall(function()
        local drop, dropList = {}, {}
        for _, elem in dataProvider:Enumerate() do
            local option = type(elem) == "table" and elem.option
            local passed = OrderPassesFilter(option, ctx)
            if type(option) == "table" then
                lastOrdersFilterResults[option] = passed
            end
            if not passed then
                drop[elem] = true
                table.insert(dropList, elem)
            end
        end

        -- Hand the list a new provider holding only the passing rows (removing rows from Blizzard's
        -- provider in place did not refresh the list). Later result pages are inserted into this one.
        if #dropList > 0 then
            local kept = {}
            for _, elem in dataProvider:Enumerate() do
                if not drop[elem] then
                    table.insert(kept, elem)
                end
            end
            local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
            scrollBox:SetDataProvider(CreateDataProvider(kept), retain)
            dataProvider = scrollBox:GetDataProvider()

            for _, elem in dataProvider:Enumerate() do
                if drop[elem] then
                    error("ReciPeek: filtered orders are still in the list after rebuilding it")
                end
            end
        end
        lastOrdersFilterError = nil

        -- Blizzard only shows its "no orders" text when the server sent none
        local remaining = dataProvider.GetSize and dataProvider:GetSize() or 1
        if remaining == 0 and orderList and orderList.ResultsText and type(orders) == "table" and #orders > 0 then
            orderList.ResultsText:SetText("No orders you have the materials for.\n|cFF888888Turn off ReciPeek's Have Materials filter to see every order.|r")
            orderList.ResultsText:Show()
        end
    end)

    if not ok then
        lastOrdersFilterError = tostring(err)
        geterrorhandler()(err)
    end

    C_Timer.After(0, MaybeRequestMoreOrders)
end

-- Rebuilds the order list from the results Blizzard already holds (no new server request)
local function RefreshNativeOrdersList()
    local page = GetOrdersPage()
    if not page or not page.BrowseFrame or not page.BrowseFrame:IsVisible() then return end
    if page.requestCallback then return end  -- a request is in flight; its results get filtered on arrival

    local ok, err = true, nil
    if lastShownOrdersBucketed == true and page.ShowBuckets then
        ok, err = pcall(page.ShowBuckets, page, 0, false)
    elseif lastShownOrdersBucketed == false and page.ShowOrders then
        ok, err = pcall(page.ShowOrders, page, 0, false)
    end
    if not ok then geterrorhandler()(err) end
end

local function UpdateOrdersFilterDropdownResetState()
    local page = GetOrdersPage()
    local dropdown = page and page.BrowseFrame and page.BrowseFrame.RecipeList and page.BrowseFrame.RecipeList.FilterDropdown
    if dropdown and dropdown.ValidateResetState then
        dropdown:ValidateResetState()
    end
end

local function SetOrdersFilterEnabled(enabled)
    enabled = enabled and true or false
    if ordersFilterEnabled == enabled then return end
    ordersFilterEnabled = enabled
    -- Defer so the rebuild does not run inside the open filter menu's click handler
    C_Timer.After(0, function()
        RefreshNativeOrdersList()
        UpdateOrdersFilterDropdownResetState()
    end)
end

-- Returns true if inventory changes would add or remove any row from the filtered order list
local function OrdersFilterResultsChanged()
    if not next(lastOrdersFilterResults) then return false end
    EnsureProfessionItemMap()
    local ctx = NewMaterialsFilterContext()
    for option, passed in pairs(lastOrdersFilterResults) do
        if OrderPassesFilter(option, ctx) ~= passed then
            return true
        end
    end
    return false
end

-- Debounced re-check after bag changes; only rebuilds the order list when its contents would change
local function ScheduleOrdersFilterRecheck(delay)
    if not ordersFilterEnabled or ordersFilterRecheckPending then return end
    ordersFilterRecheckPending = true
    C_Timer.After(delay or 0.4, function()
        ordersFilterRecheckPending = false
        if not ordersFilterEnabled then return end
        local page = GetOrdersPage()
        if not page or not page.BrowseFrame or not page.BrowseFrame:IsVisible() then return end
        if IsPlayerCrafting() then return end
        if OrdersFilterResultsChanged() then
            RefreshNativeOrdersList()
        end
    end)
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

local RefreshPeekWindow
local UpdateMainSchematicFormIndicators

-- ============================================================================
-- MASTER CRAFT & BATCH CRAFTING
-- ----------------------------------------------------------------------------
-- A craft run is a list of target recipes and how many of each to make. Each
-- click crafts the next step of its plan: missing intermediate reagents first
-- (deepest first), then the targets. WoW only starts a craft from a click, so
-- every step takes one click, but one step can be many crafts of one recipe.
-- The plan is rebuilt from current bags after every craft.
-- ============================================================================

local MASTER_CRAFT_MAX_QTY = 999

-- { targets = { { recipeID, remaining, spellIDs = { [id] = true } }, ... }, prepOnly = boolean }
-- A prep-only run (main window "Prep All") crafts the reagents but leaves the target itself to
-- Blizzard's Create button, so its reagent quality, finishing reagents and concentration apply.
local craftRun = nil

local function CopyPool(pool)
    local copy = {}
    for k, v in pairs(pool) do copy[k] = v end
    return copy
end

local function IsRecipeLearned(recipeID)
    local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
    if info then return info.learned ~= false end
    local cached = recipeNameCache[recipeID]
    return (cached and cached.learned ~= false) or false
end

local function GetRecipeDisplayName(recipeID)
    local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
    return (info and info.name) or (recipeNameCache[recipeID] and recipeNameCache[recipeID].name) or ("Recipe #" .. tostring(recipeID))
end

local function ShortenName(name, maxLen)
    if string.len(name) > maxLen then
        return string.sub(name, 1, maxLen - 2) .. ".."
    end
    return name
end

-- Largest count (up to `wanted`) of recipeID that `pool` covers, crafting intermediate reagents as needed
local function GetMaxPlannableCrafts(recipeID, wanted, pool, ctx)
    if not recipeID or (wanted or 0) < 1 or not IsRecipeLearned(recipeID) then return 0 end
    local function Fits(n)
        return ReserveCraftMaterials(recipeID, n, CopyPool(pool), ctx, 0, {})
    end
    if not Fits(1) then return 0 end
    if Fits(wanted) then return wanted end
    local lo, hi = 1, wanted  -- Fits(lo) is true, Fits(hi) is false
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if Fits(mid) then lo = mid else hi = mid end
    end
    return lo
end

-- Plans every craft needed for `targets` ({ recipeID, count } list). All targets draw from one shared
-- pool, in order, so they never count the same materials twice. Returns the ordered steps
-- ({ recipeID, count }, one per recipe, intermediates first) and how many of each target are covered.
local function BuildCraftPlan(targets)
    EnsureProfessionItemMap()
    local ctx = NewMaterialsFilterContext()
    local pool, rawSteps, planned = {}, {}, {}
    for i, target in ipairs(targets) do
        local n = GetMaxPlannableCrafts(target.recipeID, target.count, pool, ctx)
        planned[i] = n
        if n > 0 then
            ReserveCraftMaterials(target.recipeID, n, pool, ctx, 0, {}, rawSteps)
        end
    end

    -- One step per recipe, placed where it is first needed (its own intermediates are always earlier)
    local steps, byRecipe = {}, {}
    for _, s in ipairs(rawSteps) do
        local existing = byRecipe[s.recipeID]
        if existing then
            existing.count = existing.count + s.count
        else
            local step = { recipeID = s.recipeID, count = s.count }
            byRecipe[s.recipeID] = step
            table.insert(steps, step)
        end
    end
    return steps, planned
end

-- Targets of the active run that still need crafting, as { recipeID, count } for BuildCraftPlan
local function GetCraftRunTargets()
    local list = {}
    if craftRun then
        for _, t in ipairs(craftRun.targets) do
            if t.remaining > 0 then
                table.insert(list, { recipeID = t.recipeID, count = t.remaining })
            end
        end
    end
    return list
end

local function EndCraftRun(message)
    craftRun = nil
    if message then
        print("|cFF00CCFFReciPeek:|r " .. message)
    end
end

-- Plans the active run's next step. Returns steps, the next step (nil when out of materials) and its
-- verb ("Prep" for a reagent, "Craft" for a target). Returns nil if the run just ended: everything is
-- crafted, or a prep-only run has nothing left but its target.
local function DescribeCraftRun()
    if not craftRun then return nil end
    local targets = GetCraftRunTargets()
    if #targets == 0 then
        EndCraftRun("Crafting finished.")
        return nil
    end
    local steps = BuildCraftPlan(targets)
    local step = steps[1]
    local isTarget = false
    if step then
        for _, t in ipairs(craftRun.targets) do
            if t.remaining > 0 and t.recipeID == step.recipeID then isTarget = true end
        end
    end
    if step and isTarget and craftRun.prepOnly then
        EndCraftRun(string.format("Reagents ready. Click Create to craft %s.", GetRecipeDisplayName(step.recipeID)))
        return nil
    end
    return steps, step, isTarget and "Craft" or "Prep"
end

-- Refreshes everything that shows run state (main window buttons and the side window)
local function RefreshCraftRunDisplays(delay)
    C_Timer.After(delay or 0.2, function()
        if UpdateMainSchematicFormIndicators then UpdateMainSchematicFormIndicators() end
        if peekFrame and peekFrame:IsShown() then RefreshPeekWindow() end
    end)
end

-- Crafts the next step of the active run. Must be called from a click.
local function ExecuteNextCraftStep()
    if not craftRun or IsPlayerCrafting() then return end
    local steps, step = DescribeCraftRun()
    if not steps then return end
    if not step then
        print("|cFF00CCFFReciPeek:|r Out of materials for the rest of this run. Click Cancel to stop it.")
        return
    end
    if C_TradeSkillUI and C_TradeSkillUI.CraftRecipe then
        C_TradeSkillUI.CraftRecipe(step.recipeID, step.count)
    end
end

-- Starts a run for targets ({ recipeID, count } list) and crafts its first step. Must be called from a click.
local function StartCraftRun(targets, prepOnly)
    local runTargets = {}
    for _, t in ipairs(targets) do
        if t.recipeID and (t.count or 0) > 0 then
            -- A ranked recipe may be cast as its highest learned rank, so match either spell
            local spellIDs = { [t.recipeID] = true }
            local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(t.recipeID)
            if info and info.nextRecipeID and Professions and Professions.GetHighestLearnedRecipe then
                local highest = Professions.GetHighestLearnedRecipe(info)
                if highest and highest.recipeID then spellIDs[highest.recipeID] = true end
            end
            table.insert(runTargets, { recipeID = t.recipeID, remaining = t.count, spellIDs = spellIDs })
        end
    end
    if #runTargets == 0 then return end
    craftRun = { targets = runTargets, prepOnly = prepOnly and true or false }
    ExecuteNextCraftStep()
end

-- Counts a finished cast toward the run's targets (UNIT_SPELLCAST_SUCCEEDED; a recipe's spell is its recipeID)
local function OnCraftCastSucceeded(spellID)
    if not craftRun or not spellID then return end
    local counted = false
    local allDone = true
    for _, t in ipairs(craftRun.targets) do
        if not counted and t.remaining > 0 and t.spellIDs[spellID] then
            t.remaining = t.remaining - 1
            counted = true
        end
        if t.remaining > 0 then allDone = false end
    end
    if counted and allDone then
        EndCraftRun("Crafting finished.")
    end
end

-- Builds the tooltip lines describing a plan
local function AddPlanToTooltip(steps, targetIDs)
    if #steps == 0 then
        GameTooltip:AddLine("Not enough materials, even counting sub-crafts.", 1, 0.4, 0.4)
        return
    end
    for i, step in ipairs(steps) do
        local verb = targetIDs[step.recipeID] and "Craft" or "Prep"
        GameTooltip:AddLine(string.format("%d. %s %dx %s", i, verb, step.count, GetRecipeDisplayName(step.recipeID)), 1, 1, 1)
    end
end

-- Updates the side window's [Batch] button. Idle, it crafts every ticked tab at its own quantity;
-- while any crafting run is active it shows and advances that run's next step (right-click cancels).
local function UpdateCraftRunControls()
    local batchBtn = peekFrame.batchBtn
    local crafting = IsPlayerCrafting()

    local checkedTabs = {}
    for _, tab in ipairs(openTabs) do
        if tab.batch then table.insert(checkedTabs, tab) end
    end

    local steps, step, verb
    if craftRun then
        steps, step, verb = DescribeCraftRun()  -- may end the run, which falls through to idle below
    end
    local isRun = craftRun ~= nil

    if isRun then
        if crafting then
            batchBtn:SetText("Crafting...")
            batchBtn:Disable()
        elseif step then
            local more = (#steps > 1) and string.format(" (+%d)", #steps - 1) or ""
            batchBtn:SetText(string.format("%s: %dx %s%s", verb, step.count,
                ShortenName(GetRecipeDisplayName(step.recipeID), 22), more))
            batchBtn:Enable()
        else
            batchBtn:SetText("Out of materials (right-click to cancel)")
            batchBtn:Enable()
        end
    else
        batchBtn:SetText(string.format("Batch Craft Ticked Tabs (%d)", #checkedTabs))
        if #checkedTabs > 0 and not crafting then batchBtn:Enable() else batchBtn:Disable() end
    end

    batchBtn:SetScript("OnClick", function(_, mouseButton)
        peekFrame.qtyBox:ClearFocus()
        if isRun then
            if mouseButton == "RightButton" then
                EndCraftRun("Crafting run cancelled.")
            else
                ExecuteNextCraftStep()
            end
        elseif mouseButton == "LeftButton" then
            local targets = {}
            for _, tab in ipairs(checkedTabs) do
                table.insert(targets, { recipeID = tab.recipeID, count = tab.craftQty or 1 })
            end
            StartCraftRun(targets)
        end
        RefreshCraftRunDisplays()
    end)

    batchBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if isRun and craftRun then
            GameTooltip:AddLine("Crafting Run: Next Step", 1, 0.82, 0)
            local targetIDs = {}
            for _, t in ipairs(craftRun.targets) do
                GameTooltip:AddLine(string.format("%s: %d left", GetRecipeDisplayName(t.recipeID), t.remaining), 0.6, 0.85, 1)
                if t.remaining > 0 then targetIDs[t.recipeID] = true end
            end
            GameTooltip:AddLine(" ")
            AddPlanToTooltip(steps or {}, targetIDs)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Left-click: next step (WoW needs a click to start each craft). Right-click: cancel.", 0.6, 0.6, 0.6, true)
        else
            GameTooltip:AddLine("Batch Craft", 1, 0.82, 0)
            GameTooltip:AddLine("Tick the box on any tabs to craft each of them at its own quantity, prepping missing reagents first.", 0.85, 0.85, 0.85, true)
            GameTooltip:AddLine("Tabs share your materials in tab order, left to right.", 0.85, 0.85, 0.85, true)
            if #checkedTabs > 0 then
                GameTooltip:AddLine(" ")
                for _, tab in ipairs(checkedTabs) do
                    GameTooltip:AddLine(string.format("%dx %s", tab.craftQty or 1, tab.name or GetRecipeDisplayName(tab.recipeID)), 1, 1, 1)
                end
            end
        end
        GameTooltip:Show()
    end)
    batchBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
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

    -- [Prep] button to the right of the reagent, shown when you're short of it and can craft it.
    -- Sits past the reagent's name and Blizzard's provided-by checkmark, before a second reagent column.
    local prep = CreateFrame("Button", nil, ind, "BackdropTemplate")
    prep:SetSize(34, 18)
    prep:SetPoint("LEFT", btn, "LEFT", 188, 0)
    prep:SetFrameLevel(ind:GetFrameLevel() + 3)
    prep:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 7,
        insets = { left = 1, right = 1, top = 1, bottom = 1 }
    })
    prep:SetBackdropColor(0.20, 0.13, 0.02, 0.96)
    prep:SetBackdropBorderColor(1.0, 0.82, 0.0, 1.0)
    local prepHighlight = prep:CreateTexture(nil, "HIGHLIGHT")
    prepHighlight:SetPoint("TOPLEFT", 1, -1)
    prepHighlight:SetPoint("BOTTOMRIGHT", -1, 1)
    prepHighlight:SetColorTexture(1.0, 0.85, 0.2, 0.25)
    local prepLabel = prep:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if fontPath then
        prepLabel:SetFont(fontPath, 10, "OUTLINE")
    end
    prepLabel:SetPoint("CENTER", prep, "CENTER", 0, 0)
    prep.label = prepLabel
    prep.reciPeekNoPeek = true  -- clicking it must not also open the reagent in the side window
    prep:Hide()
    ind.prepBtn = prep

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

-- False while viewing someone else's profession (linked / guild) or an NPC's: ReciPeek can't craft there
local function IsViewingOwnProfession()
    if not C_TradeSkillUI then return false end
    if C_TradeSkillUI.IsTradeSkillLinked and C_TradeSkillUI.IsTradeSkillLinked() then return false end
    if C_TradeSkillUI.IsTradeSkillGuild and C_TradeSkillUI.IsTradeSkillGuild() then return false end
    if C_TradeSkillUI.IsNPCCrafting and C_TradeSkillUI.IsNPCCrafting() then return false end
    return true
end

-- Quantity in Blizzard's own craft amount box on the Recipes tab
local function GetMainCraftQuantity()
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local box = page and page.CreateMultipleInputBox
    local value = box and box.GetValue and box:GetValue()
    return math.max(1, tonumber(value) or 1)
end

-- Returns the reagent slot's schematic (quantity required and accepted reagent variants)
local function GetSlotSchematic(slot)
    if slot.GetReagentSlotSchematic then
        local ok, slotSchem = pcall(slot.GetReagentSlotSchematic, slot)
        if ok and type(slotSchem) == "table" then return slotSchem end
    end
    return slot.reagentSlotSchematic
end

-- How many crafts of subRecipeID would cover this slot's shortfall at `qty` crafts of the form's recipe
-- (customer-provided reagents count as on hand). Returns crafts possible, crafts needed and shortfall.
local function GetSlotPrepCrafts(slot, subRecipeID, qty, customer, ctx)
    local slotSchem = GetSlotSchematic(slot)
    if not slotSchem or not slotSchem.reagents or (slotSchem.quantityRequired or 0) <= 0 then return 0, 0, 0 end
    local have = 0
    for _, r in ipairs(slotSchem.reagents) do
        if r.itemID then
            have = have + GetPlayerReagentCount(r.itemID) + (customer[r.itemID] or 0)
        end
    end
    local shortfall = slotSchem.quantityRequired * qty - have
    if shortfall <= 0 then return 0, 0, 0 end
    local subReq = GetRecipeRequirements(subRecipeID)
    local yield = (subReq and subReq.yield) or 1
    local wanted = math.ceil(shortfall / yield)
    return GetMaxPlannableCrafts(subRecipeID, wanted, {}, ctx), wanted, shortfall
end

-- Applies visual indicators to craftable reagent slots in a SchematicForm
local function ApplyIndicatorsToSchematicForm(form)
    if not form or not form:IsShown() then return end

    -- Recipes tab: Blizzard's quantity box. Crafting order: one craft, with the customer's reagents counted.
    local qty, customer = 1, {}
    local craftForm = ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
    if form == craftForm then
        qty = GetMainCraftQuantity()
    else
        local orderView = ProfessionsFrame.OrdersPage and ProfessionsFrame.OrdersPage.OrderView
        if orderView and type(orderView.order) == "table" then
            customer = ExtractCustomerProvidedMap(orderView.order)
        end
    end
    local ctx = NewMaterialsFilterContext()
    local busy = (craftRun ~= nil) or IsPlayerCrafting()
    local ownProfession = IsViewingOwnProfession()

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

            -- Short of this reagent and able to make it (sub-crafts included): offer [Prep N]
            local prepCrafts, prepWanted, shortfall = 0, 0, 0
            if isLearned and ownProfession then
                prepCrafts, prepWanted, shortfall = GetSlotPrepCrafts(slot, subRecipeID, qty, customer, ctx)
            end
            local prep = ind.prepBtn
            -- A run this slot started (prepping this reagent) keeps its button live to click through the steps
            local ownsRun = craftRun ~= nil and not craftRun.prepOnly and #craftRun.targets == 1
                and craftRun.targets[1].recipeID == subRecipeID and craftRun.targets[1].remaining > 0
            if prepCrafts > 0 or ownsRun then
                local subID, crafts, wanted, short, forQty = subRecipeID, prepCrafts, prepWanted, shortfall, qty
                prep.label:SetText("|cFFFFD100Prep|r")
                local enabled = ownsRun and not IsPlayerCrafting() or (not ownsRun and not busy)
                if enabled then prep:Enable(); prep:SetAlpha(1) else prep:Disable(); prep:SetAlpha(0.5) end

                prep:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                prep:SetScript("OnClick", function(_, mouseButton)
                    if ownsRun then
                        if mouseButton == "RightButton" then
                            EndCraftRun("Crafting run cancelled.")
                        else
                            ExecuteNextCraftStep()
                        end
                    elseif mouseButton == "LeftButton" then
                        StartCraftRun({ { recipeID = subID, count = crafts } })
                    end
                    RefreshCraftRunDisplays()
                end)
                prep:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if ownsRun then
                        local steps, step, verb = DescribeCraftRun()
                        GameTooltip:AddLine("Prepping " .. GetRecipeDisplayName(subID), 1, 0.82, 0)
                        if step then
                            GameTooltip:AddLine(string.format("Next: %s %dx %s", verb, step.count, GetRecipeDisplayName(step.recipeID)), 1, 1, 1)
                        end
                        GameTooltip:AddLine("Left-click: next step. Right-click: cancel.", 0.6, 0.6, 0.6, true)
                    else
                        GameTooltip:AddLine("Prep " .. GetRecipeDisplayName(subID), 1, 0.82, 0)
                        GameTooltip:AddLine(string.format("You're %d short for %d craft%s. Crafts %dx %s.",
                            short, forQty, forQty == 1 and "" or "s", crafts, GetRecipeDisplayName(subID)), 0.85, 0.85, 0.85, true)
                        if crafts < wanted then
                            GameTooltip:AddLine(string.format("Materials only cover %d of the %d crafts needed.", crafts, wanted), 1, 0.4, 0.4, true)
                        end
                        GameTooltip:AddLine("If it needs its own reagents prepped first, keep clicking Prep to work through them.", 0.6, 0.6, 0.6, true)
                    end
                    GameTooltip:Show()
                end)
                prep:SetScript("OnLeave", function() GameTooltip:Hide() end)
                prep:Show()
            else
                prep:Hide()
            end

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

-- [Prep] button beside Blizzard's Create All on the Recipes tab. Preps every missing reagent for
-- the quantity in Blizzard's box, one click per step, then leaves the final craft to Blizzard's Create
-- (so its reagent quality, finishing reagents and concentration choices apply). While any crafting
-- run is active it shows and advances that run's next step instead.
local function UpdateMainPrepButton()
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    if not page or not page.CreateAllButton then return end

    local btn = page.reciPeekPrepBtn
    if not btn then
        btn = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
        btn:SetSize(72, 22)
        btn:SetPoint("RIGHT", page.CreateAllButton, "LEFT", -8, 0)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        page.reciPeekPrepBtn = btn
    end

    local form = page.SchematicForm
    local recipeID = page:IsShown() and form and form:IsShown() and GetRecipeIDFromForm(form)
    if not recipeID or not IsViewingOwnProfession() or not IsRecipeLearned(recipeID) then
        btn:Hide()
        return
    end
    btn:Show()

    -- A prep-only run belongs to the recipe it was started on; switching recipes drops it
    if craftRun and craftRun.prepOnly and craftRun.targets[1].recipeID ~= recipeID then
        craftRun = nil
    end

    local crafting = IsPlayerCrafting()
    local steps, step, verb
    if craftRun then
        steps, step, verb = DescribeCraftRun()  -- may end the run, which falls through to idle below
    end

    -- The button just says "Prep" (or "Craft" when a side-window batch reaches a target); the tooltip says what
    local isRun = craftRun ~= nil
    local startCount = 0
    local status  -- tooltip line describing the current state
    if isRun then
        btn:SetText(verb or "Prep")
        if crafting then
            status = "Crafting..."
            btn:Disable()
        elseif step then
            status = string.format("Next: %s %dx %s", verb, step.count, GetRecipeDisplayName(step.recipeID))
            btn:Enable()
        else
            status = "|cFFFF6666Out of materials. Right-click to cancel.|r"
            btn:Enable()
        end
    else
        btn:SetText("Prep")
        local planned
        steps, planned = BuildCraftPlan({ { recipeID = recipeID, count = GetMainCraftQuantity() } })
        startCount = planned[1] or 0
        local prepSteps = math.max(0, #steps - 1)
        if #steps == 0 then
            status = "|cFFFF6666Not enough materials, even counting reagents you could craft.|r"
            btn:Disable()
        elseif prepSteps == 0 then
            status = "|cFF00FF66Reagents ready. Nothing to prep.|r"
            btn:Disable()
        else
            status = string.format("Preps reagents for %dx (%d step%s).", startCount, prepSteps, prepSteps == 1 and "" or "s")
            if crafting then btn:Disable() else btn:Enable() end
        end
    end

    btn:SetScript("OnClick", function(_, mouseButton)
        if isRun then
            if mouseButton == "RightButton" then
                EndCraftRun("Crafting run cancelled.")
            else
                ExecuteNextCraftStep()
            end
        elseif mouseButton == "LeftButton" and startCount > 0 then
            StartCraftRun({ { recipeID = recipeID, count = startCount } }, true)
        end
        RefreshCraftRunDisplays()
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local targetIDs = {}
        if isRun and craftRun then
            GameTooltip:AddLine("Crafting Run: Next Step", 1, 0.82, 0)
            for _, t in ipairs(craftRun.targets) do
                if t.remaining > 0 then targetIDs[t.recipeID] = true end
            end
        else
            GameTooltip:AddLine("Prep Reagents", 1, 0.82, 0)
            GameTooltip:AddLine("Crafts every reagent you're missing for the amount in the box, from base materials you have. Then click Create as usual.", 0.85, 0.85, 0.85, true)
            targetIDs[recipeID] = true
        end
        GameTooltip:AddLine(status, 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        AddPlanToTooltip(steps or {}, targetIDs)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Each click runs one step (WoW needs a click to start each craft).", 0.6, 0.6, 0.6, true)
        if isRun then
            GameTooltip:AddLine("Right-click to cancel.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
end

-- Updates reagent slot indicators on the active SchematicForm (Recipes or Crafting Orders)
UpdateMainSchematicFormIndicators = function()
    UpdateMainPrepButton()

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
        -- Main side panel frame (width: 336, height: 474)
        local f = CreateFrame("Frame", "ReciPeekSideFrame", ProfessionsFrame, "BackdropTemplate")
        f:SetSize(336, 474)
        -- Default spot: just right of the Professions window, bottom edges aligned
        f:SetPoint("BOTTOMLEFT", ProfessionsFrame, "BOTTOMRIGHT", 6, 0)
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

        -- Batch row above the craft row (also shows / advances any active crafting run)
        local batchBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        batchBtn:SetHeight(24)
        batchBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 42)
        batchBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 42)
        batchBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        batchBtn:SetText("Batch Craft Ticked Tabs (0)")
        f.batchBtn = batchBtn

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
            -- "Include in Batch" checkbox
            btn.batchCheck = CreateFrame("CheckButton", nil, btn, "UICheckButtonTemplate")
            btn.batchCheck:SetSize(18, 18)
            btn.batchCheck:SetPoint("LEFT", btn, "LEFT", 1, 0)

            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.label:SetPoint("LEFT", btn.batchCheck, "RIGHT", 0, 0)

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
        local btnWidth = math.min(170, btn.label:GetStringWidth() + 40)
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

        btn.batchCheck:SetChecked(tab.batch and true or false)
        btn.batchCheck:SetScript("OnClick", function(self)
            tab.batch = self:GetChecked() and true or false
            RefreshPeekWindow()
        end)
        btn.batchCheck:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Include in Batch", 1, 0.82, 0)
            GameTooltip:AddLine("Ticked tabs are crafted together by the Batch button, each at its own quantity.", 0.85, 0.85, 0.85, true)
            GameTooltip:Show()
        end)
        btn.batchCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
    EnsureProfessionItemMap()
    local masterMax = GetMaxPlannableCrafts(recipeID, MASTER_CRAFT_MAX_QTY, {}, NewMaterialsFilterContext())
    local subCraftNote = ""
    if masterMax > maxCraftable then
        subCraftNote = string.format("  •  |cFF33E0E6w/ Subs: %d|r", masterMax)
    end
    peekFrame.rStatus:SetText(string.format("%sIn Bags: |cFFFFFFFF%d|r  •  Can Craft: %s%d|r%s", learnedStatus, ownedOutput, craftableColor, maxCraftable, subCraftNote))

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

            -- [Prep N] button: crafts just this reagent's shortfall
            row.prepBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.prepBtn:SetSize(58, 18)
            row.prepBtn:SetPoint("RIGHT", row, "RIGHT", -62, 0)
            row.prepBtn:SetNormalFontObject("GameFontNormalSmall")
            row.prepBtn:SetHighlightFontObject("GameFontHighlightSmall")
            row.prepBtn:SetDisabledFontObject("GameFontDisableSmall")
            row.prepBtn:Hide()

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
    -- The quantity can go up to what prepping covers (so the Prep buttons show); Craft / Craft All stay direct-only
    local qtyLimit = math.max(maxCraftable, masterMax)
    local maxAllowedQty = (qtyLimit > 0) and qtyLimit or 999
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

    -- 4. Batch row
    UpdateCraftRunControls()

    -- 5. Per-reagent [Prep N] buttons: craft just the shortfall of one reagent for the chosen quantity
    local prepCtx = NewMaterialsFilterContext()
    local busy = (craftRun ~= nil) or IsPlayerCrafting()
    for i, rg in ipairs(reagents) do
        local row = peekFrame.reagentRows[i]
        local shortfall = (rg.required * currentQty) - rg.owned
        local wanted, prepCrafts, yield = 0, 0, 1
        if rg.subRecipeID and shortfall > 0 then
            local subReq = GetRecipeRequirements(rg.subRecipeID)
            yield = (subReq and subReq.yield) or 1
            wanted = math.ceil(shortfall / yield)
            prepCrafts = GetMaxPlannableCrafts(rg.subRecipeID, wanted, {}, prepCtx)
        end

        if prepCrafts > 0 then
            row.prepBtn:SetText("Prep " .. prepCrafts)
            if busy then row.prepBtn:Disable() else row.prepBtn:Enable() end
            row.prepBtn:SetScript("OnClick", function()
                peekFrame.qtyBox:ClearFocus()
                StartCraftRun({ { recipeID = rg.subRecipeID, count = prepCrafts } })
                RefreshCraftRunDisplays()
            end)
            row.prepBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine("Prep " .. rg.name, 1, 0.82, 0)
                GameTooltip:AddLine(string.format("You're %d short for %d craft%s. Crafts %dx %s (makes at least %d).",
                    shortfall, currentQty, currentQty == 1 and "" or "s", prepCrafts,
                    GetRecipeDisplayName(rg.subRecipeID), prepCrafts * yield), 0.85, 0.85, 0.85, true)
                if prepCrafts < wanted then
                    GameTooltip:AddLine(string.format("Materials only cover %d of the %d crafts needed.", prepCrafts, wanted), 1, 0.4, 0.4, true)
                end
                GameTooltip:AddLine("If this reagent needs its own reagents prepped first, the main button walks through those steps.", 0.6, 0.6, 0.6, true)
                GameTooltip:Show()
            end)
            row.prepBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.prepBtn:Show()
            row.nameText:SetPoint("RIGHT", row, "RIGHT", -124, 0)
        else
            row.prepBtn:Hide()
            row.nameText:SetPoint("RIGHT", row, "RIGHT", -68, 0)
        end
    end
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
local isRecipeListHooked = false
local isFilterDropdownHooked = false
local isDefaultFiltersHooked = false
local isOrdersShowHooked = false
local isOrdersFilterDropdownHooked = false

-- Makes a filter dropdown show its reset (X) button while one of our filters is active
local function HookFilterDropdownResetState(dropdown, isOurFilterActive)
    local blizzardIsDefault = dropdown.isDefaultCallback
    dropdown:SetIsDefaultCallback(function()
        if isOurFilterActive() then return false end
        if blizzardIsDefault then return blizzardIsDefault() end
        return true
    end)
end

-- Starting filters, applied the first time your own profession window opens each session:
-- ReciPeek's Have Materials filter on (Recipes and Crafting Orders tabs), Learned on, Unlearned off.
-- Blizzard's reset (X) still clears them back to showing everything.
local sessionDefaultFiltersApplied = false
local function ApplySessionDefaultFilters()
    if sessionDefaultFiltersApplied or not C_TradeSkillUI then return end
    -- Skip linked / guild / NPC profession views: "learned" and materials there aren't yours
    if (C_TradeSkillUI.IsTradeSkillLinked and C_TradeSkillUI.IsTradeSkillLinked())
        or (C_TradeSkillUI.IsTradeSkillGuild and C_TradeSkillUI.IsTradeSkillGuild())
        or (C_TradeSkillUI.IsNPCCrafting and C_TradeSkillUI.IsNPCCrafting()) then
        return
    end
    sessionDefaultFiltersApplied = true

    if C_TradeSkillUI.SetShowLearned then C_TradeSkillUI.SetShowLearned(true) end
    if C_TradeSkillUI.SetShowUnlearned then C_TradeSkillUI.SetShowUnlearned(false) end
    SetMaterialsFilterEnabled(true)
    SetOrdersFilterEnabled(true)
end

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
            -- After Blizzard has finished setting up its own filters for the window
            C_Timer.After(0.2, ApplySessionDefaultFilters)
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

        -- Prep counts follow Blizzard's craft amount box
        local qtyBox = ProfessionsFrame.CraftingPage.CreateMultipleInputBox
        if qtyBox and qtyBox.HasScript and qtyBox:HasScript("OnTextChanged") then
            local pending = false
            qtyBox:HookScript("OnTextChanged", function()
                if pending then return end
                pending = true
                C_Timer.After(0.15, function()
                    pending = false
                    UpdateMainSchematicFormIndicators()
                end)
            end)
        end
    end

    -- Recipes tab list: filter the tree right after Blizzard builds it (before it picks a selection)
    local craftingPage = ProfessionsFrame.CraftingPage
    local recipeList = craftingPage and craftingPage.RecipeList
    if recipeList and recipeList.ScrollBox and recipeList.ScrollBox.SetDataProvider and not isRecipeListHooked then
        isRecipeListHooked = true
        hooksecurefunc(recipeList.ScrollBox, "SetDataProvider", function(_, dataProvider)
            ApplyMaterialsFilterToDataProvider(dataProvider)
        end)
        craftingPage:HookScript("OnShow", function()
            C_Timer.After(0.1, function()
                if listBuiltWithFilter ~= materialsFilterEnabled then
                    -- Filter was toggled (e.g. via /rp filter) while the Recipes tab was hidden
                    RefreshNativeRecipeList()
                else
                    ScheduleMaterialsFilterRecheck(0)
                end
            end)
        end)
    end

    -- Show the filter dropdown's reset (X) button while our filter is active
    local filterDropdown = recipeList and recipeList.FilterDropdown
    if filterDropdown and filterDropdown.SetIsDefaultCallback and not isFilterDropdownHooked then
        isFilterDropdownHooked = true
        HookFilterDropdownResetState(filterDropdown, function() return materialsFilterEnabled end)
    end

    -- Blizzard's filter reset (from either tab) also clears ours
    if Professions and Professions.SetDefaultFilters and not isDefaultFiltersHooked then
        isDefaultFiltersHooked = true
        hooksecurefunc(Professions, "SetDefaultFilters", function()
            SetMaterialsFilterEnabled(false)
            SetOrdersFilterEnabled(false)
        end)
    end

    local orderForm = GetOrderSchematicForm()
    if orderForm and not isOrderFormHooked and orderForm.Init then
        isOrderFormHooked = true
        hooksecurefunc(orderForm, "Init", function()
            C_Timer.After(0.02, UpdateMainSchematicFormIndicators)
        end)
    end

    local ordersPage = ProfessionsFrame.OrdersPage
    local browseFrame = ordersPage and ordersPage.BrowseFrame
    local orderList = browseFrame and browseFrame.OrderList
    local scrollBox = orderList and orderList.ScrollBox

    -- Crafting Orders list: filter the rows right after Blizzard fills them (first page and each extra page)
    if ordersPage and ordersPage.ShowGeneric and browseFrame and not isOrdersShowHooked then
        isOrdersShowHooked = true
        hooksecurefunc(ordersPage, "ShowGeneric", function(_, orders, _, offset)
            ApplyOrdersFilterToList(orders, offset)
        end)
        browseFrame:HookScript("OnShow", function()
            C_Timer.After(0.1, function()
                if ordersListBuiltWithFilter ~= ordersFilterEnabled then
                    -- Filter was toggled (e.g. via /rp orders) while the order list was hidden
                    RefreshNativeOrdersList()
                else
                    ScheduleOrdersFilterRecheck(0)
                end
            end)
        end)
    end

    local ordersFilterDropdown = browseFrame and browseFrame.RecipeList and browseFrame.RecipeList.FilterDropdown
    if ordersFilterDropdown and ordersFilterDropdown.SetIsDefaultCallback and not isOrdersFilterDropdownHooked then
        isOrdersFilterDropdownHooked = true
        HookFilterDropdownResetState(ordersFilterDropdown, function() return ordersFilterEnabled end)
    end

    if scrollBox and not isOrderListHooked then
        isOrderListHooked = true

        -- Blizzard fetches the next page based on rows it added, not rows still shown, so check again on scroll
        if scrollBox.RegisterCallback and ScrollBoxListMixin and ScrollBoxListMixin.Event and ScrollBoxListMixin.Event.OnDataRangeChanged then
            scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnDataRangeChanged, function()
                if ordersFilterEnabled then C_Timer.After(0, MaybeRequestMoreOrders) end
            end, ordersRangeCallbackOwner)
        end

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
eventFrame:RegisterEvent("UPDATE_TRADESKILL_CAST_STOPPED")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            ReciPeekDB = ReciPeekDB or {}
            ReciPeekDB.filterIncludeBank = nil  -- old "Include Bank" setting (removed); drop the stale saved value
            local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
            print("|cFF00CCFFReci|r|cFFFFD100Peek|r " .. (version and ("v" .. version .. " ") or "") .. "loaded! Craftable reagents and Crafting Orders with combined materials on hand are highlighted in green.")
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
        if event == "BAG_UPDATE_DELAYED" then
            ScheduleMaterialsFilterRecheck()
            ScheduleOrdersFilterRecheck()
        end
    elseif event == "UPDATE_TRADESKILL_CAST_STOPPED" then
        ScheduleMaterialsFilterRecheck(0.5)
        ScheduleOrdersFilterRecheck(0.5)
        -- Re-enable the Prep / Batch buttons once the craft (or repeat) ends
        if ProfessionsFrame and ProfessionsFrame:IsShown() then
            RefreshCraftRunDisplays(0.3)
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg3 = spellID; a recipe's craft spell is its recipeID
        if craftRun then
            OnCraftCastSucceeded(arg3)
            RefreshCraftRunDisplays(0.1)
        end
    elseif event == "GLOBAL_MOUSE_DOWN" then
        if arg1 ~= "LeftButton" then return end
        if IsShiftKeyDown() then return end -- Preserve Shift + Left-Click for chat item linking
        if not ProfessionsFrame or not ProfessionsFrame:IsShown() then return end

        local focus = GetMouseFoci and GetMouseFoci()[1] or (GetMouseFocus and GetMouseFocus())
        if not focus or focus.reciPeekNoPeek or not IsInsideSchematicForm(focus) then return end

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

-- Filter Menu Hook: adds the ReciPeek materials filter to the native Filter dropdown of the
-- Recipes tab and of the Crafting Orders tab (both use the same menu)
if Menu and Menu.ModifyMenu then
    Menu.ModifyMenu("MENU_PROFESSIONS_FILTER", function(owner, rootDescription)
        local craftingPage = GetCraftingPage()
        local recipesDropdown = craftingPage and craftingPage.RecipeList and craftingPage.RecipeList.FilterDropdown
        local ordersPage = GetOrdersPage()
        local ordersBrowse = ordersPage and ordersPage.BrowseFrame
        local ordersDropdown = ordersBrowse and ordersBrowse.RecipeList and ordersBrowse.RecipeList.FilterDropdown

        local label = "Have Materials (incl. Sub-Crafts)"
        local isChecked, onToggle, tooltipLines
        if recipesDropdown and owner == recipesDropdown then
            isChecked = function() return materialsFilterEnabled end
            onToggle = function() SetMaterialsFilterEnabled(not materialsFilterEnabled) end
            tooltipLines = {
                "Only show learned recipes you can craft right now, counting reagents you could craft first from the base materials you have.",
                "All reagents share one pool, so a recipe needing two crafted reagents is hidden if you only have materials for one.",
                "|cFF888888Counts your bags, reagent bag, bank and Warband bank, like crafting does. Also toggled with /rp filter.|r",
            }
        elseif ordersDropdown and owner == ordersDropdown then
            isChecked = function() return ordersFilterEnabled end
            onToggle = function() SetOrdersFilterEnabled(not ordersFilterEnabled) end
            tooltipLines = {
                "Only show orders you can fill right now with the customer's reagents plus your own, counting reagents you could craft first from the base materials you have.",
                "|cFF00FF66Green|r rows are ready now. |cFF33E0E6Teal|r rows need some reagents crafted first.",
                "Public orders grouped by recipe stay listed; open one to see only the orders you can fill.",
                "|cFF888888Counts your bags, reagent bag, bank and Warband bank, like crafting does. Also toggled with /rp orders.|r",
            }
        else
            return
        end

        local checkbox
        if MenuUtil and MenuUtil.CreateTitle and MenuUtil.CreateCheckbox and MenuUtil.CreateDivider and rootDescription.Insert then
            -- Pin to the top of the menu: [ReciPeek] [filter] [divider] then Blizzard's filters
            rootDescription:Insert(MenuUtil.CreateTitle("ReciPeek"), 1)
            checkbox = rootDescription:Insert(MenuUtil.CreateCheckbox(label, isChecked, onToggle), 2)
            rootDescription:Insert(MenuUtil.CreateDivider(), 3)
        else
            -- Fallback: append to the bottom
            rootDescription:CreateDivider()
            rootDescription:CreateTitle("ReciPeek")
            checkbox = rootDescription:CreateCheckbox(label, isChecked, onToggle)
        end

        if checkbox and checkbox.SetTooltip then
            checkbox:SetTooltip(function(tooltip)
                GameTooltip_SetTitle(tooltip, label)
                for _, line in ipairs(tooltipLines) do
                    GameTooltip_AddNormalLine(tooltip, line)
                end
            end)
        end
    end)
end

-- Diagnostic for /rp why on the Crafting Orders tab: explains the filter / highlight verdict for the open order
local function PrintOrderDiagnostic(order)
    local P = function(s) print("  " .. s) end
    local function ItemName(itemID)
        return (itemID and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or ("item " .. tostring(itemID))
    end

    local recipeID = order.spellID or order.recipeID
    local rInfo = recipeID and C_TradeSkillUI.GetRecipeInfo(recipeID)
    print(("|cFF00CCFFReciPeek why (order):|r %s  recipe=%s orderID=%s type=%s reagentState=%s learned=%s"):format(
        tostring(rInfo and rInfo.name), tostring(recipeID), tostring(order.orderID), tostring(order.orderType),
        tostring(order.reagentState), tostring(rInfo and rInfo.learned)))

    -- Filter state, and what the last filter pass decided for this order (if it was in the list)
    local listed = "not seen by the filter"
    for option, passed in pairs(lastOrdersFilterResults) do
        if option.orderID and option.orderID == order.orderID then
            listed = passed and "PASSED" or "FAILED (should have been hidden)"
        end
    end
    P(("filter on=%s  list built with filter=%s  last pass for this order: %s"):format(
        tostring(ordersFilterEnabled), tostring(ordersListBuiltWithFilter), listed))
    if lastOrdersFilterError then
        P("|cFFFF6666last filter error:|r " .. lastOrdersFilterError)
    end
    local scrollBox = GetOrdersScrollBox()
    local listProvider = scrollBox and scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if listProvider and listProvider.Enumerate then
        local inList = false
        for _, elem in listProvider:Enumerate() do
            if type(elem) == "table" and type(elem.option) == "table" and elem.option.orderID == order.orderID then
                inList = true
            end
        end
        P(("order list rows=%s  this order in list=%s"):format(
            tostring(listProvider.GetSize and listProvider:GetSize()), tostring(inList)))
    end

    -- Raw customer-provided reagents as the order reports them
    for _, r in ipairs(order.reagents or {}) do
        local info = r.reagentInfo or r.reagent or r
        local nested = info.reagent or r.reagent
        local itemID = (nested and nested.itemID) or info.itemID or r.itemID
        P(("customer gives: %s x%s  slotIndex=%s basic=%s source=%s"):format(ItemName(itemID),
            tostring(info.quantity or r.quantity), tostring(r.slotIndex), tostring(r.isBasicReagent), tostring(r.source)))
    end

    EnsureProfessionItemMap()
    local ctx = NewMaterialsFilterContext()
    local customer = ExtractCustomerProvidedMap(order)
    local req = recipeID and GetRecipeRequirements(recipeID)
    if not req then
        P("|cFFFF6666no requirements could be read for this recipe|r")
    else
        P(("requirements: %d slot(s) counted, salvage=%s evaluable=%s"):format(#req.slots, tostring(req.isSalvage), tostring(req.evaluable)))
        for _, slot in ipairs(req.slots) do
            local have, given = 0, 0
            for _, r in ipairs(slot.reagents) do
                have = have + GetFilterReagentCount(ctx, r)
                given = given + ((r.itemID and customer[r.itemID]) or 0)
            end
            local subRecipeID = FindLearnedSubRecipe(slot.reagents)
            P(("%s: need %d  you have %d  customer gives %d  sub-craft recipe=%s"):format(
                ItemName(slot.reagents[1].itemID), slot.quantity, have, given, tostring(subRecipeID)))
        end
    end

    -- Slots on the recipe that the check skips (optional / finishing reagents)
    local schematic = recipeID and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    for _, slot in ipairs((schematic and schematic.reagentSlotSchematics) or {}) do
        local first = slot.reagents and slot.reagents[1]
        P(("  schematic slot: %s  type=%s required=%s need=%s variants=%d"):format(
            first and ItemName(first.itemID) or "?", tostring(slot.reagentType), tostring(slot.required),
            tostring(slot.quantityRequired), slot.reagents and #slot.reagents or 0))
    end

    local verdict = EvaluateOrderReadiness(order, ctx)
    P("Verdict: " .. ((verdict == "direct" and "|cFF00FF66ready now|r") or (verdict == "subcraft" and "|cFF33E0E6ready after sub-crafts|r") or "|cFFFF6666not ready (filter hides it)|r"))
end

-- Slash Command Handler (/rp or /recipeek)
SlashCmdList["RECIPEEK"] = function(msg)
    local cmd = strtrim(string.lower(msg or ""))
    if cmd == "filter" then
        SetMaterialsFilterEnabled(not materialsFilterEnabled)
        print("|cFF00CCFFReciPeek:|r Have Materials (incl. Sub-Crafts) filter " .. (materialsFilterEnabled and "|cFF00FF66enabled|r" or "|cFFFF6666disabled|r") .. ".")
        return
    elseif cmd == "orders" then
        SetOrdersFilterEnabled(not ordersFilterEnabled)
        print("|cFF00CCFFReciPeek:|r Crafting Orders Have Materials filter " .. (ordersFilterEnabled and "|cFF00FF66enabled|r" or "|cFFFF6666disabled|r") .. ".")
        return
    elseif cmd == "why" then
        -- Diagnostic: on an open crafting order, explain the Orders filter verdict for it
        local ordersPage = GetOrdersPage()
        local orderView = ordersPage and ordersPage.OrderView
        if orderView and orderView:IsVisible() and type(orderView.order) == "table" then
            PrintOrderDiagnostic(orderView.order)
            return
        end

        -- Diagnostic: explains the Have Materials filter verdict for the recipe currently displayed
        local recipeID = GetCurrentDisplayedRecipeID()
        local info = recipeID and C_TradeSkillUI.GetRecipeInfo(recipeID)
        if not info then
            print("|cFF00CCFFReciPeek:|r Select a recipe in the Recipes tab first.")
            return
        end
        EnsureProfessionItemMap()
        print(("|cFF00CCFFReciPeek why:|r %s (id %d) learned=%s numAvailable=%s"):format(
            tostring(info.name), recipeID, tostring(info.learned), tostring(info.numAvailable)))
        local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
        for _, slot in ipairs((schematic and schematic.reagentSlotSchematics) or {}) do
            local have = 0
            for _, r in ipairs(slot.reagents or {}) do
                if r.itemID and r.itemID > 0 then
                    have = have + GetPlayerReagentCount(r.itemID)
                end
            end
            local first = slot.reagents and slot.reagents[1]
            local name = first and first.itemID and C_Item.GetItemNameByID(first.itemID) or (first and first.currencyID and ("currency " .. first.currencyID)) or "?"
            print(("  %s  type=%s required=%s need=%s  have=%d"):format(
                name, tostring(slot.reagentType), tostring(slot.required), tostring(slot.quantityRequired), have))
        end
        local ctx = NewMaterialsFilterContext()
        print("  Filter result: " .. (RecipePassesMaterialsFilter(info, ctx) and "|cFF00FF66shown|r" or "|cFFFF6666hidden|r"))
        return
    end

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