Config = {}

Config.UseOXinventory = true
Config.UseOxtarget = true
Config.UseOxlib = true
Config.Debug = true

-- Job Start
Config.RequiredPolice = 0
Config.JobStartLocation = vec3(1181.85, -3113.8, 6.03)
Config.JobStartPed = 'g_m_m_mexboss_02'
Config.JobStartCooldown = 300 -- 5 minutes

Config.Dispatch = {
    Enabled = true,
    Chance = 100
}

-- Job Vehicle
Config.JobVehicle = 'rumpo2'
Config.JobVehicleSpawn = vec3(1196.94, -3105.86, 6.03)
Config.JobVehicleSpawnHeading = 3.33

-- Lab Entry / Exit
Config.DrugLabeEnterLocation = vec3(1233.59, -3235.51, 5.53)
Config.EnternaceSpawnLocation = vec3(997.14, -3200.79, -36.39)
Config.RequiredEnterItem = 'lockpick'
Config.RemoveRequiredEnterItem = true
Config.DrugLabExitLocation = vec3(997.14, -3200.79, -36.39)
Config.ExitSpawnLocation = vec3(1233.59, -3235.51, 5.53)

Config.SearchAnim = {
    dict = 'mini@repair',
    clip = 'fixing_a_ped'
}

-- Loot Props
Config.LootProps = {
    weed = 'hei_prop_heist_weed_pallet',
    coke = 'imp_prop_impexp_coke_trolly',
    meth = 'xm3_prop_xm3_bdl_meth_01a'
}

-- Loot Search Locations
Config.LootLocation = {
    vec3(1014.59, -3200.05, -37.99),
    vec3(1014.98, -3197.82, -37.99)
}

Config.LootSearchTime = 7000 -- milliseconds

-- Loot Pool
Config.LootItems = {
    'ogkush_baggy',
    'bag_of_coke',
    'meth',
}

Config.LootItemAmount = {
    min = 80,
    max = 120
}

Config.LootItemChance = {
    weed = 80,
    coke = 60,
    meth = 40
}

-- Guards
Config.OnlyGaurdsSpawnOnEnter = true
Config.GaurdRespawntime = 300 -- 5 minutes

Config.GuardAccuracy = 45
Config.GuardArmor = 50
Config.GuardHealth = 200

Config.Gaurds = {
    {
        model = 'g_m_y_mexgoon_01',
        weapon = 'WEAPON_assaultrifle',
        coords = vec3(1009.23, -3198.59, -37.99),
        heading = 0.0,
        spawncount = 5,
        spawnraduis = 0.8
    }
}