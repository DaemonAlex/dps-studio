-- SERVER. DPS 2026-10-22: club crowds (see shared/crowds.lua). One row per venue, the whole venue as JSON.
-- Admins edit venues in game with /crowd; every change goes to all players at once.

local ACE = 'dps.entityselector'
local venues = {}   -- key -> { label, x, y, z, radius, level, dance = { {x,y,z,h} }, staff = { {kind,x,y,z,h} } }
local MAX_DANCE, MAX_STAFF = 80, 12

local function allowed(src) return src and IsPlayerAceAllowed(src, ACE) end
local function num(v) return type(v) == 'number' and v == v and math.abs(v) < 1e5 end

local function save(key)
    local v = venues[key]
    if v then
        MySQL.query.await('INSERT INTO dps_studio_crowds (name, data) VALUES (?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data)', { key, json.encode(v) })
    else
        MySQL.query.await('DELETE FROM dps_studio_crowds WHERE name = ?', { key })
    end
    TriggerClientEvent('dps-studio:crowds', -1, venues)
end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS dps_studio_crowds (
        name VARCHAR(32) NOT NULL,
        data LONGTEXT NOT NULL,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (name))]])
    for _, row in ipairs(MySQL.query.await('SELECT name, data FROM dps_studio_crowds') or {}) do
        local ok, v = pcall(json.decode, row.data)
        if ok and type(v) == 'table' then venues[row.name] = v end
    end
    if next(venues) == nil then   -- first start: write the starting venues once
        for key, v in pairs(StudioCrowd.DEFAULTS) do
            venues[key] = v
            MySQL.query.await('INSERT INTO dps_studio_crowds (name, data) VALUES (?, ?)', { key, json.encode(v) })
        end
    end
    local n = 0
    for _ in pairs(venues) do n = n + 1 end
    lib.print.info(('crowds: %d venues'):format(n))
    TriggerClientEvent('dps-studio:crowds', -1, venues)
end)

lib.callback.register('dps-studio:crowds', function() return venues end)

---The venue whose middle is closest to a spot, if the spot is inside it.
local function nearest(p)
    local best, bestD
    for key, v in pairs(venues) do
        local d = #(vec3(p.x, p.y, p.z) - vec3(v.x, v.y, v.z))
        if d <= v.radius + 5.0 and (not bestD or d < bestD) then best, bestD = key, d end
    end
    return best
end

---Every /crowd action from an admin's game. p = where the admin stands { x, y, z, h }.
lib.callback.register('dps-studio:crowdEdit', function(src, action, arg, p)
    if not allowed(src) then return false, 'Crowds are for admins' end
    if type(p) ~= 'table' or not (num(p.x) and num(p.y) and num(p.z) and num(p.h)) then return false, 'Bad spot' end
    local spot = { x = p.x, y = p.y, z = p.z, h = p.h }
    if action == 'new' then
        local key = StudioCrowd.CleanKey(arg and arg.key)
        if not key then return false, 'Name: 2 to 32 letters, numbers or _' end
        if venues[key] then return false, key .. ' already exists' end
        local label = type(arg.label) == 'string' and arg.label:gsub('[<>]', ''):sub(1, 40) or key
        venues[key] = { label = label ~= '' and label or key, x = p.x, y = p.y, z = p.z, radius = 30.0, level = 'light', dance = {}, staff = {} }
        save(key)
        return true, ('Made venue %s here (30 m around you). Now stand on the dance floor and use /crowd dance.'):format(key)
    end
    local key = nearest(p)
    if not key then return false, 'You are not inside any venue. /crowd new <name> makes one here.' end
    local v = venues[key]
    if action == 'dance' then
        if #v.dance >= MAX_DANCE then return false, 'This venue has the most dance spots it can hold (' .. MAX_DANCE .. ')' end
        v.dance[#v.dance + 1] = spot
        save(key)
        return true, ('%s: dance spot %d added'):format(v.label, #v.dance)
    elseif action == 'staff' then
        if not StudioCrowd.STAFF[arg] then return false, 'Staff is dj, bartender or bouncer' end
        if #v.staff >= MAX_STAFF then return false, 'This venue has the most staff spots it can hold (' .. MAX_STAFF .. ')' end
        v.staff[#v.staff + 1] = { kind = arg, x = p.x, y = p.y, z = p.z, h = p.h }
        save(key)
        return true, ('%s: %s added'):format(v.label, arg)
    elseif action == 'level' then
        if StudioCrowd.LEVELS[arg] == nil then return false, 'Level is off, light or packed' end
        v.level = arg
        save(key)
        return true, ('%s: crowd %s'):format(v.label, arg)
    elseif action == 'undo' then
        local list = arg == 'staff' and v.staff or v.dance
        if #list == 0 then return false, 'Nothing to undo' end
        table.remove(list)
        save(key)
        return true, ('%s: last %s spot removed'):format(v.label, arg == 'staff' and 'staff' or 'dance')
    elseif action == 'radius' then
        local r = tonumber(arg)
        if not r or r < 5 or r > 80 then return false, 'Size is 5 to 80 metres' end
        v.radius = r
        save(key)
        return true, ('%s: %d m around its middle'):format(v.label, r)
    elseif action == 'delete' then
        venues[key] = nil
        save(key)
        return true, ('Venue %s removed'):format(key)
    elseif action == 'info' then
        return true, ('%s (%s): crowd %s, %d dance spots, %d staff, %d m'):format(v.label, key, v.level, #v.dance, #v.staff, v.radius)
    end
    return false, 'Unknown /crowd action'
end)
