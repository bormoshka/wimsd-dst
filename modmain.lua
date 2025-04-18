PrefabFiles = {}

GLOBAL.require "mathutil"
GLOBAL.require "json"
local json = GLOBAL.json

local cooking = GLOBAL.require("cooking")
local ThePlayer = GLOBAL.ThePlayer
local TheInput = GLOBAL.TheInput
local TheSim = GLOBAL.TheSim
local Ents = GLOBAL.Ents
local TheWorld = GLOBAL.TheWorld
local FRAMES = 1 / 60

local useGamepad = GetModConfigData("use_gamepad", true)
local max_searched_containers = GetModConfigData("max_searched_containers") or 50
local search_radius = GetModConfigData("search_radius") or 30
local search_radius_for_tags = GetModConfigData("search_radius_for_tags") or 15
local highlight_multiplier = GetModConfigData("highlight_multiplier") or 1
local logLevel = GetModConfigData("LOG_LEVEL", 0)
if type(logLevel) ~= "number" then
    print("Invalid log level", logLevel)
    logLevel = 0
end
local WARN_LEVEL = 2
local INFO_LEVEL = 3
local DEBUG_LEVEL = 7
local TRACE_LEVEL = 12

local CONTROLLER_UPDATE_INTERVAL = 0.2 -- 200ms
-- Константы
local HIGHLIGHT_COLORS = {
    -- red, green, blue, alpha
    RED = { 0.4 * highlight_multiplier, 0.05 * highlight_multiplier, 0.05 * highlight_multiplier, 1 },
    GREEN = { 0.0 * highlight_multiplier, 0.25 * highlight_multiplier, 0.0 * highlight_multiplier, 1 },
    BLUE = { 0.05 * highlight_multiplier, 0.05 * highlight_multiplier, 0.4 * highlight_multiplier, 1 },
    YELLOW = { 0.25 * highlight_multiplier, 0.2 * highlight_multiplier, 0.0 * highlight_multiplier, 1 },
}

local ENVIRONMENTS = {
    SERVER = 1,
    SERVER_DEDICATED = 2,
    NETWORK_CLIENT = 3
}
local CURRENT_ENVIRONMENT = nil

if GLOBAL.TheNet:GetIsServer() then
    if GLOBAL.TheNet:IsDedicated() then
        CURRENT_ENVIRONMENT = ENVIRONMENTS.SERVER_DEDICATED
    else
        CURRENT_ENVIRONMENT = ENVIRONMENTS.SERVER
    end
elseif GLOBAL.TheNet:GetIsClient() then
    CURRENT_ENVIRONMENT = ENVIRONMENTS.NETWORK_CLIENT
end

-- RPC-метки
local WIMSD_RPC = "WIMSDModHighlight"
local WISMD_RETURN_RPC = "WIMSDModReturn"
local MOD_NAMESPACE = "WIMSDMod"
-- Переменные
local pending_recipes = {}
local tracked_entities = {}
local last_ingredients = {}

-- Утилитки
local function safe_unpack_rgba(t)
    return
    t[1], t[2], t[3], t[4]
end

local function safe_unpack(t, start)
    start = start or 1
    return
    t[start], t[start + 1], t[start + 2], t[start + 3], t[start + 4],
    t[start + 5], t[start + 6], t[start + 7], t[start + 8], t[start + 9],
    t[start + 10], t[start + 11], t[start + 12], t[start + 13], t[start + 14],
    t[start + 15], t[start + 16], t[start + 17], t[start + 18], t[start + 19],
    t[start + 20]
end

--------------------------------------------
-- Логгирование (отладка)
--------------------------------------------

local function serialize(obj, depth, indent, visited)
    local function safe_tostring(x)
        if type(x) == "table" then
            return "[table]"
        elseif type(x) == "function" then
            return "[function]"
        elseif type(x) == "userdata" then
            return "[userdata]"
        else
            return tostring(x)
        end
    end
    depth = depth or 0
    indent = indent or "  "
    visited = visited or {}

    if type(obj) ~= "table" then
        if type(obj) == "string" then
            return '"' .. obj .. '"'
        end
        return tostring(obj)
    end

    if visited[obj] then
        return "[Cyclic reference]"
    end
    visited[obj] = true

    local result = {}
    local current_indent = string.rep(indent, depth)
    local next_indent = current_indent .. indent

    table.insert(result, "{ ")

    for k, v in pairs(obj) do
        local key = type(k) == "string" and ('["%s"]'):format(k) or ("[%s]"):format(safe_tostring(k))
        table.insert(result, "\n")
        table.insert(result, next_indent)
        table.insert(result, key .. " = ")
        table.insert(result, serialize(v, depth + 1, indent, visited))
        table.insert(result, ",")
    end

    table.insert(result, current_indent .. "}")

    return table.concat(result)
end

local function WarnLog(...)
    if logLevel >= WARN_LEVEL then
        print("[WIMSD][WARN]", ...)
    end
end

local function DebugLog(...)
    if logLevel >= DEBUG_LEVEL then
        print("[WIMSD][DEBUG]", ...)
    end
end

local function InfoLog(...)
    if logLevel >= INFO_LEVEL then
        print("[WIMSD][INFO]", ...)
    end
end

local function LazyTraceLog(message, object)
    if logLevel >= TRACE_LEVEL then
        print("[WIMSD][TRACE]", message, serialize(object))
    end
end

local function TraceLog(...)
    if logLevel >= TRACE_LEVEL then
        print("[WIMSD][TRACE]", ...)
    end
end

local next = GLOBAL.next
--local function next(table)
--    local has_items = false
--    if table == nil then
--        return false
--    end
--    for k, v in pairs(table) do
--        TraceLog("Processing items:", k, v)
--        has_items = true
--        break
--    end
--    return has_items
--end

local function ConvertToIngredientsMap(table_of_ingredients)
    local result = {}

    for _, entry in ipairs(table_of_ingredients) do
        local amount = entry.amount or 1
        if type(entry.type) == "string" then
            result[entry.type] = (result[entry.type] or 0) + amount
        elseif type(entry.type) == "table" then
            for _, t in ipairs(entry.type) do
                result[t] = (result[t] or 0) + amount
            end
        end
    end
    return result
end

local function HasItemsInInventory(owner, item_name, amount)
    local inventory = owner.replica.inventory
    local builder = owner.replica.builder

    local has_needed_amount, _ = inventory:Has(item_name, math.max(1, GLOBAL.RoundBiasedUp(amount * builder:IngredientMod())), true)
    return has_needed_amount
end
--------------------------------------------
-- Функция GetPlayerByUserID
--------------------------------------------
local function GetPlayerByUserID(userid)
    TraceLog("GetPlayerByUserID: Looking for userid:", userid)
    for _, v in ipairs(GLOBAL.AllPlayers) do
        TraceLog("Checking player:", v.userid)
        if v.userid == userid then
            TraceLog("Found player for userid:", userid)
            return v
        end
    end
    TraceLog("No player found for userid:", userid)
    return nil
end

local function GetMissingIngredients(recipe, player)
    local missing = {}
    for _, ingredient in ipairs(recipe.ingredients) do
        local has = player.components.inventory:GetNumItem(ingredient.type, ingredient.tags)
        if has < ingredient.amount then
            missing[ingredient.type] = true  -- Используем как множество
        end
    end
    return missing
end

--------------------------------------------
-- Утилитарные функции
--------------------------------------------
---
local function table_count(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

local function ApplyHighlight(ent, color)
    if not ent or not ent:IsValid() or not ent.AnimState then
        return false
    end

    -- Сохраняем оригинальный цвет
    if not ent._original_add_color then
        ent._original_add_color = { ent.AnimState:GetAddColour() }
    end

    -- Устанавливаем новый цвет
    ent.AnimState:SetAddColour(safe_unpack_rgba(color))

    -- Добавляем обработчик для автоматической очистки
    if not ent._on_remove_fn then
        ent._on_remove_fn = function()
            tracked_entities[ent] = nil
            ent._original_add_color = nil
        end
        ent:ListenForEvent("onremove", ent._on_remove_fn)
    end

    tracked_entities[ent] = true
    return true
end

local function ClearHighlight(ent)
    if not ent or not ent:IsValid() then
        return
    end

    -- Восстанавливаем оригинальный цвет
    if ent._original_add_color then
        ent.AnimState:SetAddColour(safe_unpack_rgba(ent._original_add_color))
        ent._original_add_color = nil
    end

    -- Удаляем обработчик
    if ent._on_remove_fn then
        ent:RemoveEventCallback("onremove", ent._on_remove_fn)
        ent._on_remove_fn = nil
    end

    tracked_entities[ent] = nil
end

--------------------------------------------
-- Основные функции мода
--------------------------------------------
local function HighlightContainer(container, color)
    if not container or not container:IsValid() then
        DebugLog("Invalid container for highlighting")
        return false
    end

    if ApplyHighlight(container, color) then
        TraceLog("Highlighted container:", container.prefab)
        return true
    end
    return false
end

local function UnHighlightAll()
    DebugLog("Unhighlighting all chests. Count:", table_count(tracked_entities))
    pending_recipes = {}
    -- Создаем копию таблицы для безопасной итерации
    local entities = {}
    for ent in pairs(tracked_entities) do
        table.insert(entities, ent)
    end

    for _, ent in ipairs(entities) do
        ClearHighlight(ent)
    end
end

--------------------------------------------
-- Поиск сундуков с нужными предметами (на сервере)
--------------------------------------------
local function UniversalChestFinder(ents_found, handle_slot_fn)
    local result = {}
    local look_count = 0
    for _, ent in ipairs(ents_found) do
        if look_count > max_searched_containers then
            break
        end
        if ent:IsValid() and ent.GUID and ent.components.container then
            for _, slot_item in pairs(ent.components.container.slots or {}) do
                if handle_slot_fn(ent, slot_item, result) then
                    break
                end
            end
        end
        look_count = look_count + 1
    end

    TraceLog("UniversalChestFinder: Found", #result, "containers")
    return result
end

-- Специализированные функции
local function FindChestsWithItems(ents_found, itemNames)
    local function handle_slot(ent, slot_item, result)
        if slot_item and itemNames[slot_item.prefab] then
            local guid_str = tostring(ent.GUID)
            result[guid_str] = result[guid_str] or {}
            table.insert(result[guid_str], slot_item.prefab)
            LazyTraceLog("Found valid item:", slot_item.prefab, "in chest:", ent.GUID)
            return true
        end
        return false
    end

    return UniversalChestFinder(ents_found, handle_slot, search_radius)
end

local function FindChestsWithTags(ents_found, tags)
    local function handle_slot(ent, slot_item, result)
        local ingredient = cooking.ingredients[slot_item.prefab]
        if slot_item and ingredient then
            for target_tag, amount in pairs(tags) do
                -- TraceLog("Checking tag:", target_tag, "for item:", slot_item.prefab, "with tags:", ingredient.tags)
                if ingredient and ingredient.tags then
                    if ingredient.tags[target_tag] then
                        local guid_str = tostring(ent.GUID)
                        result[guid_str] = result[guid_str] or {}
                        local merged_value = target_tag .. "#as#" .. slot_item.prefab
                        table.insert(result[guid_str], merged_value)
                        LazyTraceLog("Found valid item:", merged_value, "in chest:", ent.GUID)
                        return true
                    else
                        TraceLog("Not matched a tag for " .. slot_item.prefab .. ":", target_tag)
                    end
                else
                    LazyTraceLog("No ingredient or tags for " .. slot_item.prefab .. ":", ingredient)
                end
            end
        else
            LazyTraceLog("Invalid ingredient or slot_item for " .. slot_item.prefab .. ":", ingredient)
        end
        return false
    end
    return UniversalChestFinder(ents_found, handle_slot)
end

local function SearchForContainers(player, items, tags)
    if not player or not player:IsValid() then
        InfoLog("UniversalChestFinder: Invalid player")
        return {}
    end
    local x, y, z = player.Transform:GetWorldPosition()
    local smallest_search_radius = 10
    if items == nil and tags ~= nil then
        smallest_search_radius = search_radius_for_tags
    elseif items ~= nil then
        smallest_search_radius = search_radius
    end
    local ents_found = TheSim:FindEntities(x, y, z, smallest_search_radius, { "highlightable_chest" })
    local by_tags = {}
    if tags then
        by_tags = FindChestsWithTags(ents_found, tags)
    end
    local by_items = {}
    if items then
        by_items = FindChestsWithItems(ents_found, items)
    end

    return by_items, by_tags
end
--------------------------------------------
-- RPC: Обработка запроса поиска сундуков по выбранному предмету/ингредиенту (на сервере)
--------------------------------------------
AddModRPCHandler(MOD_NAMESPACE, WIMSD_RPC, function(player, json_encoded_prefabs, ...)
    local received_data = json.decode(json_encoded_prefabs)
    TraceLog("Server received RPC from:", player.userid, json_encoded_prefabs)

    local target_player = GetPlayerByUserID(player.userid)
    if not target_player then
        DebugLog("Player not found:", player.userid)
        return
    end

    -- Дополнительная проверка префабов

    local response = {}
    local items, tags = SearchForContainers(player, received_data["items"], received_data["tags"])
    if items then
        response["chests_with_items"] = items
    end
    if tags then
        response["chests_with_tags"] = tags
    end

    local encoded_chests_data = json.encode(response)
    TraceLog("Sending found_chests", encoded_chests_data)
    SendModRPCToClient(
            GetClientModRPC(MOD_NAMESPACE, WISMD_RETURN_RPC),
            player.userid,
            encoded_chests_data
    )

end)

--------------------------------------------
-- RPC: Обработка возвращённых GUID для подсветки (на клиенте)
--------------------------------------------
AddClientModRPCHandler(MOD_NAMESPACE, WISMD_RETURN_RPC, function(jsonified_chunk, ...)
    TraceLog(MOD_NAMESPACE .. WISMD_RETURN_RPC .. " Received", jsonified_chunk)
    if CURRENT_ENVIRONMENT == ENVIRONMENTS.SERVER_DEDICATED then
        TraceLog("Received", WISMD_RETURN_RPC, "from server on DEDICATED")
        return
    end
    if not GLOBAL.ThePlayer then
        TraceLog("Not found ThePlayer")
        return
    else
        TraceLog("Found ThePlayer", GLOBAL.ThePlayer)
    end

    local chests_data = json.decode(jsonified_chunk)
    UnHighlightAll()

    local function ProcessGuid(guid, items, is_tag)
        local ent = Ents[guid]
        if ent then
            local has_items = false
            local color = HIGHLIGHT_COLORS.YELLOW
            if is_tag then
                color = HIGHLIGHT_COLORS.BLUE
            else
                for _, name in ipairs(items) do
                    has_items = HasItemsInInventory(GLOBAL.ThePlayer, name, 1)
                end
                if has_items then
                    color = HIGHLIGHT_COLORS.GREEN
                else
                    color = HIGHLIGHT_COLORS.RED
                end
            end

            if HighlightContainer(ent, color) then
                TraceLog("ProcessGuid: Successfully processed GUID:", guid)
                return true
            else
                TraceLog("ProcessGuid: Could not highlight entity for GUID:", guid)
            end
        else
            DebugLog("ProcessGuid: Missing entity for GUID:", guid)
        end
        return false
    end

    -- Улучшенная система повторных попыток
    local MAX_RETRIES = 3
    local retry_count = 0
    local pending_guids_for_items = nil
    local pending_guids_for_tags = nil

    local function RetryPendingGUIDs()

        local processed = 0
        if not pending_guids_for_items then
            pending_guids_for_items = chests_data["chests_with_items"]
        end
        if pending_guids_for_items then
            TraceLog("Retry attempt", retry_count + 1, "for", #pending_guids_for_items, "GUIDs")
            LazyTraceLog("Retrying GUIDs:", pending_guids_for_items)
            for chest_guid, items in pairs(pending_guids_for_items) do
                if ProcessGuid(GLOBAL.tonumber(chest_guid), items, false) then
                    table.remove(pending_guids_for_items, chest_guid)
                    processed = processed + 1
                end
            end
        end
        if not pending_guids_for_tags then
            pending_guids_for_tags = chests_data["chests_with_tags"]
        end
        if pending_guids_for_tags then
            for chest_guid, items in pairs(pending_guids_for_tags) do
                if ProcessGuid(GLOBAL.tonumber(chest_guid), items, true) then
                    table.remove(pending_guids_for_tags, chest_guid)
                    processed = processed + 1
                end
            end
        end

        TraceLog("Processed", processed, "GUIDs in attempt", retry_count + 1)

        retry_count = retry_count + 1
        if retry_count < MAX_RETRIES then
            if (pending_guids_for_tags and #pending_guids_for_tags > 0) or
                    (pending_guids_for_items and #pending_guids_for_items > 0) then
                RetryPendingGUIDs()
                TraceLog("Retrying...")
            else
                TraceLog("Nothing to retry")
            end
        else
            pending_guids_for_tags = nil
            pending_guids_for_items = nil
            retry_count = 0
            TraceLog("All GUIDs processed")
        end

    end

    RetryPendingGUIDs()

end)

--------------------------------------------
-- Функция для отправки запроса поиска (используется в хуках)
--------------------------------------------
local function FindItem(inst, items, tags)
    -- Ранний выход если нет инстанса или items == nil
    if not inst or not inst.userid then
        DebugLog("FindItem: Invalid inst or userid")
        UnHighlightAll()
        return
    end

    -- Обработка очистки подсветки
    if items == nil then
        DebugLog("FindItem: Clearing highlight")
        UnHighlightAll()
        return
    end


    -- Проверка перед отправкой RPC
    if items and next(items) or tags and next(tags) then
        SendModRPCToServer(GetModRPC(MOD_NAMESPACE, WIMSD_RPC), json.encode({ items = items, tags = tags }))
    else
        DebugLog("FindItem: No valid prefabs to search")
        UnHighlightAll()
    end
end
--------------------------------------------
-- Добавление тега к контейнерам (свободным сундукам)
--------------------------------------------
AddPrefabPostInitAny(function(inst)
    if inst.components.container then
        if not inst.components.highlight then
            inst:AddComponent("highlight")
            DebugLog("Highlight component added to container:", inst.prefab)
        end
        inst:AddTag("highlightable_chest")
        DebugLog("Tag added to container:", inst.prefab)
    end
end)
--------------------------------------------
-- Клиентский код
--------------------------------------------

if not CURRENT_ENVIRONMENT == ENVIRONMENTS.NETWORK_CLIENT then
    return
end
local is_in_craft = false

AddPlayerPostInit(function(inst)
    if not inst then
        return
    end
    inst:DoTaskInTime(0, RegisterListeners)

    require("frontend")
    local front = GLOBAL.TheFrontEnd
    if front and front.ClearFocus then
        DebugLog("Trying to redefine ClearFocus for TheFrontEnd")
        local old_ClearFocus = front.ClearFocus
        function front:ClearFocus(...)
            DebugLog("FrontEnd:ClearFocus: Called")
            res = old_ClearFocus(self, ...)
            pending_recipes = {}
            update_highlights_for_gamepad(nil)
            return res
        end
    else
        DebugLog("GLOBAL.FrontEnd is undefined, or ClearFocus is not defined but ", GLOBAL.FrontEnd, GLOBAL.FrontEnd.ClearFocus)
    end
end)

--------------------------------------------
-- Хук на компонент инвентаря (устанавливаем пересылку активного предмета)
--------------------------------------------
env.AddComponentPostInit("inventory", function(self)
    if not self.inst:HasTag("player") then
        return
    end

    local _SetActiveItem = self.SetActiveItem
    function self:SetActiveItem(item, ...)
        if item and item.prefab then
            DebugLog("Setting active item:", item.prefab)
            -- Гарантируем что inst - валидный игрок
            if self.inst and self.inst.userid then
                local table = {}
                table[item.prefab] = 1
                FindItem(self.inst, table)
            else
                DebugLog("FindItem: Invalid player instance for active item", item.prefab)
            end
        else
            DebugLog("Clearing active item")
            UnHighlightAll()
        end
        return _SetActiveItem(self, item, ...)
    end
end)

--------------------------------------------
-- Хук на виджет ингредиента в меню крафта
--------------------------------------------
local function highlightIngredients(owner, ingredients)
    LazyTraceLog("highlightMissingItems:", ingredients)

    local ingredients_missing = {}  -- простой список имён
    -- будем передавать на сервер всё. Пусть он ищет и возвращает всё что мы запросили, а клиент уже потом разберется
    -- for name, amount in pairs(ingredients) do
    --     local has = HasItemsInInventory(owner, name, amount)
    --     if not has then
    --         table.insert(ingredients_missing, name)
    --     else
    --         table.insert(ingredients_in_stock, name)
    --     end
    --     TraceLog("CRFT_DTLS Checking ingredient:", name, "has:", has, "amount:", amount)
    -- end
    LazyTraceLog("Searching for missing ingredients:", ingredients_missing)
    FindItem(owner, ingredients)
end

if not useGamepad then
    InfoLog("For now it is gamepad only mod")
    -- env.AddClassPostConstruct("widgets/ingredientui", function(self, atlas, image, quantity, on_hand, has_enough, name, owner, recipe_type)
    --     -- Сохраняем ссылку на рецепт для использования в поиске
    --     DebugLog("notUseGamepad ingredientui: Constructed with", atlas, image, quantity, on_hand, has_enough, name, owner, recipe_type)
    --     self.product = recipe_type
    --
    --     local _OnGainFocus = self.OnGainFocus
    --     local _OnLoseFocus = self.OnLoseFocus
    --
    --     function self:OnGainFocus(...)
    --         DebugLog("ingredientui: OnGainFocus, product:", tostring(self.product))
    --         if self.product and owner and owner.userid then
    --             FindItem(owner, { self.product })
    --         end
    --
    --         return _OnGainFocus(self, ...)
    --     end
    --
    --     function self:OnLoseFocus(...)
    --         DebugLog("ingredientui: OnLoseFocus, clearing highlight")
    --         UnHighlightAll()
    --         return _OnLoseFocus(self, ...)
    --     end
    --
    -- end)
else
    env.AddClassPostConstruct("widgets/redux/craftingmenu_widget", function(self, owner, crafting_hud, height)
        DebugLog("craftingmenu_widget INIT")
        local hud_close = self.crafting_hud.Close
        function self.crafting_hud:Close(...)
            TraceLog("craftingmenu_widget:crafting_hud Close")
            UnHighlightAll()
            return hud_close(self, ...)
        end
    end)
    env.AddClassPostConstruct("widgets/redux/craftingmenu_details", function(self, owner, parent_widget, panel_width, panel_height)
        TraceLog("UseGamepad widgets/redux/craftingmenu_details: Constructed with", self, owner, parent_widget, panel_width, panel_height)
        local _Refresh = self.UpdateBuildButton

        function self:UpdateBuildButton(...)
            TraceLog("widgets/redux/craftingmenu_details UpdateBuildButton")

            local result = _Refresh(self, ...)
            is_in_craft = self.parent_widget.enabled

            TraceLog("Parent state", self.parent_widget.enabled)
            if is_in_craft then
                if self.data then
                    -- DebugLog("self.data", serialize(self.data))
                    LazyTraceLog("self.data.recipe.ingredients", self.data.recipe.ingredients)
                    if self.data.recipe.ingredients then
                        FindItem(owner, ConvertToIngredientsMap(self.data.recipe.ingredients))
                    end
                end
            end

            return result
        end
        DebugLog("widgets/crafting AddClassPostConstruct")
    end)
    env.AddClassPostConstruct("widgets/redux/craftingmenu_pinslot", function(self, owner, craftingmenu, slot_num, pin_data)
        TraceLog("UseGamepad widgets/redux/craftingmenu_pinslot: Constructed with", owner, craftingmenu, slot_num, pin_data)
        local _super = self.ShowRecipe

        function self:ShowRecipe(...)
            local result = _super(self, ...)
            local recipe_data = self.craftingmenu:GetRecipeState(self.recipe_name)
            if recipe_data then
                LazyTraceLog("recipe", recipe_data.recipe)
                FindItem(owner, ConvertToIngredientsMap(recipe_data.recipe.ingredients))
            end

            return result
        end
        local _super2 = self.HideRecipe

        function self:HideRecipe(...)
            local result = _super2(self, ...)
            UnHighlightAll()
            return result
        end

        DebugLog("widgets/crafting AddClassPostConstruct")
    end)
end

local function isCraftPotPresent()
    GLOBAL.require "widgets/foodrecipepopup"
    GLOBAL.require "widgets/foodcrafting"
end

if GLOBAL.pcall(isCraftPotPresent) then
    DebugLog("Craft Pot Mod detected")
    -- local cooking = GLOBAL.require("cooking")
    -- local tag_to_ingredient = {}

    -- for item, data in pairs(cooking.ingredients) do
    --     local tags = data.tags
    --     if tags then
    --         for tag, _ in pairs(tags) do
    --             tag_to_ingredient[tag] = tag_to_ingredient[tag] or {}
    --             table.insert(tag_to_ingredient[tag], item)
    --         end
    --     end
    -- end

    AddClassPostConstruct("widgets/foodrecipepopup", function(self, owner, recipe)
        local _Update = self.Update
        function self:Update(...)
            owner:DoTaskInTime(0, function()
                UnHighlightAll()
                if recipe ~= nil then
                    local converted_recipe = {}  -- [ingredient_name] = amount
                    local tags = {}

                    local function transformToTables(item)
                        local amount = item.amt or 1
                        if amount < 1 then
                            amount = 1
                        end

                        local function add(table, name)
                            if type(name) ~= "string" then
                                WarnLog("Invalid name type, expected string but got:", type(name), serialize(name))
                                return
                            end
                            table[name] = (table[name] or 0) + amount
                        end

                        if item.name then
                            if type(item.name) == "table" then
                                for _, n in ipairs(item.name) do
                                    add(converted_recipe, n)
                                end
                            else
                                add(converted_recipe, item.name)
                            end
                        elseif item.tag then
                            TraceLog("item.tag", item.tag)
                            add(tags, item.tag)
                            -- local resolved_name = tag_to_ingredient[item.tag]
                            -- if resolved_name then
                            --     add(resolved_name)
                            -- else
                            --     WarnLog("Unknown tag:", item.tag)
                            -- end
                        else
                            WarnLog("item.name is missing", serialize(item))
                        end
                    end

                    local function handleMix(mix)
                        -- Если mix – не таблица, пропускаем
                        if type(mix) ~= "table" then
                            return
                        end

                        -- Если текущая таблица имеет ключ "name" или "tag", считаем, что это единичный ингредиент
                        if mix.name or mix.tag then
                            transformToTables(mix)
                        else
                            -- Иначе перебираем элементы таблицы
                            for _, v in pairs(mix) do
                                handleMix(v)
                            end
                        end
                    end

                    handleMix(recipe.minmix)
                    LazyTraceLog("foodrecipepopup converted_recipe:", converted_recipe)
                    LazyTraceLog("foodrecipepopup converted_recipe:", tags)
                    FindItem(owner, converted_recipe, tags)
                end
            end)

            return _Update(self, ...)
        end
    end)

    AddClassPostConstruct("widgets/foodcrafting", function(self)
        local _OnLoseFocus = self.OnLoseFocus
        self.OnLoseFocus = function(...)
            UnHighlightAll()
            return _OnLoseFocus(self, ...)

        end

        local _Close = self.Close
        self.Close = function(...)
            UnHighlightAll()
            return _Close(self, ...)
        end
    end)
end

--------------------------------------------
-- Хук на виджет группы вкладок (например, для сброса подсветки при смене вкладки)
--------------------------------------------
-- Не триггерится на гемпаде
--AddClassPostConstruct("widgets/tabgroup", function(self)
--    local _DeselectAll = self.DeselectAll
--    function self:DeselectAll(...)
--        DebugLog("tabgroup: DeselectAll invoked, clearing highlight")
--        FindItem(ThePlayer, nil)
--        return _DeselectAll(self, ...)
--    end
--end)

InfoLog("Initialization Completed")
