fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'SHOCK'
description 'Drug Lab Robbery Script'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

client_scripts {
    'cl_main.lua'
}

server_scripts {
    'sv_main.lua'
}

dependencies {
    'ox_lib',
    'ox_target',
    'ox_inventory',
    'qb-core'
}