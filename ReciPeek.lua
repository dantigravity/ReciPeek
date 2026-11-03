-- ReciPeek.lua (v1.0.0 - Tabbed Sub-Reagent Peek Window, 1-Click Sub-Crafting & Recipe Jump by Dantigravity)
local ADDON_NAME = "ReciPeek"

SLASH_RECIPEEK1 = "/rp"
SLASH_RECIPEEK2 = "/recipeek"

-- Maps outputItemID -> recipeID for the currently open profession
local itemToRecipeMap = {}
local recipeNameCache = {}

-- Open tabs in the ReciPeek side window: list of { recipeID = number, name = string, icon = number }
local openTabs = {}
local activeTabIndex = 1
local peekFrame = nil

-- Helper: Extracts a numeric itemID from an itemLink or number
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

-- Returns total count of an item in player's bags + reagent bag + Warband/character bank
local function GetPlayerReagentCount(itemID)
    if not itemID then return 0 end
    if C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(itemID, true, false, true, true) or 0
    elseif GetItemCount then
        return GetItemCount(itemID, true) or 0
    end
    return 0
end

-- Scans all recipes in the currently open profession and maps every crafted outputItemID (and quality IDs) to its recipeID
local function RebuildProfessionItemMap()
    wipe(itemToRecipeMap)
    wipe(recipeNameCache)

    if not C_TradeSkillUI or not C_TradeSkillUI.GetAllRecipeIDs then return end
    local allRecipes = C_TradeSkillUI.GetAllRecipeIDs()
    if not allRecipes then return end

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

-- Returns the currently displayed recipeID in the main ProfessionsFrame schematic panel
local function GetCurrentDisplayedRecipeID()
    if not ProfessionsFrame or not ProfessionsFrame.CraftingPage then return nil end
    local form = ProfessionsFrame.CraftingPage.SchematicForm
    if form then
        if form.GetRecipeInfo then
            local info = form:GetRecipeInfo()
            if info and info.recipeID then return info.recipeID end
        end
        if form.currentRecipeInfo and form.currentRecipeInfo.recipeID then
            return form.currentRecipeInfo.recipeID
        end
    end
    return nil
end

-- Resolves whether an itemID is crafted by a recipe in the current profession
local function GetCraftableRecipeForItemID(itemID, allowSameAsMain)
    if not itemID then return nil end
    if not next(itemToRecipeMap) then
        RebuildProfessionItemMap()
    end
    local targetRecipeID = itemToRecipeMap[itemID]
    if not targetRecipeID then return nil end
    if not allowSameAsMain then
        local currentRecipeID = GetCurrentDisplayedRecipeID()
        if targetRecipeID == currentRecipeID then return nil end
    end
    return targetRecipeID
end

-- Jumps the main Blizzard Professions window directly to targetRecipeID
local function JumpMainWindowToRecipe(targetRecipeID)
    if not targetRecipeID then return end

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

-- Calculates all required reagents for a recipeID and how many times the player can craft it right now
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

            -- Sum across all quality tiers if this reagent has Bronze/Silver/Gold variants
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

            table.insert(reagentsList, {
                itemID = primaryItemID,
                name = itemName,
                icon = itemIcon,
                required = requiredQty,
                owned = totalOwned,
                subRecipeID = subRecipeID,
            })
        end
    end

    if maxCraftable == 9999 then maxCraftable = 0 end
    return reagentsList, maxCraftable, schematic
end

-- Forward declaration for UI refresh
local RefreshPeekWindow

-- Opens or focuses a recipe tab inside the ReciPeek side window
local function OpenRecipeInPeekTab(recipeID)
    if not recipeID then return end

    -- Check if tab already exists
    for idx, tab in ipairs(openTabs) do
        if tab.recipeID == recipeID then
            activeTabIndex = idx
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
    })
    activeTabIndex = #openTabs
    RefreshPeekWindow()
end

-- Creates (if needed) and updates the ReciPeek tabbed side panel
RefreshPeekWindow = function()
    if not ProfessionsFrame or not ProfessionsFrame:IsShown() then
        if peekFrame then peekFrame:Hide() end
        return
    end

    if not peekFrame then
        local f = CreateFrame("Frame", "ReciPeekSideFrame", ProfessionsFrame, "BackdropTemplate")
        f:SetSize(330, 430)
        f:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 6, 0)
        f:SetFrameStrata("HIGH")
        f:EnableMouse(true)
        f:SetMovable(true)
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

        -- Top Title Bar
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
        title:SetText("|cFF00CCFFReci|r|cFFFFD100Peek|r  |cFF888888• Recipe Inspector|r")

        -- "+ Pin Current" Button (pins the currently viewed main recipe as a tab)
        local pinBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        pinBtn:SetSize(82, 20)
        pinBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -32, -7)
        pinBtn:SetText("+ Pin Main")
        pinBtn:SetScript("OnClick", function()
            local curID = GetCurrentDisplayedRecipeID()
            if curID then OpenRecipeInPeekTab(curID) end
        end)

        -- Close "X" Button
        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        -- Tab Container Area
        local tabBar = CreateFrame("Frame", nil, f)
        tabBar:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -32)
        tabBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -32)
        tabBar:SetHeight(50)
        f.tabBar = tabBar
        f.tabButtons = {}

        -- Divider line below tabs
        local div = f:CreateTexture(nil, "ARTWORK")
        div:SetHeight(1)
        div:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -2)
        div:SetPoint("TOPRIGHT", tabBar, "BOTTOMRIGHT", 0, -2)
        div:SetColorTexture(0.25, 0.55, 0.80, 0.6)

        -- Active Recipe Header inside Peek Window
        local rIcon = f:CreateTexture(nil, "ARTWORK")
        rIcon:SetSize(36, 36)
        rIcon:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 6, -10)
        f.rIcon = rIcon

        local rTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        rTitle:SetPoint("TOPLEFT", rIcon, "TOPRIGHT", 10, -2)
        rTitle:SetPoint("RIGHT", f, "RIGHT", -12, 0)
        rTitle:SetJustifyH("LEFT")
        f.rTitle = rTitle

        local rStatus = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rStatus:SetPoint("TOPLEFT", rTitle, "BOTTOMLEFT", 0, -4)
        rStatus:SetJustifyH("LEFT")
        f.rStatus = rStatus

        -- Reagents Subheader
        local reagHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        reagHeader:SetPoint("TOPLEFT", rIcon, "BOTTOMLEFT", 0, -14)
        reagHeader:SetText("|cFFFFD100Required Materials (Click craftable rows to peek deeper):|r")

        -- Reagent Rows Pool
        f.reagentRows = {}

        -- Bottom Action Bar: [Craft 1] [Craft All] [Open Full Recipe ->]
        local craftOneBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        craftOneBtn:SetSize(84, 24)
        craftOneBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 12)
        craftOneBtn:SetText("Craft 1")
        f.craftOneBtn = craftOneBtn

        local craftAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        craftAllBtn:SetSize(98, 24)
        craftAllBtn:SetPoint("LEFT", craftOneBtn, "RIGHT", 6, 0)
        craftAllBtn:SetText("Craft All")
        f.craftAllBtn = craftAllBtn

        local jumpBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        jumpBtn:SetSize(118, 24)
        jumpBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 12)
        jumpBtn:SetText("Open Recipe ->")
        f.jumpBtn = jumpBtn

        peekFrame = f
    end

    if #openTabs == 0 then
        peekFrame:Hide()
        return
    end

    if activeTabIndex > #openTabs then activeTabIndex = #openTabs end
    if activeTabIndex < 1 then activeTabIndex = 1 end

    peekFrame:Show()

    -- 1. Render Tab Buttons (up to 2 rows of tabs so you can hold up to 6 recipes at once)
    for _, b in ipairs(peekFrame.tabButtons) do b:Hide() end

    local xOff = 0
    local yOff = 0
    local maxRowWidth = 310

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

            -- Tiny "x" button on each tab to close individual tabs
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
        local btnWidth = math.min(150, btn.label:GetStringWidth() + 26)
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
            activeTabIndex = idx
            RefreshPeekWindow()
        end)

        btn.closeTab:SetScript("OnClick", function()
            table.remove(openTabs, idx)
            if activeTabIndex >= idx and activeTabIndex > 1 then
                activeTabIndex = activeTabIndex - 1
            end
            RefreshPeekWindow()
        end)

        btn:Show()
    end

    -- 2. Render Active Tab's Recipe Details & Reagent List
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

    for _, row in ipairs(peekFrame.reagentRows) do row:Hide() end

    local rowStartY = -162
    for i, rg in ipairs(reagents) do
        local row = peekFrame.reagentRows[i]
        if not row then
            row = CreateFrame("Button", nil, peekFrame, "BackdropTemplate")
            row:SetHeight(28)
            row:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                insets = { left = 1, right = 1, top = 1, bottom = 1 }
            })

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(22, 22)
            row.icon:SetPoint("LEFT", row, "LEFT", 6, 0)

            row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
            row.nameText:SetPoint("RIGHT", row, "RIGHT", -90, 0)
            row.nameText:SetJustifyH("LEFT")

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
        row:SetBackdropColor(0.11, 0.13, 0.18, 0.85)
        row.icon:SetTexture(rg.icon)

        local subBadge = rg.subRecipeID and " |cFF00CCFF[Peek ->]|r" or ""
        row.nameText:SetText(rg.name .. subBadge)

        local countColor = hasEnough and "|cFF00FF66" or "|cFFFF5555"
        row.countText:SetText(string.format("%s%d / %d|r", countColor, rg.owned, rg.required))

        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if rg.itemID then
                GameTooltip:SetItemByID(rg.itemID)
                if rg.subRecipeID then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("|cFF00FF66<Left-Click to Peek Sub-Recipe in New Tab>|r")
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
                    OpenRecipeInPeekTab(rg.subRecipeID)
                end
            end
        end)

        row:Show()
    end

    -- 3. Wire Up Bottom Buttons ([Craft 1], [Craft All], [Open Recipe ->])
    local canCraftNow = (maxCraftable > 0) and (not rInfo or rInfo.learned ~= false)

    if canCraftNow then
        peekFrame.craftOneBtn:Enable()
        peekFrame.craftAllBtn:Enable()
        peekFrame.craftAllBtn:SetText("Craft All [" .. maxCraftable .. "]")
    else
        peekFrame.craftOneBtn:Disable()
        peekFrame.craftAllBtn:Disable()
        peekFrame.craftAllBtn:SetText("Craft All [0]")
    end

    peekFrame.craftOneBtn:SetScript("OnClick", function()
        if C_TradeSkillUI and C_TradeSkillUI.CraftRecipe then
            C_TradeSkillUI.CraftRecipe(recipeID, 1)
        end
    end)

    peekFrame.craftAllBtn:SetScript("OnClick", function()
        if maxCraftable > 0 and C_TradeSkillUI and C_TradeSkillUI.CraftRecipe then
            C_TradeSkillUI.CraftRecipe(recipeID, maxCraftable)
        end
    end)

    peekFrame.jumpBtn:SetScript("OnClick", function()
        JumpMainWindowToRecipe(recipeID)
    end)
end

-- Inspects a hovered or clicked UI frame inside Blizzard's SchematicForm to extract its reagent itemID
local function ExtractReagentItemIDFromFrame(frame)
    local cur = frame
    local depth = 0
    while cur and depth < 6 do
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

-- Checks if a frame is inside the main ProfessionsFrame SchematicForm reagent area
local function IsInsideSchematicForm(frame)
    if not ProfessionsFrame or not ProfessionsFrame:IsShown() then return false end
    local form = ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
    if not form or not form:IsShown() then return false end

    local cur = frame
    while cur do
        if cur == form then return true end
        cur = cur.GetParent and cur:GetParent() or nil
    end
    return false
end

-- Hooks ProfessionsFrame show/hide
local isProfessionsHooked = false
local function TryHookProfessionsFrame()
    if isProfessionsHooked or not ProfessionsFrame then return end
    isProfessionsHooked = true

    ProfessionsFrame:HookScript("OnShow", function()
        C_Timer.After(0.1, function()
            RebuildProfessionItemMap()
            if #openTabs > 0 then RefreshPeekWindow() end
        end)
    end)

    ProfessionsFrame:HookScript("OnHide", function()
        if peekFrame then peekFrame:Hide() end
    end)
end

-- Event Listener: Handles clicks on craftable sub-reagents & live bag count updates after crafting
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("GLOBAL_MOUSE_DOWN")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            print("|cFF00CCFFReci|r|cFFFFD100Peek|r v1.0.0 loaded! Left-Click any craftable reagent to Peek in a tab, or Ctrl + Left-Click to jump straight to its recipe.")
        elseif arg1 == "Blizzard_Professions" then
            TryHookProfessionsFrame()
        end
    elseif event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
        TryHookProfessionsFrame()
        RebuildProfessionItemMap()
        if peekFrame and peekFrame:IsShown() then RefreshPeekWindow() end
    elseif event == "BAG_UPDATE_DELAYED" then
        if peekFrame and peekFrame:IsShown() then
            RefreshPeekWindow()
        end
    elseif event == "GLOBAL_MOUSE_DOWN" then
        if arg1 ~= "LeftButton" then return end
        if IsShiftKeyDown() then return end -- Keep Shift + Left-Click for chat item linking
        if not ProfessionsFrame or not ProfessionsFrame:IsShown() then return end

        local focus = GetMouseFoci and GetMouseFoci()[1] or (GetMouseFocus and GetMouseFocus())
        if not focus or not IsInsideSchematicForm(focus) then return end

        local itemID = ExtractReagentItemIDFromFrame(focus)
        local targetRecipeID = GetCraftableRecipeForItemID(itemID, false)
        if targetRecipeID then
            if IsControlKeyDown() then
                JumpMainWindowToRecipe(targetRecipeID)
            else
                OpenRecipeInPeekTab(targetRecipeID)
            end
        end
    end
end)

if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_Professions") then
    TryHookProfessionsFrame()
end

-- Tooltip Prompt: Shows ReciPeek shortcuts when hovering over any craftable reagent inside the Profession window
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
                local rName = (rInfo and rInfo.name) or "Sub-Recipe"
                tooltip:AddLine(" ")
                tooltip:AddLine("|cFF00FF66<Left-Click to Peek Recipe: " .. rName .. ">|r")
                tooltip:AddLine("|cFF00CCFF<Ctrl + Left-Click to Jump to Recipe Page>|r")
            end
        end
    end)
end

-- Slash command (/rp or /recipeek) to toggle the Peek window or pin the current recipe
SlashCmdList["RECIPEEK"] = function()
    RebuildProfessionItemMap()
    local curID = GetCurrentDisplayedRecipeID()
    if curID then
        OpenRecipeInPeekTab(curID)
    else
        print("|cFF00CCFFReciPeek:|r Open a Profession window and click any craftable sub-reagent (or type /rp to pin the active recipe).")
    end
end