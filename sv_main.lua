local QBCore = exports['qb-core']:GetCoreObject()

local activeJobs = {}
local globalStartCooldown = 0

local function DebugPrint(msg)
    if Config.Debug then
        print(('[druglab:server] %s'):format(msg))
    end
end

local function GetPlayer(src)
    return QBCore.Functions.GetPlayer(src)
end

local function CountPolice()
    local amount = 0
    local players = QBCore.Functions.GetQBPlayers()

    for _, player in pairs(players) do
        if player.PlayerData and player.PlayerData.job and player.PlayerData.job.name == 'police' then
            if player.PlayerData.job.onduty == nil or player.PlayerData.job.onduty == true then
                amount = amount + 1
            end
        end
    end

    return amount
end

local function HasOxItem(src, itemName, amount)
    amount = amount or 1

    if not Config.UseOXinventory then
        return false
    end

    local count = exports.ox_inventory:Search(src, 'count', itemName)
    return (count or 0) >= amount
end

local function RemoveOxItem(src, itemName, amount)
    amount = amount or 1

    if not Config.UseOXinventory then
        return false
    end

    local removed = exports.ox_inventory:RemoveItem(src, itemName, amount)
    return removed == true
end

local function GiveLootReward(src, itemName, amount)
    amount = tonumber(amount) or 1

    if Config.UseOXinventory then
        local canCarry = exports.ox_inventory:CanCarryItem(src, itemName, amount)
        if not canCarry then
            return false, 'not_enough_space'
        end

        local success, response = exports.ox_inventory:AddItem(src, itemName, amount)
        if not success then
            DebugPrint(('AddItem failed for %s | item=%s | amount=%s | reason=%s'):format(src, itemName, amount, tostring(response)))
            return false, response or 'add_failed'
        end

        return true
    end

    return false, 'inventory_disabled'
end

RegisterNetEvent('druglab:server:resetJob', function()
    local src = source
    activeJobs[src] = nil
    DebugPrint(('Reset job state for %s'):format(src))
end)

local function Notify(src, msg, msgType)
    TriggerClientEvent('druglab:client:notify', src, {
        title = 'Drug Lab',
        description = msg,
        type = msgType or 'inform'
    })
end

local function EnsurePlayerState(src)
    if not activeJobs[src] then
        activeJobs[src] = {
            started = false,
            startedAt = 0,
            lootSearched = {},
            hasEntered = false,
        }
    end

    return activeJobs[src]
end

local function IsValidLootType(itemName)
    for _, lootName in ipairs(Config.LootItems) do
        if lootName == itemName then
            return true
        end
    end

    return false
end

local function IsWithinLootAmount(amount)
    amount = tonumber(amount) or 0
    return amount >= Config.LootItemAmount.min and amount <= Config.LootItemAmount.max
end

local function RollAllowedChance(itemName)
    local chance = Config.LootItemChance[itemName] or 0
    local roll = math.random(1, 100)
    return roll <= chance
end

--========================================================
-- ox_lib callbacks
--========================================================

lib.callback.register('druglab:server:getPoliceCount', function(source)
    return CountPolice()
end)

lib.callback.register('druglab:server:hasRequiredItem', function(source, itemName)
    if not itemName or itemName == '' then
        return true
    end

    if Config.UseOXinventory then
        return HasOxItem(source, itemName, 1)
    end

    return false
end)

--========================================================
-- job lifecycle
--========================================================

RegisterNetEvent('druglab:server:jobStarted', function()
    local src = source
    local state = EnsurePlayerState(src)

    if globalStartCooldown > os.time() then
        local remaining = globalStartCooldown - os.time()
        Notify(src, ('The supplier is cooling down. Wait %s seconds.'):format(remaining), 'error')
        TriggerClientEvent('druglab:client:setJobActive', src, false)
        DebugPrint(('Blocked job start for %s due to global cooldown'):format(src))
        return
    end

    if Config.RequiredPolice > 0 then
        local policeCount = CountPolice()
        if policeCount < Config.RequiredPolice then
            Notify(src, ('Not enough police. Required: %s'):format(Config.RequiredPolice), 'error')
            TriggerClientEvent('druglab:client:setJobActive', src, false)
            DebugPrint(('Blocked job start for %s due to police count %s/%s'):format(src, policeCount, Config.RequiredPolice))
            return
        end
    end

    state.started = true
    state.startedAt = os.time()
    state.hasEntered = false
    state.lootSearched = {}

    globalStartCooldown = os.time() + Config.JobStartCooldown

    DebugPrint(('Job started for %s'):format(src))
end)

RegisterNetEvent('druglab:server:removeRequiredItem', function(itemName)
    local src = source
    local state = EnsurePlayerState(src)

    if not state.started then
        DebugPrint(('Player %s tried to remove entry item without active job'):format(src))
        return
    end

    if not Config.RemoveRequiredEnterItem then
        return
    end

    if not itemName or itemName == '' then
        return
    end

    if Config.UseOXinventory then
        if not HasOxItem(src, itemName, 1) then
            Notify(src, ('You do not have %s.'):format(itemName), 'error')
            TriggerClientEvent('druglab:client:forceCleanup', src)
            DebugPrint(('Player %s missing required item %s at removal stage'):format(src, itemName))
            return
        end

        local removed = RemoveOxItem(src, itemName, 1)
        if not removed then
            Notify(src, ('Failed to use %s.'):format(itemName), 'error')
            TriggerClientEvent('druglab:client:forceCleanup', src)
            DebugPrint(('Failed removing required item %s from %s'):format(itemName, src))
            return
        end
    end

    state.hasEntered = true
    DebugPrint(('Removed required item %s from %s'):format(itemName, src))
end)

RegisterNetEvent('druglab:server:dispatchAlert', function(coords)
    local src = source

    if not Config.Dispatch.Enabled then
        return
    end

    DebugPrint(('Dispatch alert from %s at %s'):format(
        src,
        coords and ('%.2f, %.2f, %.2f'):format(coords.x or 0.0, coords.y or 0.0, coords.z or 0.0) or 'unknown'
    ))

    -- Hook for ps-dispatch / cd_dispatch / custom dispatch
    -- Example only:
    -- TriggerEvent('yourdispatch:event', {...})
end)

--========================================================
-- loot reward
--========================================================

RegisterNetEvent('druglab:server:giveLoot', function(lootType, amount, index)
    local src = source
    local state = EnsurePlayerState(src)

    if not state.started then
        DebugPrint(('Player %s tried to loot without active job'):format(src))
        return
    end

    if not state.hasEntered and Config.RemoveRequiredEnterItem then
        DebugPrint(('Player %s tried to loot before entry validation'):format(src))
        return
    end

    if type(index) ~= 'number' or not Config.LootLocation[index] then
        DebugPrint(('Invalid loot index from %s: %s'):format(src, tostring(index)))
        return
    end

    if state.lootSearched[index] then
        Notify(src, 'This stash has already been looted.', 'error')
        DebugPrint(('Duplicate loot attempt from %s at index %s'):format(src, index))
        return
    end

    if not IsValidLootType(lootType) then
        DebugPrint(('Invalid loot type from %s: %s'):format(src, tostring(lootType)))
        return
    end

    if not IsWithinLootAmount(amount) then
        DebugPrint(('Invalid loot amount from %s: %s'):format(src, tostring(amount)))
        return
    end

    local success, reason = GiveLootReward(src, lootType, amount)

    if not success then
        if reason == 'not_enough_space' then
            Notify(src, 'You cannot carry that much.', 'error')
        else
            Notify(src, 'Failed to receive loot.', 'error')
        end

        DebugPrint(('Loot reward failed for %s | type=%s | amount=%s | reason=%s'):format(src, lootType, amount, tostring(reason)))
        return
    end

    state.lootSearched[index] = true

    Notify(src, ('You received %sx %s.'):format(amount, lootType), 'success')
    DebugPrint(('Gave loot to %s | type=%s | amount=%s | index=%s'):format(src, lootType, amount, index))
end)

--========================================================
-- cleanup
--========================================================

AddEventHandler('playerDropped', function()
    local src = source
    activeJobs[src] = nil
end)

RegisterNetEvent('druglab:server:resetJob', function()
    local src = source
    activeJobs[src] = nil
    DebugPrint(('Reset job state for %s'):format(src))
end)