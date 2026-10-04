fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'dps-studio'
author 'Del Perro Sands'
description 'DPS Studio (/admin): build the rooms players use every day. Rooms, saved looks, furniture, shells, inspect, spots, doors and history on one panel.'
version '1.4.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/logic.lua',
    'shared/shellmeta.lua',
    'shared/ipls.lua',
}
client_scripts {
    'client/rooms.lua',
    'client/place.lua',
    'client/inspect.lua',
    'client/mark.lua',
    'client/booth.lua',
    'client/flyover.lua',
    'client/ipl.lua',
    'client/doors.lua',
    'client/panel.lua',
}
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/flyover.lua',
}

ui_page 'html/index.html'
files { 'html/index.html', 'html/style.css', 'html/dps-look.css', 'html/app.js', 'html/library.json' }

dependencies { 'ox_lib', 'oxmysql' }
