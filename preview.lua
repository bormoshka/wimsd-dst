PrefabFiles = {}

local env = env
GLOBAL.setfenv(1, GLOBAL)

local ThePlayer = GLOBAL.ThePlayer
local TheSim = GLOBAL.TheSim
local Ents = GLOBAL.Ents
local TheNet = GLOBAL.TheNet

-- Константы
local SEARCH_RADIUS = 30
local MAX_HIGHLIGHTED = 50
local UPDATE_INTERVAL = 0.5

-- RPC-метки
local FINDER_RPC = "FinderHighlight"
local FINDER_RETURN_RPC = "FinderReturn"
local FIND_ITEM_RPC = "FIND"  -- для поиска по выбранному предмету/ингредиенту

-- Кэш подсвеченных сундуков и GUID, которые не найдены
local finder_chests = {}
local pending_guids = {}

--------------------------------------------
-- Логгирование (отладка)
--------------------------------------------
local function DebugLog(...)
    print("[Where Is My Stuff, Dude? 2025][DEBUG]", ...)
end

--------------------------------------------
-- Функция GetPlayerByUserID
--------------------------------------------
local function GetPlayerByUserID(userid)
    DebugLog("GetPlayerByUserID: Looking for userid:", userid)
    for _, v in ipairs(GLOBAL.AllPlayers) do
        DebugLog("Checking player:", v.userid)
        if v.userid == userid then
            DebugLog("Found player for userid:", userid)
            return v
        end
    end
    DebugLog("No player found for userid:", userid)
    return nil
end

--------------------------------------------
-- Компонент подсветки сундуков
--------------------------------------------
local function HighlightContainer(container, color)
    if container and container:IsValid() and container.components.highlight then
        DebugLog("Highlighting container:", container.GUID)
        container.components.highlight:Highlight(color or GLOBAL.HIGHLIGHT_GOLD)
        return true
    end
    DebugLog("Failed to highlight container:", container and container.GUID or "nil")
    return false
end

local function UnhighlightAll()
    DebugLog("Unhighlighting all chests. Count:", #finder_chests)
    for _, chest in pairs(finder_chests) do
        if chest and chest:IsValid() and chest.components.highlight then
            chest.components.highlight:UnHighlight()
        end
    end
    finder_chests = {}
end

--------------------------------------------
-- Поиск сундуков с нужными предметами (на сервере)
--------------------------------------------
local function FindChestsWithItems(player, itemnames)
    if not player or not player:IsValid() then
        DebugLog("FindChestsWithItems: Invalid player")
        return {}
    end

    local x, y, z = player.Transform:GetWorldPosition()
    local ents_found = TheSim:FindEntities(x, y, z, SEARCH_RADIUS, { "highlightable_chest" })
    local valid = {}

    for _, ent in ipairs(ents_found) do
        if #valid >= MAX_HIGHLIGHTED then break end
        for _, slot_item in pairs(ent.components.container.slots or {}) do
            if slot_item and itemnames[slot_item.prefab] then
                table.insert(valid, ent)
                DebugLog("FindChestsWithItems: Found valid chest:", ent.GUID, "with item:", slot_item.prefab)
                break
            end
        end
    end

    DebugLog("FindChestsWithItems: Total valid chests found:", #valid)
    return valid
end

--------------------------------------------
-- RPC: Обработка запроса поиска сундуков по выбранному предмету/ингредиенту (на сервере)
--------------------------------------------
AddModRPCHandler("FinderMod", FINDER_RPC, function(player, data)
    DebugLog("Server received RPC from:", player.userid)
    DebugLog("RPC Data:", GLOBAL.serialize(data))

    local target_player = GetPlayerByUserID(data.playerid)
    if not target_player or not target_player:IsValid() then
        DebugLog("Server RPC: Invalid target player for userid:", data.playerid)
        return
    end

    local prefabs_needed = {}
    for _, prefab in ipairs(data.prefabs) do
        prefabs_needed[prefab] = true
    end

    local found_chests = FindChestsWithItems(target_player, prefabs_needed)
    local chest_guids = {}
    for _, chest in ipairs(found_chests) do
        table.insert(chest_guids, chest.GUID)
    end

    DebugLog("Server RPC: Sending to client", #chest_guids, "chests")
    SendModRPCToClient(target_player.userid, "FinderMod", FINDER_RETURN_RPC, chest_guids)
end)

--------------------------------------------
-- RPC: Обработка возвращённых GUID для подсветки (на клиенте)
--------------------------------------------
AddClientModRPCHandler("FinderMod", FINDER_RETURN_RPC, function(chest_guids)
    DebugLog("Client received chests:", #chest_guids)
    UnhighlightAll()

    local function ProcessGuid(guid)
        local ent = Ents[guid]
        if ent then
            if HighlightContainer(ent) then
                table.insert(finder_chests, ent)
                DebugLog("ProcessGuid: Successfully processed GUID:", guid)
                return true
            else
                DebugLog("ProcessGuid: Could not highlight entity for GUID:", guid)
            end
        else
            DebugLog("ProcessGuid: Missing entity for GUID:", guid)
            table.insert(pending_guids, guid)
        end
        return false
    end

    for _, guid in ipairs(chest_guids) do
        ProcessGuid(guid)
    end

    if #pending_guids > 0 then
        DebugLog("Client RPC: Pending GUIDs count:", #pending_guids, "-> Retrying in 3 frames")
        ThePlayer:DoTaskInTime(3 * FRAMES, function()
            for i = #pending_guids, 1, -1 do
                local guid = pending_guids[i]
                if ProcessGuid(guid) then
                    table.remove(pending_guids, i)
                end
            end
        end)
    end
end)

--------------------------------------------
-- Функция для отправки запроса поиска (используется в хуках)
--------------------------------------------
local function FindItem(inst, item, active_item)
    if item then
        DebugLog("FindItem: Sending RPC for item:", tostring(item))
        SendModRPCToServer("FinderMod", FINDER_RPC, {
            prefabs = { item },
            playerid = inst.userid
        })
    else
        DebugLog("FindItem: Clearing highlight")
        UnhighlightAll()
    end
end

--------------------------------------------
-- Хук на компонент инвентаря (устанавливаем пересылку активного предмета)
--------------------------------------------
env.AddComponentPostInit("inventory", function(self)
    if not self.inst:HasTag("player") then
        return
    end

    local _SetActiveItem = self.SetActiveItem
    function self:SetActiveItem(item, ...)
        if item then
            DebugLog("inventory component: Active item set:", item.prefab)
            FindItem(self.inst, item.prefab, true)
        else
            DebugLog("inventory component: Active item cleared")
            SendModRPCToClient(GetClientModRPC("FINDER_REDUX", "HIGHLIGHT_ACTIVEITEM"), self.inst, nil)
        end
        return _SetActiveItem(self, item, ...)
    end
end)

--------------------------------------------
-- Хук на виджет ингредиента в меню крафта
--------------------------------------------
AddClassPostConstruct("widgets/ingredientui", function(self, atlas, image, quantity, on_hand, has_enough, name, owner, recipe_type)
    -- Сохраняем ссылку на рецепт для использования в поиске
    self.product = recipe_type

    local function pass() return true end
    local _OnGainFocus = self.OnGainFocus or pass
    local _OnLoseFocus = self.OnLoseFocus or pass

    function self:OnGainFocus(...)
        DebugLog("ingredientui: OnGainFocus, product:", tostring(self.product))
        if self.product then
            FindItem(owner, self.product.name or nil)  -- Предполагаем, что имя рецепта совпадает с prefab
        end
        return _OnGainFocus(self, ...)
    end

    function self:OnLoseFocus(...)
        DebugLog("ingredientui: OnLoseFocus, clearing highlight")
        FindItem(owner, nil)
        return _OnLoseFocus(self, ...)
    end
end)

--------------------------------------------
-- Хук на виджет группы вкладок (например, для сброса подсветки при смене вкладки)
--------------------------------------------
AddClassPostConstruct("widgets/tabgroup", function(self)
    local _DeselectAll = self.DeselectAll
    function self:DeselectAll(...)
        DebugLog("tabgroup: DeselectAll invoked, clearing highlight")
        FindItem(ThePlayer, nil)
        return _DeselectAll(self, ...)
    end
end)

--------------------------------------------
-- Добавление тега к контейнерам (свободным сундукам)
--------------------------------------------
AddPrefabPostInitAny(function(inst)
    if inst.components.container then
        inst:AddTag("highlightable_chest")
        DebugLog("Tag added to container:", inst.prefab)
    end
end)

print("[Where Is My Stuff, Dude? 2025] Initialized with debug logging")
