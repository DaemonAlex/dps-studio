-- SERVER. DPS Studio: rooms (a door, a shell, saved looks of furniture), spots,
-- and a history of every change that can be restored.
-- One row per room holds the whole room as JSON, so a history snapshot is that same
-- JSON and restoring it is one write. Every admin action is checked here, never trusted
-- from the client. Admin = ace dps.entityselector (group.admin has it).

local ACE = 'dps.entityselector'
local RES = GetCurrentResourceName()
local rooms = {}           -- name -> room (see Studio.NewRoom)
local ready = false
local shells, shellSet = {}, {}
local furnCats, furnModels

local function allowed(src) return src and IsPlayerAceAllowed(src, ACE) end
local function who(src) return (GetPlayerName(src) or ('id ' .. tostring(src))):sub(1, 60) end

-- ---------------------------------------------------------------- data sources
local function loadShells()
    shells = Studio.ParseShells(LoadResourceFile('qs-housing', 'config/main.lua'))
    shellSet = {}
    for _, m in ipairs(shells) do shellSet[m] = true end
end

local function furniture()
    if not furnCats then
        local cats, models = Studio.ParseFurniture(LoadResourceFile('qs-housing', 'config/furniture.lua'),
            'nui://qs-housing/web/images/', { vector3 = vector3, vec3 = vec3, vector4 = vector4, vec4 = vec4 })
        local n = 0
        for _ in pairs(models) do n = n + 1 end
        if n == 0 then
            lib.print.warn('furniture: could not read qs-housing config/furniture.lua, will try again next time')
            return cats, models
        end
        -- the full library (html/library.json, built by tools/build_library.py): every game object
        -- and every model the server streams. Any of them may be placed.
        local libN = 0
        local ok, library = pcall(json.decode, LoadResourceFile(RES, 'html/library.json') or '')
        if ok and type(library) == 'table' and type(library.groups) == 'table' then
            for _, g in ipairs(library.groups) do
                for _, it in ipairs(type(g.items) == 'table' and g.items or {}) do
                    local m = type(it) == 'table' and it[1]
                    if type(m) == 'string' and not models[m] then models[m] = true; libN = libN + 1 end
                end
            end
        else
            lib.print.warn('library: html/library.json could not be read, only housing furniture can be placed')
        end
        furnCats, furnModels = cats, models   -- kept only when it loaded
        lib.print.info(('furniture: %d groups, %d pieces, library adds %d'):format(#furnCats, n, libN))
    end
    return furnCats, furnModels
end

-- ---------------------------------------------------------------- database
local TABLES = {
    [[CREATE TABLE IF NOT EXISTS dps_studio_rooms (
        name VARCHAR(32) NOT NULL,
        data LONGTEXT NOT NULL,
        updated_by VARCHAR(64) DEFAULT NULL,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (name))]],
    [[CREATE TABLE IF NOT EXISTS dps_studio_history (
        id INT NOT NULL AUTO_INCREMENT,
        at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        by_name VARCHAR(64) DEFAULT NULL,
        action VARCHAR(40) NOT NULL,
        room VARCHAR(32) NOT NULL,
        summary VARCHAR(200) DEFAULT NULL,
        before_data LONGTEXT DEFAULT NULL,
        pruned TINYINT NOT NULL DEFAULT 0,
        PRIMARY KEY (id), KEY room_idx (room))]],
    [[CREATE TABLE IF NOT EXISTS dps_studio_spots (
        id INT NOT NULL AUTO_INCREMENT,
        kind VARCHAR(8) NOT NULL DEFAULT 'spot',
        label VARCHAR(80) DEFAULT '',
        x DOUBLE NOT NULL, y DOUBLE NOT NULL, z DOUBLE NOT NULL, h DOUBLE NOT NULL DEFAULT 0,
        prop_hash BIGINT DEFAULT NULL, prop_dist FLOAT DEFAULT NULL,
        street VARCHAR(60) DEFAULT '', zone VARCHAR(60) DEFAULT '',
        by_name VARCHAR(64) DEFAULT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (id))]],
    [[CREATE TABLE IF NOT EXISTS dps_studio_thumbs (
        model VARCHAR(96) NOT NULL,
        url VARCHAR(400) NOT NULL,
        at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (model))]],
    [[CREATE TABLE IF NOT EXISTS dps_studio_meta (
        k VARCHAR(40) NOT NULL, v VARCHAR(200) DEFAULT NULL, PRIMARY KEY (k))]],
}

local function persist(room)
    MySQL.query.await('INSERT INTO dps_studio_rooms (name, data, updated_by) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data), updated_by = VALUES(updated_by)',
        { room.name, json.encode(room), room.updatedBy })
end

local function insertSpot(s)
    return MySQL.insert.await('INSERT INTO dps_studio_spots (kind, label, x, y, z, h, prop_hash, prop_dist, street, zone, by_name, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, NOW()))',
        { s.kind, s.label or '', s.x, s.y, s.z, s.h or 0, s.propHash, s.propDist, (s.street or ''):sub(1, 60), (s.zone or ''):sub(1, 60), s.by, s.at })
end

-- ---------------------------------------------------------------- lists sent out
local publicCache = {}        -- rebuilt only when a room changes, never per request
local function rebuildPublic()
    local out = {}
    for _, r in pairs(rooms) do out[#out + 1] = Studio.PublicRoom(r) end
    publicCache = out
end
local function publicList() return publicCache end

local function summaries()
    local out = {}
    for _, r in pairs(rooms) do out[#out + 1] = Studio.RoomSummary(r) end
    table.sort(out, function(a, b) return a.label:lower() < b.label:lower() end)
    return out
end

---Tells every player about one room (false when it was removed), and open panels to refresh.
local function broadcast(name)
    rebuildPublic()
    if name then
        TriggerClientEvent('dps-studio:room', -1, name, rooms[name] and Studio.PublicRoom(rooms[name]) or false)
    else
        TriggerClientEvent('dps-studio:rooms', -1, publicCache)
    end
    TriggerClientEvent('dps-studio:changed', -1)
end

local KEEP_SNAPSHOTS = 200    -- per room; older history lines keep their words but lose the snapshot

---Runs one change to one room: snapshot, change, save, history, tell everyone.
---fn returns ok, err. The room may be created or removed inside fn.
local function change(src, name, action, summary, fn)
    if not ready then return false, 'Studio is still starting, try again in a moment' end
    local before = rooms[name] and Studio.Copy(rooms[name]) or nil
    local ok, err = fn()
    if not ok then
        rooms[name] = before   -- nothing half-done survives a failed check
        return false, err
    end
    local room = rooms[name]
    if room then
        room.updatedBy = who(src)
        room.updatedAt = os.date('!%Y-%m-%d %H:%M UTC')
        persist(room)
    else
        MySQL.query.await('DELETE FROM dps_studio_rooms WHERE name = ?', { name })
    end
    MySQL.insert.await('INSERT INTO dps_studio_history (by_name, action, room, summary, before_data) VALUES (?, ?, ?, ?, ?)',
        { who(src), action, name, summary:sub(1, 200), before and json.encode(before) or nil })
    MySQL.update.await(('UPDATE dps_studio_history SET before_data = NULL, pruned = 1 WHERE room = ? AND before_data IS NOT NULL AND id < (SELECT id FROM (SELECT id FROM dps_studio_history WHERE room = ? ORDER BY id DESC LIMIT 1 OFFSET %d) t)'):format(KEEP_SNAPSHOTS - 1), { name, name })
    lib.print.info(('%s: %s'):format(who(src), summary))
    broadcast(name)
    return true
end

-- ---------------------------------------------------------------- start up
local function importOld()
    local done = MySQL.scalar.await('SELECT v FROM dps_studio_meta WHERE k = ?', { 'import_v1' })
    if done then return end
    local _, models = furniture()
    if #shells == 0 or not next(models) then
        lib.print.warn('import waits: the qs-housing shell or furniture list could not be read. It runs again next start.')
        return
    end
    -- mark it first: a failure half way must never import the same spots twice
    MySQL.insert.await('INSERT INTO dps_studio_meta (k, v) VALUES (?, ?)', { 'import_v1', os.date('!%Y-%m-%d %H:%M UTC') })
    local nRooms, nSpots = 0, 0

    local pj = LoadResourceFile(RES, 'import/portals.json')
    local portals = pj and json.decode(pj) or {}
    for name, p in pairs(portals) do
        local key = Studio.CleanName(name)
        if key and not rooms[key] and type(p) == 'table' and type(p.shell) == 'string' and shellSet[p.shell]
            and Studio.ValidSpot(p.entrance) and Studio.ValidOffset(p.exit) then
            local room = Studio.NewRoom(key, Studio.CleanLabel(p.label) or key, p.shell, p.entrance, p.exit)
            local look = room.looks[1]
            for _, q in ipairs(type(p.props) == 'table' and p.props or {}) do
                if type(q) == 'table' and type(q.model) == 'string' and models[q.model] and Studio.ValidOffset(q) then Studio.PutPiece(look, q) end
            end
            room.updatedBy = 'import'
            room.updatedAt = os.date('!%Y-%m-%d %H:%M UTC')
            rooms[key] = room
            persist(room)
            MySQL.insert.await('INSERT INTO dps_studio_history (by_name, action, room, summary) VALUES (?, ?, ?, ?)',
                { 'import', 'import', key, 'Brought in from dps-shellbrowser' })
            nRooms = nRooms + 1
        end
    end

    for _, pair in ipairs({ { 'import/spots.txt', Studio.ParseSpotLine }, { 'import/pos_captures.txt', Studio.ParsePosLine } }) do
        local txt = LoadResourceFile(RES, pair[1]) or ''
        for line in txt:gmatch('[^\n]+') do
            local s = pair[2](line)
            if s then
                s.label = (s.label or ''):sub(1, 80)
                s.by = (s.by or ''):sub(1, 60)
                if pcall(insertSpot, s) then nSpots = nSpots + 1 end   -- one bad line never stops the rest
            end
        end
    end

    lib.print.info(('import: %d rooms, %d spots'):format(nRooms, nSpots))
end

CreateThread(function()
    for _, q in ipairs(TABLES) do MySQL.query.await(q) end
    MySQL.query.await('ALTER TABLE dps_studio_history ADD COLUMN IF NOT EXISTS pruned TINYINT NOT NULL DEFAULT 0')
    loadShells()
    for _, row in ipairs(MySQL.query.await('SELECT name, data FROM dps_studio_rooms') or {}) do
        local ok, r = pcall(json.decode, row.data)
        if ok and type(r) == 'table' and type(r.looks) == 'table' and #r.looks > 0 then
            for _, l in ipairs(r.looks) do l.pieces = type(l.pieces) == 'table' and l.pieces or {} end
            rooms[row.name] = r
        else
            lib.print.warn(('room %s has unreadable data and was skipped'):format(row.name))
        end
    end
    local ok, err = pcall(importOld)
    if not ok then lib.print.warn(('import stopped: %s'):format(tostring(err))) end
    rebuildPublic()
    ready = true
    local n = 0
    for _ in pairs(rooms) do n = n + 1 end
    lib.print.info(('ready: %d rooms, %d shells'):format(n, #shells))
    broadcast()
    for _, pid in ipairs(GetPlayers()) do
        pid = tonumber(pid)
        if pid and allowed(pid) then TriggerClientEvent('dps-studio:admin', pid, true) end
    end
end)

-- ---------------------------------------------------------------- everyone
local lastAsk = {}
lib.callback.register('dps-studio:rooms', function(src)
    local now = GetGameTimer()
    if lastAsk[src] and now - lastAsk[src] < 2000 then return {} end   -- a client asks once on start
    lastAsk[src] = now
    return publicList()
end)
AddEventHandler('playerDropped', function() lastAsk[source] = nil end)
lib.callback.register('dps-studio:isAdmin', function(src)
    local ok = allowed(src) and true or false
    lib.print.info(('%s asked for Studio: %s'):format(who(src), ok and 'admin' or 'not admin'))
    return ok
end)

-- ---------------------------------------------------------------- admin: reads
lib.callback.register('dps-studio:boot', function(src)
    if not allowed(src) then return nil end
    if #shells == 0 then loadShells() end
    local cats = furniture()
    return { rooms = summaries(), shells = shells, furniture = cats, maxPieces = Studio.MAX_PIECES, depth = Studio.DEPTH }
end)

lib.callback.register('dps-studio:roomList', function(src)
    if not allowed(src) then return nil end
    return summaries()
end)

lib.callback.register('dps-studio:spots', function(src)
    if not allowed(src) then return nil end
    return MySQL.query.await('SELECT id, kind, label, x, y, z, h, street, zone, by_name, DATE_FORMAT(created_at, "%d %b %H:%i") AS at FROM dps_studio_spots ORDER BY id DESC LIMIT 400') or {}
end)

lib.callback.register('dps-studio:history', function(src)
    if not allowed(src) then return nil end
    return MySQL.query.await('SELECT id, DATE_FORMAT(at, "%d %b %H:%i") AS at, by_name, action, room, summary, before_data IS NOT NULL AS has_before, pruned FROM dps_studio_history ORDER BY id DESC LIMIT 300') or {}
end)

-- ---------------------------------------------------------------- admin: rooms
lib.callback.register('dps-studio:roomCreate', function(src, d)
    if not allowed(src) then return false, 'Studio is for admins' end
    if type(d) ~= 'table' then return false, 'Bad data' end
    local name, label = Studio.CleanName(d.name), Studio.CleanLabel(d.label)
    if not name then return false, 'Name: letters, numbers, - or _ only, up to 32' end
    if not label then return false, 'The door words must be 1 to 40 letters' end
    if not shellSet[d.shell] then return false, 'That shell is not in the housing list' end
    if not Studio.ValidSpot(d.entrance) then return false, 'Bad door spot' end
    if not Studio.ValidOffset(d.exit) then return false, 'The way out must be inside the shell' end
    if rooms[name] and d.redo ~= true then return false, 'That name is taken. Pick another, or use Change shell or way out on that room.' end
    if not rooms[name] and d.redo == true then return false, 'That room is gone' end
    return change(src, name, rooms[name] and 'rebuild' or 'create', ('Made room %s with %s'):format(label, d.shell), function()
        local old = rooms[name]
        local room = Studio.NewRoom(name, label, d.shell, d.entrance, d.exit)
        if old and old.shell == d.shell then           -- same shell: every look survives
            room.looks, room.look, room.nextLook = old.looks, old.look, old.nextLook
        end
        rooms[name] = room
        return true
    end)
end)

lib.callback.register('dps-studio:nameCheck', function(src, name, label, redo)
    if not allowed(src) then return false, 'Studio is for admins' end
    local key = Studio.CleanName(name)
    if not key then return false, 'Short name: letters, numbers, - or _ only, up to 32' end
    if not Studio.CleanLabel(label) then return false, 'The door words must be 1 to 40 letters' end
    if redo ~= true and rooms[key] then return false, 'That name is taken. Pick another, or use Change shell or way out on that room.' end
    return true
end)

lib.callback.register('dps-studio:roomDoor', function(src, name, spot)
    if not allowed(src) then return false, 'Studio is for admins' end
    if not rooms[name] then return false, 'No room with that name' end
    if not Studio.ValidSpot(spot) then return false, 'Bad door spot' end
    return change(src, name, 'door', ('Moved the door of %s'):format(rooms[name].label), function()
        rooms[name].entrance = { x = spot.x, y = spot.y, z = spot.z, h = spot.h }
        return true
    end)
end)

lib.callback.register('dps-studio:roomLabel', function(src, name, label)
    if not allowed(src) then return false, 'Studio is for admins' end
    label = Studio.CleanLabel(label)
    if not rooms[name] then return false, 'No room with that name' end
    if not label then return false, 'The door words must be 1 to 40 letters' end
    return change(src, name, 'label', ('Renamed %s to %s'):format(rooms[name].label, label), function()
        rooms[name].label = label
        return true
    end)
end)

lib.callback.register('dps-studio:roomCopy', function(src, name, newName, label, spot)
    if not allowed(src) then return false, 'Studio is for admins' end
    local from = rooms[name]
    newName, label = Studio.CleanName(newName), Studio.CleanLabel(label)
    if not from then return false, 'No room with that name' end
    if not newName then return false, 'Name: letters, numbers, - or _ only, up to 32' end
    if rooms[newName] then return false, 'That name is taken' end
    if not label then return false, 'The door words must be 1 to 40 letters' end
    if not Studio.ValidSpot(spot) then return false, 'Bad door spot' end
    return change(src, newName, 'copy', ('Copied %s to %s'):format(from.label, label), function()
        local room = Studio.Copy(from)
        room.name, room.label = newName, label
        room.entrance = { x = spot.x, y = spot.y, z = spot.z, h = spot.h }
        rooms[newName] = room
        return true
    end)
end)

lib.callback.register('dps-studio:roomDelete', function(src, name)
    if not allowed(src) then return false, 'Studio is for admins' end
    if not rooms[name] then return false, 'No room with that name' end
    return change(src, name, 'delete', ('Removed room %s (restore it from History)'):format(rooms[name].label), function()
        rooms[name] = nil
        return true
    end)
end)

-- ---------------------------------------------------------------- admin: looks
lib.callback.register('dps-studio:lookNew', function(src, name, lookName, copy)
    if not allowed(src) then return false, 'Studio is for admins' end
    local room = rooms[name]
    lookName = Studio.CleanLabel(lookName, 30)
    if not room then return false, 'No room with that name' end
    if not lookName then return false, 'Look name: 1 to 30 letters' end
    return change(src, name, 'look', ('New look %s in %s'):format(lookName, room.label), function()
        local look, err = Studio.AddLook(room, lookName, copy and room.look or nil)
        if not look then return false, err end
        room.look = look.id
        return true
    end)
end)

lib.callback.register('dps-studio:lookSwitch', function(src, name, id)
    if not allowed(src) then return false, 'Studio is for admins' end
    local room = rooms[name]
    if not room then return false, 'No room with that name' end
    local look = Studio.FindLook(room, id)
    if not look then return false, 'That look is gone' end
    return change(src, name, 'switch', ('%s now shows %s'):format(room.label, look.name), function()
        room.look = id
        return true
    end)
end)

lib.callback.register('dps-studio:lookRename', function(src, name, id, lookName)
    if not allowed(src) then return false, 'Studio is for admins' end
    local room = rooms[name]
    lookName = Studio.CleanLabel(lookName, 30)
    if not room then return false, 'No room with that name' end
    local look = Studio.FindLook(room, id)
    if not look then return false, 'That look is gone' end
    if not lookName then return false, 'Look name: 1 to 30 letters' end
    return change(src, name, 'look', ('Renamed look %s to %s'):format(look.name, lookName), function()
        look.name = lookName
        return true
    end)
end)

lib.callback.register('dps-studio:lookDelete', function(src, name, id)
    if not allowed(src) then return false, 'Studio is for admins' end
    local room = rooms[name]
    if not room then return false, 'No room with that name' end
    local look = Studio.FindLook(room, id)
    if not look then return false, 'That look is gone' end
    return change(src, name, 'look', ('Removed look %s from %s (restore it from History)'):format(look.name, room.label), function()
        return Studio.RemoveLook(room, id)
    end)
end)

-- ---------------------------------------------------------------- admin: pieces
local LOOK_CHANGED = 'Someone switched this room to another look. Open the panel and try again.'

lib.callback.register('dps-studio:piecePut', function(src, name, piece, id, lookId)
    if not allowed(src) then return false, 'Studio is for admins' end
    local room = rooms[name]
    if not room then return false, 'No room here' end
    if lookId ~= room.look then return false, LOOK_CHANGED end
    local _, models = furniture()
    local ok, err = Studio.ValidPiece(piece, models)
    if not ok then return false, err end
    local look = Studio.ActiveLook(room)
    return change(src, name, id and 'move' or 'place', ('%s %s in %s / %s'):format(id and 'Moved' or 'Placed', piece.model, room.label, look.name), function()
        local p, e = Studio.PutPiece(look, piece, id)
        return p ~= nil, e
    end)
end)

lib.callback.register('dps-studio:pieceRemove', function(src, name, id, lookId)
    if not allowed(src) then return false, 'Studio is for admins' end
    local room = rooms[name]
    if not room then return false, 'No room here' end
    if lookId ~= room.look then return false, LOOK_CHANGED end
    local look = Studio.ActiveLook(room)
    return change(src, name, 'remove', ('Removed a piece from %s / %s'):format(room.label, look.name), function()
        return Studio.RemovePiece(look, id)
    end)
end)

-- ---------------------------------------------------------------- admin: history
lib.callback.register('dps-studio:restore', function(src, id)
    if not allowed(src) then return false, 'Studio is for admins' end
    local row = type(id) == 'number' and MySQL.single.await('SELECT room, action, summary, before_data, pruned FROM dps_studio_history WHERE id = ?', { id })
    if not row then return false, 'That history line is gone' end
    if not row.before_data then
        -- no snapshot means the room did not exist before this line. That is only true for
        -- a line that made a room; an old line whose snapshot was cleared must never delete one.
        if tonumber(row.pruned) == 1 then return false, 'That change is too old to put back' end
        if row.action ~= 'create' and row.action ~= 'copy' and row.action ~= 'import' then return false, 'Nothing to put back for this line' end
    end
    local before
    if row.before_data then
        local ok, r = pcall(json.decode, row.before_data)
        if not ok or type(r) ~= 'table' then return false, 'That snapshot cannot be read' end
        if #shells == 0 then loadShells() end
        local _, models = furniture()
        local clean, err = Studio.CleanRoom(r, shellSet, next(models) and models or nil)
        if not clean then return false, 'That snapshot cannot be used: ' .. err end
        if clean.name ~= row.room then return false, 'That snapshot belongs to another room' end
        before = clean
    end
    return change(src, row.room, 'restore', ('Restored %s to before: %s'):format(row.room, row.summary or ''), function()
        rooms[row.room] = before
        return true
    end)
end)

-- ---------------------------------------------------------------- admin: spots
lib.callback.register('dps-studio:spotSave', function(src, s)
    if not allowed(src) then return false, 'Studio is for admins' end
    if type(s) ~= 'table' or not Studio.ValidSpot(s) then return false, 'Bad spot' end
    local kind = s.kind == 'pos' and 'pos' or 'spot'
    local id = insertSpot({
        kind = kind, label = Studio.CleanLabel(s.label, 80) or '', x = s.x, y = s.y, z = s.z, h = s.h,
        propHash = math.type(s.propHash) == 'integer' and s.propHash or nil, propDist = (type(s.propDist) == 'number' and s.propDist == s.propDist and math.abs(s.propDist) < 1e4) and s.propDist or nil,
        street = type(s.street) == 'string' and s.street or '', zone = type(s.zone) == 'string' and s.zone or '', by = who(src),
    })
    lib.print.info(('%s marked %s #%s %s vec3(%.2f, %.2f, %.2f) h %.1f'):format(who(src), kind, tostring(id), s.label or '', s.x, s.y, s.z, s.h))
    return true, id
end)

AddEventHandler('playerJoining', function()
    local src = source
    if allowed(src) then TriggerClientEvent('dps-studio:admin', src, true) end
end)


-- ---------------------------------------------------------------- admin: photos
-- The photo booth (client/booth.lua) sends one small webp per piece; the server puts it on
-- the Fivemanage image host with the key kept in the server-only convar dps:fivemanage_image
-- and keeps the picture link here. Players never download the pictures; the panel shows them.
local FM_URL = 'https://api.fivemanage.com/api/v3/file/base64'
local thumbs = {}   -- model -> url
local busyUpload = {}

CreateThread(function()
    while not ready do Wait(500) end
    for _, row in ipairs(MySQL.query.await('SELECT model, url FROM dps_studio_thumbs') or {}) do thumbs[row.model] = row.url end
    local n = 0
    for _ in pairs(thumbs) do n = n + 1 end
    lib.print.info(('photos: %d on file'):format(n))
end)

-- One picture of the asking admin's game view, through screencapture (already on the server
-- for qs-housing). Returns a data URI of a 960 x 540 webp, or false.
lib.callback.register('dps-studio:shoot', function(src)
    if not allowed(src) then return false end
    if GetResourceState('screencapture') ~= 'started' then return false end
    local p, settled = promise.new(), false
    local function settle(v) if not settled then settled = true; p:resolve(v) end end
    local ok = pcall(function()
        exports.screencapture:serverCapture(src, { encoding = 'webp', maxWidth = 960, maxHeight = 540 }, settle)
    end)
    if not ok then return false end
    SetTimeout(8000, function() settle(false) end)
    local data = Citizen.Await(p)
    return type(data) == 'string' and data or false
end)

lib.callback.register('dps-studio:thumbs', function(src)
    if not allowed(src) then return nil end
    return thumbs
end)

lib.callback.register('dps-studio:thumbSave', function(src, model, b64)
    if not allowed(src) then return false, 'Studio is for admins' end
    local _, models = furniture()
    if type(model) ~= 'string' or not models[model] then return false, 'Not a library piece' end
    if type(b64) ~= 'string' or #b64 < 200 or #b64 > 120000 or b64:find('[^%w%+/=]') then return false, 'Bad picture' end
    local key = GetConvar('dps:fivemanage_image', '')
    if key == '' then return false, 'No Fivemanage key on the server' end
    if busyUpload[model] then return false, 'Already sending that one' end
    busyUpload[model] = true
    local p = promise.new()
    PerformHttpRequest(FM_URL, function(code, body)
        p:resolve({ code = code, body = body })
    end, 'POST', json.encode({ base64 = 'data:image/webp;base64,' .. b64, filename = model .. '.webp', path = 'dps-studio/thumbs', metadata = json.encode({ model = model }) }),
        { ['Content-Type'] = 'application/json', ['Authorization'] = key })
    local res = Citizen.Await(p)
    busyUpload[model] = nil
    local ok, data = pcall(json.decode, res.body or '')
    local url = ok and type(data) == 'table' and type(data.data) == 'table' and data.data.url
    if res.code ~= 200 or type(url) ~= 'string' or not url:match('^https://') then
        lib.print.warn(('photo upload for %s failed: HTTP %s %s'):format(model, tostring(res.code), tostring(res.body):sub(1, 160)))
        return false, 'Upload failed (HTTP ' .. tostring(res.code) .. ')'
    end
    thumbs[model] = url
    MySQL.query.await('INSERT INTO dps_studio_thumbs (model, url) VALUES (?, ?) ON DUPLICATE KEY UPDATE url = VALUES(url)', { model, url })
    return true, url
end)
