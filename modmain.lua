GLOBAL.require "mathutil"
GLOBAL.require "json"
local json = GLOBAL.json
local cooking = GLOBAL.require("cooking")

--------------------------------------------
-- Логгирование НАЧАЛО
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

local Logger = Class(function(self, log_level)
    self.log_level = log_level or 0
    self.WARN_LEVEL = 2
    self.INFO_LEVEL = 3
    self.DEBUG_LEVEL = 7
    self.TRACE_LEVEL = 12

    function self:Warn(...)
        if self.log_level >= self.WARN_LEVEL then
            print("[WIMSD][WARN]", ...)
        end
    end

    function self:Debug(...)
        if self.log_level >= self.DEBUG_LEVEL then
            print("[WIMSD][DEBUG]", ...)
        end
    end

    function self:Info(...)
        if self.log_level >= self.INFO_LEVEL then
            print("[WIMSD][INFO]", ...)
        end
    end

    function self:LazyTrace(message, object)
        if self.log_level >= self.TRACE_LEVEL then
            print("[WIMSD][TRACE]", message, serialize(object))
        end
    end

    function self:Trace(...)
        if self.log_level >= self.TRACE_LEVEL then
            print("[WIMSD][TRACE]", ...)
        end
    end
end)



local log_level_client = GetModConfigData("log_level_client", 0)
local log_level_server = GetModConfigData("log_level_server", 0)

local log_level = log_level_client

if GLOBAL.TheNet:GetIsServer() then
    log_level = log_level_server
end

if type(logLevel) ~= "number" then
    print("Invalid log level", logLevel)
    logLevel = 0
end

local logger = Logger(log_level)
--------------------------------------------
-- Логгирование КОНЕЦ
--------------------------------------------


local max_searched_containers = GetModConfigData("max_searched_containers") or 50
local search_radius = GetModConfigData("search_radius") or 30
local search_radius_for_tags = GetModConfigData("search_radius_for_tags") or 15
local highlight_multiplier = GetModConfigData("highlight_multiplier") or 1


-- Константы
local HIGHLIGHT_COLORS = {
    -- red, green, blue, alpha
    RED = { 0.4 * highlight_multiplier, 0.05 * highlight_multiplier, 0.05 * highlight_multiplier, 1 },
    GREEN = { 0.0 * highlight_multiplier, 0.25 * highlight_multiplier, 0.0 * highlight_multiplier, 1 },
    BLUE = { 0.05 * highlight_multiplier, 0.05 * highlight_multiplier, 0.4 * highlight_multiplier, 1 },
    YELLOW = { 0.25 * highlight_multiplier, 0.2 * highlight_multiplier, 0.0 * highlight_multiplier, 1 },
}

-- RPC-метки
local WIMSD_RPC = "WIMSDModHighlight"
local WISMD_RETURN_RPC = "WIMSDModReturn"
local MOD_NAMESPACE = "WIMSDMod"

-- Переменные
local pending_recipes = {}
local tracked_entities = {}
local network_id_cache = {}


local next = GLOBAL.next

-- Утилитки
local function safe_unpack_rgba(t)
    return
    t[1], t[2], t[3], t[4]
end

local function table_count(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

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
    logger:Trace("GetPlayerByUserID: Looking for userid:", userid)
    for _, v in ipairs(GLOBAL.AllPlayers) do
        logger:Trace("Checking player:", v.userid)
        if v.userid == userid then
            logger:Trace("Found player for userid:", userid)
            return v
        end
    end
    logger:Trace("No player found for userid:", userid)
    return nil
end


local function ApplyHighlight(ent, color)
    if not ent or not ent:IsValid() or not ent.AnimState then
        logger:Debug("Invalid entity for highlighting or no AnimState")
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
        logger:Debug("Invalid container for highlighting")
        return false
    end

    if ApplyHighlight(container, color) then
        logger:Trace("Highlighted container:", container.prefab)
        return true
    end
    return false
end

local function UnHighlightAll()
    logger:Debug("Unhighlighting all chests. Count:", table_count(tracked_entities))
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

    logger:Trace("UniversalChestFinder: Found", #result, "containers")
    return result
end

-- Специализированные функции
local function FindChestsWithItems(ents_found, itemNames)
    local function handle_slot(ent, slot_item, result)
        if slot_item and itemNames[slot_item.prefab] then
            local net_id = tostring(ent.Network:GetNetworkID())
            result[net_id] = result[net_id] or {}
            table.insert(result[net_id], slot_item.prefab)
            logger:LazyTrace("Found valid item:", slot_item.prefab, "in chest:", ent.GUID)
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
                -- logger:Trace("Checking tag:", target_tag, "for item:", slot_item.prefab, "with tags:", ingredient.tags)
                if ingredient and ingredient.tags then
                    if ingredient.tags[target_tag] then
                        local net_id = tostring(ent.Network:GetNetworkID())
                        result[net_id] = result[net_id] or {}
                        local merged_value = target_tag .. "#as#" .. slot_item.prefab
                        table.insert(result[net_id], merged_value)
                        logger:LazyTrace("Found valid item:", merged_value, "in chest:", ent.GUID)
                        return true
                    else
                        logger:Trace("Not matched a tag for " .. slot_item.prefab .. ":", target_tag)
                    end
                else
                    logger:LazyTrace("No ingredient or tags for " .. slot_item.prefab .. ":", ingredient)
                end
            end
        else
            logger:LazyTrace("Invalid ingredient or slot_item for " .. slot_item.prefab .. ":", ingredient)
        end
        return false
    end
    return UniversalChestFinder(ents_found, handle_slot)
end

local function SearchForContainers(player, items, tags)
    if not player or not player:IsValid() then
        logger:Info("UniversalChestFinder: Invalid player")
        return {}
    end
    local x, y, z = player.Transform:GetWorldPosition()
    local smallest_search_radius = 10
    if items == nil and tags ~= nil then
        smallest_search_radius = search_radius_for_tags
    elseif items ~= nil then
        smallest_search_radius = search_radius
    end
    local ents_found = GLOBAL.TheSim:FindEntities(x, y, z, smallest_search_radius, { "highlightable_chest" })
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

local function GetEntityByNetID(net_id)
    local entity = network_id_cache[net_id]
    if entity then
        logger:Trace("Entity found in cache by NetID:", net_id, "entity is valid:", entity:IsValid())
    end
    if not entity or not entity:IsValid() then
        for _, ent in pairs(GLOBAL.Ents) do
            if ent.Network and ent.Network:GetNetworkID() == net_id then
                network_id_cache[net_id] = ent -- Добавить в кеш
                logger:Trace("Entity found in GLOBAL.Ents by NetID:", net_id)
                return ent
            end
        end
        return nil
    end
    return entity
end

--------------------------------------------
-- RPC: Обработка запроса поиска сундуков по выбранному предмету/ингредиенту (на сервере)
--------------------------------------------
local function HandleSearchRequest(player, received_data, ...)
    local response = {}
    response["shard_id"] = GLOBAL.TheShard:GetShardId()

    if received_data["items"] or received_data["tags"] then
        local items, tags = SearchForContainers(player, received_data["items"], received_data["tags"])
        if items then
            response["chests_with_items"] = items
        end
        if tags then
            response["chests_with_tags"] = tags
        end

    else
        response["purge"] = "true"
    end

    local encoded_chests_data = json.encode(response)
    logger:Trace("Sending found_chests", encoded_chests_data)
    SendModRPCToClient(
            GetClientModRPC(MOD_NAMESPACE, WISMD_RETURN_RPC),
            player.userid,
            encoded_chests_data
    )
end

AddModRPCHandler(MOD_NAMESPACE, WIMSD_RPC, function(player, json_encoded_prefabs, ...)
    local received_data = json.decode(json_encoded_prefabs)

    print("Server received RPC from:", player.userid, json_encoded_prefabs)

    local target_player = GetPlayerByUserID(player.userid)
    if not target_player then
        logger:Debug("Player not found:", player.userid)
        return
    end

    HandleSearchRequest(player, received_data)
end)

--------------------------------------------
-- RPC: Обработка возвращённых GUID для подсветки (на клиенте)
--------------------------------------------
AddClientModRPCHandler(MOD_NAMESPACE, WISMD_RETURN_RPC, function(jsonified_chunk, ...)
    logger:Trace(MOD_NAMESPACE .. WISMD_RETURN_RPC .. " Received", jsonified_chunk)

    if not GLOBAL.ThePlayer then
        logger:Trace("Player not found")
        return
    end

    local chests_data = json.decode(jsonified_chunk)
    UnHighlightAll()
    if chests_data["purge"] then
        return
    end

    -- Новая функция обработки Network ID
    local function ProcessNetID(net_id, items, is_tag)
        -- Поиск в кеше (O(1) вместо O(n))
        local ent = GetEntityByNetID(net_id)

        if not ent then
            logger:Debug("Entity not found for NetID:", net_id)
            return false
        end

        if not ent:IsValid() then
            logger:Debug("Entity is not valid:", net_id)
            return false
        end

        -- Проверка компонентов
        if not ent.AnimState then
            logger:Debug("Entity has no AnimState:", ent.prefab)
            return false
        end

        --if not ent.components.container then
        --    logger:Debug("Entity is not a container:", ent.prefab)
        --    return false
        --end

        -- Определение цвета
        local color = HIGHLIGHT_COLORS.YELLOW
        if is_tag then
            color = HIGHLIGHT_COLORS.BLUE
        else
            local has_all = true
            for _, name in ipairs(items) do
                if not HasItemsInInventory(GLOBAL.ThePlayer, name, 1) then
                    has_all = false
                    break
                end
            end
            color = has_all and HIGHLIGHT_COLORS.GREEN or HIGHLIGHT_COLORS.RED
        end

        return HighlightContainer(ent, color)
    end

    -- Улучшенная система повторных попыток
    local MAX_RETRIES = 3
    local retry_count = 0
    local pending_ids_for_items = nil
    local pending_ids_for_tags = nil

    local function RetryPending()
        local processed = 0
        if not pending_ids_for_items then
            pending_ids_for_items = chests_data["chests_with_items"]
        end
        if pending_ids_for_items then
            logger:Trace("Retry attempt", retry_count + 1, "for", #pending_ids_for_items, "GUIDs")
            logger:LazyTrace("Retrying GUIDs:", pending_ids_for_items)
            for chest_guid, items in pairs(pending_ids_for_items) do
                if ProcessNetID(GLOBAL.tonumber(chest_guid), items, false) then
                    table.remove(pending_ids_for_items, chest_guid)
                    processed = processed + 1
                end
            end
        end
        if not pending_ids_for_tags then
            pending_ids_for_tags = chests_data["chests_with_tags"]
        end
        if pending_ids_for_tags then
            for chest_guid, items in pairs(pending_ids_for_tags) do
                if ProcessNetID(GLOBAL.tonumber(chest_guid), items, true) then
                    table.remove(pending_ids_for_tags, chest_guid)
                    processed = processed + 1
                end
            end
        end

        logger:Trace("Processed", processed, "entities in attempt", retry_count + 1)

        retry_count = retry_count + 1
        if retry_count < MAX_RETRIES then
            if (pending_ids_for_tags and #pending_ids_for_tags > 0) or
                    (pending_ids_for_items and #pending_ids_for_items > 0) then
                RetryPending()
                logger:Trace("Retrying...")
            else
                logger:Trace("Nothing to retry")
            end
        else
            pending_ids_for_tags = nil
            pending_ids_for_items = nil
            retry_count = 0
            logger:Trace("All GUIDs processed")
        end

    end

    RetryPending()
end)
--------------------------------------------
-- Функция для отправки запроса поиска (используется в хуках)
--------------------------------------------
local function SearchForItemsOnServer(inst, items, tags)
    -- Ранний выход если нет инстанса или items == nil
    if not inst or not inst.userid then
        logger:Debug("FindItem: Invalid inst or userid")
        UnHighlightAll()
        return
    end

    -- Обработка очистки подсветки
    if items == nil then
        logger:Debug("FindItem: Clearing highlight")
        UnHighlightAll()
        return
    end


    -- Проверка перед отправкой RPC
    if items and next(items) or tags and next(tags) then
        SendModRPCToServer(GetModRPC(MOD_NAMESPACE, WIMSD_RPC), json.encode({ items = items, tags = tags }))
    else
        logger:Debug("FindItem: No valid prefabs to search")
        UnHighlightAll()
    end
end

-- Это не клиентский, а серверный хук, ёмаё
env.AddComponentPostInit("inventory", function(self)
    logger:Debug("Add ComponentPostInit for inventory:", self.inst:HasTag("player"))
    if not self.inst:HasTag("player") then
        return
    end
    local _SetActiveItem = self.SetActiveItem
    function self:SetActiveItem(item, ...)
        if item and item.prefab then
            logger:Debug("Setting active item:", item.prefab)
            -- Гарантируем что inst - валидный игрок
            if self.inst and self.inst.userid then
                local table = {}
                table[item.prefab] = 1
                -- SearchForItemsOnServer(self.inst, table)
                HandleSearchRequest(self.inst, { items = table })
            else
                logger:Debug("FindItem: Invalid player instance for active item", item.prefab)
            end
        else
            logger:Debug("Clearing active item")
            HandleSearchRequest(self.inst, {  })
        end
        return _SetActiveItem(self, item, ...)
    end
end)

local function RegisterListeners()
    logger:Debug("Registering listeners")

    if not GLOBAL.TheWorld then
        logger:Info("TheWorld is not initialized yet. Skipping listeners setup. It is probably a bug.")
        return
    end
    -- Обработчик создания новых сущностей
    local function OnEntitySpawned(ent)
        if ent.Network then
            logger:Trace("Entity spawned, adding to cache:", ent.prefab)
            network_id_cache[ent.Network:GetNetworkID()] = ent
        end
    end

    -- Обработчик удаления сущностей
    local function OnEntityRemoved(ent)
        if ent.Network then
            logger:Trace("Entity removed, so removing from cache:", ent.prefab)
            network_id_cache[ent.Network:GetNetworkID()] = nil
        end
    end

    -- Подписка на события
    GLOBAL.TheWorld:ListenForEvent("entity_spawned", OnEntitySpawned)
    GLOBAL.TheWorld:ListenForEvent("entity_removed", OnEntityRemoved)

end
--------------------------------------------
-- Клиентский код
--------------------------------------------
-- Добавить в обработчики смены мира
env.AddSimPostInit(function()
    GLOBAL.TheWorld:ListenForEvent("playeractivated", function(_, player)
        if player == GLOBAL.ThePlayer then
            logger:Debug("Player activated in new world - resetting caches")
            network_id_cache = {}
            tracked_entities = {}
            RegisterListeners() -- Перерегистрируем обработчики на новом мире
        end
    end)
end)

env.AddPlayerPostInit(function(inst)
    -- Ждем инициализации игрока
    inst:DoTaskInTime(2, function()
        if GLOBAL.TheWorld then
            inst:DoTaskInTime(0.5, function()
                logger:Debug("Initializing Network ID cache")
                network_id_cache = {}
                local count = 0
                for _, ent in pairs(GLOBAL.Ents) do
                    if ent.Network then
                        network_id_cache[ent.Network:GetNetworkID()] = ent
                        count = count + 1
                    end
                end
                logger:Debug("Network ID cache initialized. Entities:", count)
            end)
        else
            logger:Debug("Client world not initialized.")
        end
    end)
end)

--local function OnNetworkIDChanged(ent, old_id, new_id)
--    if old_id ~= nil then
--        network_id_cache[old_id] = nil
--    end
--    if new_id ~= nil then
--        network_id_cache[new_id] = ent
--    end
--end

-- Для всех сущностей с компонентом Network:
--env.AddComponentPostInit("network", function(self)
--    logger:Debug("Add ComponentPostInit for network")
--    if not GLOBAL.TheWorld then
--        return
--    end
--
--    local old_SetNetworkID = self.SetNetworkID
--    function self:SetNetworkID(id)
--        logger:Debug("Setting network ID:", id)
--        OnNetworkIDChanged(self.inst, self:GetNetworkID(), id)
--        return old_SetNetworkID(self, id)
--    end
--end)
-- inventory

if GLOBAL.TheNet:GetIsServer() then
    env.AddPrefabPostInitAny(function(inst)
        logger:Debug("PrefabPostInitAny:", inst.prefab)
        if inst.components.container then
            if not inst.components.highlight then
                inst:AddComponent("highlight")
                logger:Debug("Highlight component added to container:", inst.prefab)
            end
            inst:AddTag("highlightable_chest")
            logger:Debug("Tag added to container:", inst.prefab)
        end
        return inst
    end)
end

env.AddSimPostInit(function()
    if GLOBAL.TheWorld then
        RegisterListeners()
    else
        -- Для клиента: ждем инициализации мира
        GLOBAL.ThePlayer:DoTaskInTime(1, function()
            if GLOBAL.TheWorld then
                RegisterListeners()
            else
                logger:Debug("TheWorld still not initialized. Aborting.")
            end
        end)
    end
end)

local is_in_craft = false

--------------------------------------------
-- Хук на виджет ингредиента в меню крафта
--------------------------------------------

env.AddClassPostConstruct("widgets/redux/craftingmenu_widget", function(self, owner, crafting_hud, height)
    logger:Debug("craftingmenu_widget INIT")
    local hud_close = self.crafting_hud.Close
    function self.crafting_hud:Close(...)
        logger:Trace("craftingmenu_widget:crafting_hud Close")
        UnHighlightAll()
        return hud_close(self, ...)
    end
end)

env.AddClassPostConstruct("widgets/redux/craftingmenu_details", function(self, owner, parent_widget, panel_width, panel_height)
    logger:Trace("UseGamepad widgets/redux/craftingmenu_details: Constructed with", self, owner, parent_widget, panel_width, panel_height)
    local _Refresh = self.UpdateBuildButton

    function self:UpdateBuildButton(...)
        logger:Trace("widgets/redux/craftingmenu_details UpdateBuildButton")

        local result = _Refresh(self, ...)
        is_in_craft = self.parent_widget.enabled

        logger:Trace("Parent state", self.parent_widget.enabled)
        if is_in_craft then
            if self.data then
                -- logger:Debug("self.data", serialize(self.data))
                logger:LazyTrace("self.data.recipe.ingredients", self.data.recipe.ingredients)
                if self.data.recipe.ingredients then
                    SearchForItemsOnServer(owner, ConvertToIngredientsMap(self.data.recipe.ingredients))
                end
            end
        end

        return result
    end
    logger:Debug("widgets/crafting AddClassPostConstruct")
end)

env.AddClassPostConstruct("widgets/redux/craftingmenu_pinslot", function(self, owner, craftingmenu, slot_num, pin_data)
    logger:Trace("UseGamepad widgets/redux/craftingmenu_pinslot: Constructed with", owner, craftingmenu, slot_num, pin_data)
    local _super = self.ShowRecipe

    function self:ShowRecipe(...)
        local result = _super(self, ...)
        local recipe_data = self.craftingmenu:GetRecipeState(self.recipe_name)
        if recipe_data then
            logger:LazyTrace("recipe", recipe_data.recipe)
            SearchForItemsOnServer(owner, ConvertToIngredientsMap(recipe_data.recipe.ingredients))
        end

        return result
    end
    local _super2 = self.HideRecipe

    function self:HideRecipe(...)
        local result = _super2(self, ...)
        UnHighlightAll()
        return result
    end

    logger:Debug("widgets/crafting AddClassPostConstruct")
end)

local function isCraftPotPresent()
    GLOBAL.require "widgets/foodrecipepopup"
    GLOBAL.require "widgets/foodcrafting"
end

if GLOBAL.pcall(isCraftPotPresent) then
    logger:Debug("Craft Pot Mod detected")
    AddClassPostConstruct("widgets/foodrecipepopup", function(self, owner, recipe)
        local _Update = self.Update
        function self:Update(...)
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
                            logger:Warn("Invalid name type, expected string but got:", type(name), serialize(name))
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
                        logger:Trace("item.tag", item.tag)
                        add(tags, item.tag)
                    else
                        logger:Warn("item.name is missing", serialize(item))
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
                logger:LazyTrace("foodrecipepopup converted_recipe:", converted_recipe)
                logger:LazyTrace("foodrecipepopup converted_recipe:", tags)
                SearchForItemsOnServer(owner, converted_recipe, tags)
            end

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

logger:Info("Initialization Completed")
