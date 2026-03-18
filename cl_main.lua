local jobActive = false
local insideLab = false
local localJobCooldown = 0
local currentVehicle = nil
local startPed = nil

local spawnedLootProps = {}
local lootSearched = {}
local spawnedGuards = {}
local guardsSpawnedAt = 0

local startZoneId = nil
local entryZoneId = nil
local exitZoneId = nil
local lootZoneIds = {}

local function DebugPrint(msg)
    if Config.Debug then
        print(('[druglab:client] %s'):format(msg))
    end
end

local function RemoveEntranceBlip()
    if entranceBlip and DoesBlipExist(entranceBlip) then
        RemoveBlip(entranceBlip)
    end

    entranceBlip = nil
end

local function CreateEntranceRoute()
    RemoveEntranceBlip()

    entranceBlip = AddBlipForCoord(Config.DrugLabeEnterLocation.x, Config.DrugLabeEnterLocation.y, Config.DrugLabeEnterLocation.z)
    SetBlipSprite(entranceBlip, 1)
    SetBlipColour(entranceBlip, 1)
    SetBlipScale(entranceBlip, 0.85)
    SetBlipAsShortRange(entranceBlip, false)
    SetBlipRoute(entranceBlip, true)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('Drug Lab Entrance')
    EndTextCommandSetBlipName(entranceBlip)

    SetNewWaypoint(Config.DrugLabeEnterLocation.x, Config.DrugLabeEnterLocation.y)
    DebugPrint('Created entrance route blip')
end


local function GiveVehicleKeys(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    local plate = GetVehicleNumberPlateText(vehicle)
    local model = GetEntityModel(vehicle)

    SetVehicleDoorsLocked(vehicle, 1)
    SetVehicleDoorsLockedForAllPlayers(vehicle, false)

    -- Common support; keep whichever one your server uses.
    if GetResourceState('qb-vehiclekeys') == 'started' then
        TriggerEvent('vehiclekeys:client:SetOwner', plate)
        TriggerServerEvent('qb-vehiclekeys:server:AcquireVehicleKeys', plate)
        DebugPrint(('Granted qb-vehiclekeys for %s'):format(plate))
        return
    end

    if GetResourceState('wasabi_carlock') == 'started' then
        TriggerServerEvent('wasabi_carlock:giveKey', plate)
        DebugPrint(('Granted wasabi_carlock key for %s'):format(plate))
        return
    end

    if GetResourceState('qs-vehiclekeys') == 'started' then
        TriggerServerEvent('qs-vehiclekeys:server:GiveVehicleKeys', plate, model, true)
        DebugPrint(('Granted qs-vehiclekeys for %s'):format(plate))
        return
    end

    DebugPrint(('No supported key resource found; vehicle left unlocked: %s'):format(plate))
end

local function EnsureInteriorReady(coords)
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    NewLoadSceneStartSphere(coords.x, coords.y, coords.z, 50.0, 0)

    local timeout = GetGameTimer() + 5000
    while GetGameTimer() < timeout do
        Wait(50)
    end

    NewLoadSceneStop()
end

--========================================================
-- Helpers
--========================================================
local function DebugPrint(msg)
    if Config.Debug then
        print(('[druglab:client] %s'):format(msg))
    end
end

local function Notify(msg, msgType)
    msgType = msgType or 'inform'

    if Config.UseOxlib and lib and lib.notify then
        lib.notify({
            title = 'Drug Lab',
            description = msg,
            type = msgType
        })
    else
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(msg)
        EndTextCommandThefeedPostTicker(false, false)
    end
end

local function LoadModel(model)
    local modelHash = type(model) == 'number' and model or joaat(model)

    if not IsModelInCdimage(modelHash) then
        DebugPrint(('Model does not exist: %s'):format(tostring(model)))
        return nil
    end

    RequestModel(modelHash)

    local timeout = 0
    while not HasModelLoaded(modelHash) do
        Wait(50)
        timeout = timeout + 1

        if timeout >= 200 then
            DebugPrint(('Failed to load model: %s'):format(tostring(model)))
            return nil
        end
    end

    return modelHash
end

local function LoadAnimDict(dict)
    RequestAnimDict(dict)

    local timeout = 0
    while not HasAnimDictLoaded(dict) do
        Wait(50)
        timeout = timeout + 1

        if timeout >= 200 then
            DebugPrint(('Failed to load anim dict: %s'):format(dict))
            return false
        end
    end

    return true
end

local function FaceCoord(ped, coords)
    TaskTurnPedToFaceCoord(ped, coords.x, coords.y, coords.z, 750)
    Wait(750)
end

local function Progress(duration, label)
    if Config.UseOxlib and lib and lib.progressCircle then
        return lib.progressCircle({
            duration = duration,
            label = label,
            position = 'bottom',
            useWhileDead = false,
            canCancel = true,
            disable = {
                move = true,
                car = true,
                combat = true
            }
        })
    else
        Wait(duration)
        return true
    end
end

local function DeleteEntitySafe(entity)
    if entity and DoesEntityExist(entity) then
        DeleteEntity(entity)
    end
end

local function ClearLootState()
    for index, entity in pairs(spawnedLootProps) do
        if entity and DoesEntityExist(entity) and Config.UseOxtarget then
            exports.ox_target:removeLocalEntity(entity, { ('druglab_loot_%s'):format(index) })
        end

        DeleteEntitySafe(entity)
    end

    spawnedLootProps = {}
    lootSearched = {}

    for _, zoneId in ipairs(lootZoneIds) do
        if Config.UseOxtarget and exports.ox_target:zoneExists(zoneId) then
            exports.ox_target:removeZone(zoneId)
        end
    end

    lootZoneIds = {}
end

local function ClearGuards()
    for _, ped in pairs(spawnedGuards) do
        DeleteEntitySafe(ped)
    end

    spawnedGuards = {}
    guardsSpawnedAt = 0
end

local function CleanupJob()
    jobActive = false
    insideLab = false

    ClearLootState()
    ClearGuards()

    if currentVehicle and DoesEntityExist(currentVehicle) then
        SetEntityAsMissionEntity(currentVehicle, true, true)
        DeleteVehicle(currentVehicle)
    end

    currentVehicle = nil
    DebugPrint('Job cleaned up')
end

--========================================================
-- Config: RequiredPolice / Dispatch / Entry Item hooks
-- Client calls server for these; server should validate.
--========================================================
local function GetPoliceCount()
    local policeCount = 0

    if Config.UseOxlib and lib and lib.callback then
        local ok, result = pcall(function()
            return lib.callback.await('druglab:server:getPoliceCount', false)
        end)

        if ok and type(result) == 'number' then
            policeCount = result
        end
    end

    return policeCount
end

local function HasRequiredEntryItem()
    if not Config.RequiredEnterItem or Config.RequiredEnterItem == '' then
        return true
    end

    if Config.UseOxlib and lib and lib.callback then
        local ok, result = pcall(function()
            return lib.callback.await('druglab:server:hasRequiredItem', false, Config.RequiredEnterItem)
        end)

        if ok then
            return result == true
        end
    end

    -- fallback if no callback is registered yet
    DebugPrint('No server callback for required item check; defaulting to false')
    return false
end

local function RemoveRequiredEntryItem()
    if not Config.RemoveRequiredEnterItem then return end
    if not Config.RequiredEnterItem or Config.RequiredEnterItem == '' then return end

    TriggerServerEvent('druglab:server:removeRequiredItem', Config.RequiredEnterItem)
end

local function SendDispatch()
    if not Config.Dispatch.Enabled then return end

    local roll = math.random(1, 100)
    if roll > Config.Dispatch.Chance then
        DebugPrint(('Dispatch roll failed: %s/%s'):format(roll, Config.Dispatch.Chance))
        return
    end

    TriggerServerEvent('druglab:server:dispatchAlert', GetEntityCoords(PlayerPedId()))
    DebugPrint('Dispatch alert triggered')
end

--========================================================
-- Config: Job Vehicle
--========================================================
local function SpawnJobVehicle()
    if currentVehicle and DoesEntityExist(currentVehicle) then
        Notify('Job vehicle already spawned.', 'error')
        return
    end

    local modelHash = LoadModel(Config.JobVehicle)
    if not modelHash then
        Notify('Vehicle model failed to load.', 'error')
        return
    end

    currentVehicle = CreateVehicle(
        modelHash,
        Config.JobVehicleSpawn.x,
        Config.JobVehicleSpawn.y,
        Config.JobVehicleSpawn.z,
        Config.JobVehicleSpawnHeading,
        true,
        false
    )

    if not currentVehicle or currentVehicle == 0 then
        Notify('Failed to spawn job vehicle.', 'error')
        return
    end

    SetVehicleOnGroundProperly(currentVehicle)
    SetVehicleHasBeenOwnedByPlayer(currentVehicle, true)
    SetEntityAsMissionEntity(currentVehicle, true, true)
    SetVehRadioStation(currentVehicle, 'OFF')
    SetVehicleEngineOn(currentVehicle, false, true, true)
    SetModelAsNoLongerNeeded(modelHash)

    GiveVehicleKeys(currentVehicle)

    Notify('Job vehicle spawned. Check your GPS for the lab.', 'success')
    DebugPrint(('Spawned job vehicle: %s'):format(Config.JobVehicle))
end

--========================================================
-- Config: SearchAnim / LootItems / LootItemChance / LootItemAmount
--========================================================
local function RollLootType()
    local totalWeight = 0

    for _, itemName in ipairs(Config.LootItems) do
        totalWeight = totalWeight + (Config.LootItemChance[itemName] or 0)
    end

    if totalWeight <= 0 then
        return Config.LootItems[1]
    end

    local roll = math.random(1, totalWeight)
    local cumulative = 0

    for _, itemName in ipairs(Config.LootItems) do
        cumulative = cumulative + (Config.LootItemChance[itemName] or 0)

        if roll <= cumulative then
            return itemName
        end
    end

    return Config.LootItems[1]
end

local function SearchLoot(index, lootType)
    if not insideLab then
        Notify('You are not inside the lab.', 'error')
        return
    end

    if lootSearched[index] then
        Notify('This stash has already been searched.', 'error')
        return
    end

    local ped = PlayerPedId()
    local lootCoords = Config.LootLocation[index]
    if not lootCoords then return end

    FaceCoord(ped, lootCoords)

    if Config.SearchAnim and Config.SearchAnim.dict and Config.SearchAnim.clip then
        if LoadAnimDict(Config.SearchAnim.dict) then
            TaskPlayAnim(
                ped,
                Config.SearchAnim.dict,
                Config.SearchAnim.clip,
                8.0,
                -8.0,
                -1,
                49,
                0.0,
                false,
                false,
                false
            )
        end
    end

    local success = Progress(Config.LootSearchTime, 'Searching stash...')
    ClearPedTasks(ped)

    if not success then
        Notify('Search cancelled.', 'error')
        return
    end

    lootSearched[index] = true

    local amount = math.random(Config.LootItemAmount.min, Config.LootItemAmount.max)

    -- Reward should still be validated server-side
    TriggerServerEvent('druglab:server:giveLoot', lootType, amount, index)

    Notify(('You found %sx %s.'):format(amount, lootType), 'success')
    DebugPrint(('Loot searched | index=%s | item=%s | amount=%s'):format(index, lootType, amount))

    local entity = spawnedLootProps[index]
    if entity and DoesEntityExist(entity) then
        SetEntityAsMissionEntity(entity, true, true)
        DeleteEntity(entity)
        spawnedLootProps[index] = nil
    end
end

--========================================================
-- Config: LootProps / LootLocation
--========================================================
local function SpawnLootProps()
    ClearLootState()

    for index, coords in ipairs(Config.LootLocation) do
        local lootType = RollLootType()
        local propModel = Config.LootProps[lootType]

        if not coords then
            DebugPrint(('Loot index %s has no coords'):format(index))
            goto continue
        end

        if coords.x == 0.0 and coords.y == 0.0 and coords.z == 0.0 then
            DebugPrint(('Loot index %s is still using placeholder coords 0,0,0'):format(index))
            goto continue
        end

        if propModel then
            local modelHash = LoadModel(propModel)

            if modelHash then
                local entity = CreateObject(modelHash, coords.x, coords.y, coords.z, false, false, false)

                if entity and entity ~= 0 and DoesEntityExist(entity) then
                    SetEntityAsMissionEntity(entity, true, true)
                    FreezeEntityPosition(entity, true)
                    PlaceObjectOnGroundProperly(entity)

                    local finalCoords = GetEntityCoords(entity)
                    spawnedLootProps[index] = entity

                    if Config.UseOxtarget then
                        exports.ox_target:addLocalEntity(entity, {
                            {
                                name = ('druglab_loot_%s'):format(index),
                                icon = 'fa-solid fa-box-open',
                                label = ('Search %s stash'):format(lootType),
                                distance = 2.0,
                                canInteract = function(ent)
                                    return insideLab and not lootSearched[index] and ent == entity
                                end,
                                onSelect = function()
                                    SearchLoot(index, lootType)
                                end
                            }
                        })
                    end

                    DebugPrint((
                        'Loot spawned | index=%s | type=%s | model=%s | handle=%s | coords=%.2f %.2f %.2f'
                    ):format(index, lootType, propModel, entity, finalCoords.x, finalCoords.y, finalCoords.z))
                else
                    DebugPrint(('Failed to create loot prop | index=%s | model=%s'):format(index, propModel))
                end

                SetModelAsNoLongerNeeded(modelHash)
            end
        end

        ::continue::
    end
end

--========================================================
-- Config: Guards
--========================================================
local function ApplyGuardStats(ped)
    SetPedAccuracy(ped, Config.GuardAccuracy or 45)
    SetPedArmour(ped, Config.GuardArmor or 0)
    SetEntityHealth(ped, Config.GuardHealth or 200)
    SetPedDropsWeaponsWhenDead(ped, false)
    SetPedCombatAttributes(ped, 46, true)
    SetPedCombatAbility(ped, 2)
    SetPedCombatMovement(ped, 2)
    SetPedCombatRange(ped, 2)
    SetPedAlertness(ped, 3)
    SetPedFleeAttributes(ped, 0, false)
    SetPedAsEnemy(ped, true)
    SetPedRelationshipGroupHash(ped, joaat('HATES_PLAYER'))
end

local function SpawnGuards()
    ClearGuards()

    for guardIndex, guardData in ipairs(Config.Gaurds) do
        if not guardData.coords then
            DebugPrint(('Guard group %s has no coords'):format(guardIndex))
            goto continue
        end

        if guardData.coords.x == 0.0 and guardData.coords.y == 0.0 and guardData.coords.z == 0.0 then
            DebugPrint(('Guard group %s is still using placeholder coords 0,0,0'):format(guardIndex))
            goto continue
        end

        local modelHash = LoadModel(guardData.model)
        if modelHash then
            for i = 1, (guardData.spawncount or 1) do
                local spawnPos = guardData.coords
                local radius = guardData.spawnraduis or 0.0

                local offsetX = radius > 0 and (math.random() * (radius * 2.0) - radius) or 0.0
                local offsetY = radius > 0 and (math.random() * (radius * 2.0) - radius) or 0.0

                local ped = CreatePed(
                    4,
                    modelHash,
                    spawnPos.x + offsetX,
                    spawnPos.y + offsetY,
                    spawnPos.z,
                    guardData.heading or 0.0,
                    false,
                    true
                )

                if ped and ped ~= 0 and DoesEntityExist(ped) then
                    SetEntityAsMissionEntity(ped, true, true)
                    SetBlockingOfNonTemporaryEvents(ped, true)
                    GiveWeaponToPed(ped, joaat(guardData.weapon), 250, false, true)
                    ApplyGuardStats(ped)
                    TaskCombatPed(ped, PlayerPedId(), 0, 16)

                    local finalCoords = GetEntityCoords(ped)
                    spawnedGuards[#spawnedGuards + 1] = ped

                    DebugPrint((
                        'Guard spawned | group=%s | handle=%s | coords=%.2f %.2f %.2f'
                    ):format(guardIndex, ped, finalCoords.x, finalCoords.y, finalCoords.z))
                else
                    DebugPrint(('Failed to spawn guard ped for model %s'):format(tostring(guardData.model)))
                end
            end

            SetModelAsNoLongerNeeded(modelHash)
        end

        ::continue::
    end

    guardsSpawnedAt = GetGameTimer()
    DebugPrint(('Total guards spawned: %s'):format(#spawnedGuards))
end

local function RespawnGuardsIfNeeded()
    if not insideLab then return end
    if #spawnedGuards > 0 then return end
    if not Config.OnlyGaurdsSpawnOnEnter then return end
    if guardsSpawnedAt <= 0 then return end

    local elapsed = GetGameTimer() - guardsSpawnedAt
    if elapsed >= (Config.GaurdRespawntime * 1000) then
        SpawnGuards()
        Notify('More guards have arrived.', 'error')
    end
end

--========================================================
-- Config: Lab Entry / Exit
--========================================================
local function EnterLab()
    if insideLab then
        Notify('You are already inside the lab.', 'error')
        return
    end

    if not jobActive then
        Notify('You need to start the job first.', 'error')
        return
    end

    if Config.RequiredEnterItem and Config.RequiredEnterItem ~= '' then
        local hasItem = HasRequiredEntryItem()
        if not hasItem then
            Notify(('You need %s to enter the lab.'):format(Config.RequiredEnterItem), 'error')
            return
        end
    end

    RemoveRequiredEntryItem()
    SendDispatch()
    RemoveEntranceBlip()

    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do
        Wait(50)
    end

    SetEntityCoords(PlayerPedId(), Config.EnternaceSpawnLocation.x, Config.EnternaceSpawnLocation.y, Config.EnternaceSpawnLocation.z)
    EnsureInteriorReady(Config.EnternaceSpawnLocation)
    Wait(500)

    DoScreenFadeIn(500)

    insideLab = true
    Notify('You entered the drug lab.', 'success')

    Wait(250)
    SpawnLootProps()

    if Config.OnlyGaurdsSpawnOnEnter then
        Wait(250)
        SpawnGuards()
    end

    DebugPrint('Player entered lab')
end

local function ExitLab()
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do
        Wait(50)
    end

    SetEntityCoords(PlayerPedId(), Config.ExitSpawnLocation.x, Config.ExitSpawnLocation.y, Config.ExitSpawnLocation.z)
    Wait(250)

    DoScreenFadeIn(500)

    insideLab = false
    jobActive = false

    ClearLootState()
    ClearGuards()
    RemoveEntranceBlip()

    TriggerServerEvent('druglab:server:resetJob')

    Notify('You left the drug lab. The robbery is complete.', 'success')
    DebugPrint('Player exited lab and completed the job')
end

--========================================================
-- Config: Job Start
--========================================================
local function StartJob()
    if jobActive then
        Notify('You already have an active robbery.', 'error')
        return
    end

    local currentTime = GetGameTimer()

    if localJobCooldown > currentTime then
        local remaining = math.ceil((localJobCooldown - currentTime) / 1000)
        Notify(('You must wait %s seconds before starting another robbery.'):format(remaining), 'error')
        return
    end

    if Config.RequiredPolice > 0 then
        local policeCount = GetPoliceCount()

        if policeCount < Config.RequiredPolice then
            Notify(('Not enough police. Required: %s'):format(Config.RequiredPolice), 'error')
            return
        end
    end

    jobActive = true
    localJobCooldown = GetGameTimer() + (Config.JobStartCooldown * 1000)

    SpawnJobVehicle()
    CreateEntranceRoute()

    TriggerServerEvent('druglab:server:jobStarted')
    Notify('Drug lab robbery started.', 'success')
    DebugPrint('Job started')
end

local function SpawnStartPed()
    if not Config.JobStartPed or Config.JobStartPed == '' then
        DebugPrint('No start ped configured')
        return
    end

    local modelHash = LoadModel(Config.JobStartPed)
    if not modelHash then return end

    startPed = CreatePed(
        4,
        modelHash,
        Config.JobStartLocation.x,
        Config.JobStartLocation.y,
        Config.JobStartLocation.z - 1.0,
        0.0,
        false,
        true
    )

    if not startPed or startPed == 0 then
        DebugPrint('Failed to create start ped')
        return
    end

    SetEntityInvincible(startPed, true)
    FreezeEntityPosition(startPed, true)
    SetBlockingOfNonTemporaryEvents(startPed, true)
    SetPedCanRagdoll(startPed, false)

    SetModelAsNoLongerNeeded(modelHash)

    if Config.UseOxtarget then
        exports.ox_target:addLocalEntity(startPed, {
            {
                name = 'druglab_start_job',
                icon = 'fa-solid fa-flask-vial',
                label = 'Start Drug Lab Robbery',
                distance = 2.0,
                onSelect = function()
                    StartJob()
                end
            }
        })
    end

    DebugPrint('Spawned start ped')
end

--========================================================
-- Zones
--========================================================
local function CreateZones()
    if not Config.UseOxtarget then
        DebugPrint('ox_target disabled; zones not created')
        return
    end

    startZoneId = exports.ox_target:addSphereZone({
        coords = Config.JobStartLocation,
        radius = 2.0,
        debug = Config.Debug,
        options = {
            {
                name = 'druglab_start_zone',
                icon = 'fa-solid fa-flask-vial',
                label = 'Start Drug Lab Robbery',
                distance = 2.0,
                canInteract = function()
                    return not startPed or not DoesEntityExist(startPed)
                end,
                onSelect = function()
                    StartJob()
                end
            }
        }
    })

    entryZoneId = exports.ox_target:addSphereZone({
        coords = Config.DrugLabeEnterLocation,
        radius = 2.0,
        debug = Config.Debug,
        options = {
            {
                name = 'druglab_enter_zone',
                icon = 'fa-solid fa-door-open',
                label = 'Enter Drug Lab',
                distance = 2.0,
                canInteract = function()
                    return jobActive and not insideLab
                end,
                onSelect = function()
                    EnterLab()
                end
            }
        }
    })

    exitZoneId = exports.ox_target:addSphereZone({
        coords = Config.DrugLabExitLocation,
        radius = 2.0,
        debug = Config.Debug,
        options = {
            {
                name = 'druglab_exit_zone',
                icon = 'fa-solid fa-door-closed',
                label = 'Exit Drug Lab',
                distance = 2.0,
                onSelect = function()
                    ExitLab()
                end
            }
        }
    })

    DebugPrint('Created interaction zones')
end

--========================================================
-- Threads
--========================================================
CreateThread(function()
    Wait(1000)

    SpawnStartPed()
    CreateZones()

    DebugPrint('cl_main initialized')
end)

CreateThread(function()
    while true do
        Wait(5000)
        RespawnGuardsIfNeeded()
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    CleanupJob()

    if startPed and DoesEntityExist(startPed) then
        DeleteEntity(startPed)
    end

    if Config.UseOxtarget then
        if startZoneId then exports.ox_target:removeZone(startZoneId) end
        if entryZoneId then exports.ox_target:removeZone(entryZoneId) end
        if exitZoneId then exports.ox_target:removeZone(exitZoneId) end
    end
end)

--========================================================
-- Optional external cleanup hooks
--========================================================
RegisterNetEvent('druglab:client:forceCleanup', function()
    CleanupJob()
end)

RegisterNetEvent('druglab:client:setJobActive', function(state)
    jobActive = state == true
end)

RegisterNetEvent('druglab:server:resetJob', function()
    local src = source
    activeJobs[src] = nil
    DebugPrint(('Reset job state for %s'):format(src))
end)

RegisterNetEvent('druglab:client:notify', function(data)
    if Config.UseOxlib and lib and lib.notify then
        lib.notify(data)
    else
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(data.description or 'Notification')
        EndTextCommandThefeedPostTicker(false, false)
    end
end)