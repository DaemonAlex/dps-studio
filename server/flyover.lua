-- SERVER. Map flyover: /mapflyover sends the admin the map packs still without a picture
-- (flyover/targets.json, built offline from every live [maps] ymap); each picture comes back
-- as a webp data URI and is kept in flyover/shots/<pack>.txt for the review page.

local ACE = 'dps.entityselector'
local RES = GetCurrentResourceName()
local function allowed(src) return src and IsPlayerAceAllowed(src, ACE) end
local function safe(name) return (tostring(name):gsub('[^%w%-_%.]', '_')) end
local function shotPath(name) return ('flyover/shots/%s.txt'):format(safe(name)) end

lib.addCommand('mapflyover', { help = 'Studio: a top-down picture of every map pack (Backspace stops)' }, function(src)
    if not allowed(src) then return lib.notify(src, { type = 'error', description = 'Studio is for admins' }) end
    local raw = LoadResourceFile(RES, 'flyover/targets.json')
    local list = raw and json.decode(raw)
    if type(list) ~= 'table' then return lib.notify(src, { type = 'error', description = 'No flyover target list on the server' }) end
    local todo = {}
    for _, t in ipairs(list) do
        if type(t.name) == 'string' and not LoadResourceFile(RES, shotPath(t.name)) then todo[#todo + 1] = t end
    end
    if #todo == 0 then return lib.notify(src, { type = 'success', description = 'Every map pack already has its picture' }) end
    lib.print.info(('map flyover started by %s: %d of %d packs to go'):format(GetPlayerName(src) or src, #todo, #list))
    TriggerClientEvent('dps-studio:flyover', src, todo)
end)

-- The admin's game view, bigger than the booth's (review pictures, not thumbnails).
lib.callback.register('dps-studio:flyShoot', function(src)
    if not allowed(src) or GetResourceState('screencapture') ~= 'started' then return false end
    local p, settled = promise.new(), false
    local function settle(v) if not settled then settled = true; p:resolve(v) end end
    local ok = pcall(function()
        exports.screencapture:serverCapture(src, { encoding = 'webp', maxWidth = 1600, maxHeight = 900 }, settle)
    end)
    if not ok then return false end
    SetTimeout(10000, function() settle(false) end)
    local data = Citizen.Await(p)
    return type(data) == 'string' and data or false
end)

lib.callback.register('dps-studio:flySave', function(src, name, data)
    if not allowed(src) then return false end
    if type(name) ~= 'string' or #name > 120 or type(data) ~= 'string' or not data:find('^data:image/') or #data > 6000000 then return false end
    return SaveResourceFile(RES, shotPath(name), data, -1) == true
end)
