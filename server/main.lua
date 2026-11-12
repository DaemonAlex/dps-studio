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
local iplSet = {}
-- DPS 2026-10-21: every closed interior Studio offers (bob74 + the game's own); open-world ones are hidden
for key, info in pairs(StudioInteriorInfo or {}) do if not info.hide then iplSet[key] = true end end
local furnCats, furnModels

local function allowed(src) return src and IsPlayerAceAllowed(src, ACE) end

---The room already using an interior, other than `except` (each interior serves one room).
local function iplOwner(ipl, except)
    for n, r in pairs(rooms) do
        if n ~= except and r.kind == 'ipl' and r.ipl == ipl then return r end
    end
end
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
    [[CREATE TABLE IF NOT EXISTS dps_studio_hidden (
        model VARCHAR(96) NOT NULL,
        reason VARCHAR(16) NOT NULL DEFAULT 'hand',
        by_name VARCHAR(64) DEFAULT NULL,
        at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (model))]],
    [[CREATE TABLE IF NOT EXISTS dps_studio_doors (
        id INT NOT NULL,
        staff TINYINT NOT NULL DEFAULT 0,
        open TINYINT NOT NULL DEFAULT 0,
        room VARCHAR(32) DEFAULT NULL,
        PRIMARY KEY (id))]],
    [[CREATE TABLE IF NOT EXISTS dps_studio_meta (
        k VARCHAR(40) NOT NULL, v VARCHAR(200) DEFAULT NULL, PRIMARY KEY (k))]],
    -- DPS 2026-11-12: portals (two places joined). One row each, the whole portal as JSON like a room.
    [[CREATE TABLE IF NOT EXISTS dps_studio_portals (
        id INT NOT NULL AUTO_INCREMENT, data LONGTEXT NOT NULL,
        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (id))]],
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
    MySQL.query.await('ALTER TABLE dps_studio_doors ADD COLUMN IF NOT EXISTS open TINYINT NOT NULL DEFAULT 0')
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
    if d.kind == 'ipl' then
        -- an interior (IPL) room: the way out is a spot inside the interior, in world terms
        if type(d.ipl) ~= 'string' or not (iplSet[d.ipl] or Studio.IsPlaceKey(d.ipl)) then return false, 'That interior is not in the list' end
        if not Studio.ValidSpot(d.entrance) then return false, 'Bad door spot' end
        if not Studio.ValidSpot(d.exit) then return false, 'Bad way out' end
        if rooms[name] and d.redo ~= true then return false, 'That name is taken. Pick another, or use Change shell or way out on that room.' end
        if not rooms[name] and d.redo == true then return false, 'That room is gone' end
        local owner = iplOwner(d.ipl, name)
        if owner then return false, ('That interior already belongs to %s. Each interior serves one room.'):format(owner.label) end
        local iplLabel = Studio.IsPlaceKey(d.ipl) and 'a place in the world' or d.ipl
        if StudioInteriorInfo[d.ipl] then iplLabel = StudioInteriorInfo[d.ipl].label end
        return change(src, name, rooms[name] and 'rebuild' or 'create', ('Made room %s in %s'):format(label, iplLabel), function()
            local old = rooms[name]
            local room = Studio.NewIplRoom(name, label, d.ipl, d.entrance, d.exit, d.style)
            if old and old.kind == 'ipl' and old.ipl == d.ipl then   -- same interior: every look survives
                room.looks, room.look, room.nextLook = old.looks, old.look, old.nextLook
                Studio.ActiveLook(room).style = Studio.CleanStyle(d.style)
            end
            room.access = Studio.CleanAccess(d.access or (old and old.access))
            room.doors = old and old.doors or nil
            room.manage = old and old.manage or nil   -- DPS 2026-11-12: a rebuilt room keeps its owner and managers
            rooms[name] = room
            return true
        end)
    end
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
        room.access = Studio.CleanAccess(d.access or (old and old.access))
        room.doors = old and old.doors or nil
        room.manage = old and old.manage or nil       -- DPS 2026-11-12: a rebuilt room keeps its owner and managers
        room.depth = old and old.depth or nil         -- and its own depth, if staff gave it one
        room.at = old and old.at or nil               -- and the spot staff placed its shell at
        if old and old.shell == d.shell then room.exits = old.exits end   -- same shell: its extra doors still fit
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
    if from.kind == 'ipl' then return false, 'An interior serves one room, so interior rooms cannot be copied. Make a new room with another interior.' end
    if not label then return false, 'The door words must be 1 to 40 letters' end
    if not Studio.ValidSpot(spot) then return false, 'Bad door spot' end
    return change(src, newName, 'copy', ('Copied %s to %s'):format(from.label, label), function()
        local room = Studio.Copy(from)
        room.name, room.label = newName, label
        room.entrance = { x = spot.x, y = spot.y, z = spot.z, h = spot.h }
        -- DPS 2026-11-12: a copy is a new place. It does not inherit the owner, the managers or the
        -- extra doors (their outside spots belong to the first room).
        room.manage, room.exits, room.depth, room.at = nil, nil, nil, nil
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

lib.callback.register('dps-studio:lookStyle', function(src, name, style)
    if not allowed(src) then return false, 'Studio is for admins' end
    local room = rooms[name]
    if not room or room.kind ~= 'ipl' then return false, 'No interior room with that name' end
    local look = Studio.ActiveLook(room)
    return change(src, name, 'style', ('New style for %s / %s'):format(room.label, look.name), function()
        look.style = Studio.CleanStyle(style)
        return true
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
        local clean, err = Studio.CleanRoom(r, shellSet, next(models) and models or nil, iplSet)
        if not clean then return false, 'That snapshot cannot be used: ' .. err end
        if clean.name ~= row.room then return false, 'That snapshot belongs to another room' end
        if clean.kind == 'ipl' then
            local owner = iplOwner(clean.ipl, row.room)
            if owner then return false, ('That interior now belongs to %s. Each interior serves one room.'):format(owner.label) end
        end
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
local hidden = {}   -- model -> 'empty' (the booth saw nothing), 'big' (too big for a room) or 'hand' (an admin hid it): left out of Place for every admin
local busyUpload = {}

CreateThread(function()
    while not ready do Wait(500) end
    for _, row in ipairs(MySQL.query.await('SELECT model, url FROM dps_studio_thumbs') or {}) do thumbs[row.model] = row.url end
    for _, row in ipairs(MySQL.query.await('SELECT model, reason FROM dps_studio_hidden') or {}) do hidden[row.model] = row.reason end
    local n, h = 0, 0
    for _ in pairs(thumbs) do n = n + 1 end
    for _ in pairs(hidden) do h = h + 1 end
    lib.print.info(('photos: %d on file, %d pieces hidden'):format(n, h))
end)

local function setHidden(src, model, reason)
    if reason then
        hidden[model] = reason
        MySQL.query.await('INSERT INTO dps_studio_hidden (model, reason, by_name) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE reason = VALUES(reason), by_name = VALUES(by_name)', { model, reason, who(src) })
    else
        hidden[model] = nil
        MySQL.query.await('DELETE FROM dps_studio_hidden WHERE model = ?', { model })
    end
end

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
    return { thumbs = thumbs, hidden = hidden }
end)

-- Hide (or bring back) a library piece for every admin. Kept in dps_studio_hidden.
lib.callback.register('dps-studio:hide', function(src, model, on)
    if not allowed(src) then return false, 'Studio is for admins' end
    local _, models = furniture()
    if type(model) ~= 'string' or not models[model] then return false, 'Not a library piece' end
    setHidden(src, model, on and 'hand' or nil)
    lib.print.info(('%s %s %s'):format(who(src), on and 'hid' or 'brought back', model))
    return true
end)

-- The booth framed a piece and nothing was left once the green was cut out (the piece does not
-- spawn as a whole on its own), or it is too big for any room: it is left out of Place
-- (reason 'empty' or 'big'; the Hidden view can undo).
lib.callback.register('dps-studio:thumbEmpty', function(src, model, why)
    if not allowed(src) then return false, 'Studio is for admins' end
    local _, models = furniture()
    if type(model) ~= 'string' or not models[model] then return false, 'Not a library piece' end
    if hidden[model] ~= 'hand' then setHidden(src, model, (why == 'big' or why == 'failed') and why or 'empty') end
    return true
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
    local p, settled = promise.new(), false
    local function settle(v) if not settled then settled = true; p:resolve(v) end end
    SetTimeout(15000, function() settle({ code = 0, body = 'no answer from Fivemanage in 15 s' }) end)   -- never hang the booth on one upload
    PerformHttpRequest(FM_URL, function(code, body)
        settle({ code = code, body = body })
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


-- ---------------------------------------------------------------- admin: doors (ox_doorlock)
-- ox_doorlock stays the lock engine for every door in the city. Studio is the door maker:
-- it lists doors from ox_doorlock's own table, edits them with ox_doorlock's editDoor export,
-- and (from the admin's game) creates and removes them with ox_doorlock's own admin event.
-- "Staff only" is answered through ox_doorlock's doorAuthorization hook: no permissions change.
local staffDoors, openDoors, doorRoom = {}, {}, {}   -- ox door id -> true / true / room name

local function loadDoorMarks()
    staffDoors, openDoors, doorRoom = {}, {}, {}
    for _, r in ipairs(MySQL.query.await('SELECT id, staff, open, room FROM dps_studio_doors') or {}) do
        if tonumber(r.staff) == 1 then staffDoors[r.id] = true end
        if tonumber(r.open) == 1 then openDoors[r.id] = true end
        if r.room then doorRoom[r.id] = r.room end
    end
end

-- ox_doorlock asks every hook on each use: an "Everyone" door lets anyone lock or unlock it (a door
-- with no access in ox_doorlock would otherwise be usable by no one); a staff door lets admins.
local function registerDoorHook()
    if GetResourceState('ox_doorlock') ~= 'started' then return end
    exports.ox_doorlock:registerHook('doorAuthorization', function(p)
        if not (p and p.door) then return end
        if openDoors[p.door.id] then return true end
        if staffDoors[p.door.id] and allowed(p.source) then return true end
    end)
end

CreateThread(function()
    while not ready do Wait(500) end
    loadDoorMarks()
    registerDoorHook()
end)

AddEventHandler('onResourceStart', function(res)
    if res == 'ox_doorlock' and ready then registerDoorHook() end
end)

local function doorAllowed(src) return allowed(src) and IsPlayerAceAllowed(src, 'command.doorlock') end

local function doorRows()
    local out = {}
    for _, r in ipairs(MySQL.query.await('SELECT id, name, data FROM ox_doorlock ORDER BY id') or {}) do
        local ok, d = pcall(json.decode, r.data or '{}')
        if ok and type(d) == 'table' then
            out[#out + 1] = {
                id = r.id, name = r.name, state = d.state, coords = d.coords, double = type(d.doors) == 'table',
                access = Studio.CleanAccess({ groups = d.groups, items = type(d.items) == 'table' and (function()
                    local t = {}
                    for _, it in ipairs(d.items) do t[#t + 1] = type(it) == 'table' and it.name or it end
                    return t
                end)() or nil, characters = d.characters, staff = staffDoors[r.id], passcode = d.passcode,
                open = openDoors[r.id] == true or not (d.groups or d.items or d.characters or d.passcode or staffDoors[r.id]) }),
                autolock = d.autolock, lockpick = d.lockpick == true,
                maxDistance = d.maxDistance, room = doorRoom[r.id],
            }
        end
    end
    return out
end

local function doorRaw(id)
    return MySQL.single.await('SELECT id, name, data FROM ox_doorlock WHERE id = ?', { id })
end

local function doorHistory(src, id, action, summary, before)
    MySQL.insert.await('INSERT INTO dps_studio_history (by_name, action, room, summary, before_data) VALUES (?, ?, ?, ?, ?)',
        { who(src), action, ('door:%d'):format(id), summary:sub(1, 200), before and json.encode(before) or nil })
    lib.print.info(('%s: %s'):format(who(src), summary))
end

local function markDoor(id, staff, room, open)
    MySQL.query.await('INSERT INTO dps_studio_doors (id, staff, open, room) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE staff = VALUES(staff), open = VALUES(open), room = COALESCE(VALUES(room), room)',
        { id, staff and 1 or 0, open and 1 or 0, room })
    staffDoors[id] = staff or nil
    openDoors[id] = open or nil
    if room then doorRoom[id] = room end
end

local function unmarkDoor(id)
    MySQL.query.await('DELETE FROM dps_studio_doors WHERE id = ?', { id })
    staffDoors[id], openDoors[id], doorRoom[id] = nil, nil, nil
end

local pickers
lib.callback.register('dps-studio:doorPickers', function(src)
    if not allowed(src) then return nil end
    if not pickers then
        local jobs, items = {}, {}
        local function addGroups(list, kind)
            for name, g in pairs(list or {}) do
                local grades = {}
                for lvl, gr in pairs(type(g.grades) == 'table' and g.grades or {}) do
                    grades[#grades + 1] = { level = tonumber(lvl) or 0, name = type(gr) == 'table' and gr.name or tostring(gr) }
                end
                table.sort(grades, function(a, b) return a.level < b.level end)
                jobs[#jobs + 1] = { name = name, label = g.label or name, kind = kind, grades = grades }
            end
        end
        pcall(function() addGroups(exports.qbx_core:GetJobs(), 'job') end)
        pcall(function() addGroups(exports.qbx_core:GetGangs(), 'gang') end)
        table.sort(jobs, function(a, b) return a.label:lower() < b.label:lower() end)
        pcall(function()
            for name, it in pairs(exports.ox_inventory:Items() or {}) do items[#items + 1] = { name = name, label = it.label or name } end
        end)
        table.sort(items, function(a, b) return a.label:lower() < b.label:lower() end)
        if #jobs > 0 and #items > 0 then pickers = { jobs = jobs, items = items } end   -- keep only a full load
        return { jobs = jobs, items = items }
    end
    return pickers
end)

lib.callback.register('dps-studio:doors', function(src)
    if not allowed(src) then return nil end
    return doorRows()
end)

---Saves changes to one door. f = { name?, state?, access?, autolock?, lockpick?, maxDistance? }
local function saveDoor(src, id, f, why)
    local raw = doorRaw(id)
    if not raw then return false, 'That door is gone' end
    local fields = {}
    if f.access ~= nil then
        local a = Studio.CleanAccess(f.access)
        for k, v in pairs(Studio.AccessToOx(a)) do fields[k] = v end
        -- keep key item settings (single use, metadata) when the item names did not change
        local okR, old = pcall(json.decode, raw.data or '{}')
        if okR and type(old) == 'table' and type(old.items) == 'table' and type(fields.items) == 'table' then
            local oldNames, newNames = {}, {}
            for _, it in ipairs(old.items) do oldNames[#oldNames + 1] = type(it) == 'table' and it.name or it end
            for _, it in ipairs(fields.items) do newNames[#newNames + 1] = it end
            table.sort(oldNames); table.sort(newNames)
            if table.concat(oldNames, ',') == table.concat(newNames, ',') then fields.items = old.items end
        end
        markDoor(id, a.staff and not a.open, nil, a.open)
    end
    if f.name ~= nil then
        local n = Studio.CleanLabel(f.name, 40)
        if not n then return false, 'Door name: 1 to 40 letters' end
        fields.name = n
    end
    if f.state ~= nil then fields.state = f.state and 1 or 0 end
    if f.autolock ~= nil then
        local t = tonumber(f.autolock)
        fields.autolock = (t and t > 0) and math.floor(math.min(3600, t)) or ''
    end
    if f.lockpick ~= nil then fields.lockpick = f.lockpick == true end
    if f.maxDistance ~= nil then
        local d = tonumber(f.maxDistance)
        if d then fields.maxDistance = math.max(1.0, math.min(10.0, d)) + 0.0 end
    end
    local ok, err = pcall(function() exports.ox_doorlock:editDoor(id, fields) end)
    if not ok then return false, 'ox_doorlock refused the change: ' .. tostring(err):sub(1, 120) end
    doorHistory(src, id, 'door', ('%s door %s'):format(why or 'Changed', fields.name or raw.name), raw)
    return true
end

lib.callback.register('dps-studio:doorSave', function(src, id, f)
    if not allowed(src) then return false, 'Studio is for admins' end
    if type(id) ~= 'number' or type(f) ~= 'table' then return false, 'Bad data' end
    return saveDoor(src, id, f)
end)

-- Called from the admin's game right after it asked ox_doorlock to create a door by name.
lib.callback.register('dps-studio:doorMaxId', function(src)
    if not doorAllowed(src) then return false, 'Making doors needs the door permission (command.doorlock)' end
    return true, MySQL.scalar.await('SELECT COALESCE(MAX(id), 0) FROM ox_doorlock') or 0
end)

lib.callback.register('dps-studio:doorCreated', function(src, name, access, room, afterId)
    if not doorAllowed(src) or type(name) ~= 'string' then return false, 'Making doors needs the door permission (command.doorlock)' end
    local door
    for _ = 1, 30 do
        -- only a door saved after this request counts, so an older door with the same name never matches
        local id = MySQL.scalar.await('SELECT id FROM ox_doorlock WHERE name = ? AND id > ? ORDER BY id DESC LIMIT 1', { name, tonumber(afterId) or 0 })
        if id then door = { id = id } break end
        Wait(100)
    end
    if not door then return false, 'ox_doorlock did not save the door' end
    local a = Studio.CleanAccess(access)
    markDoor(door.id, a.staff and not a.open, type(room) == 'string' and rooms[room] and room or nil, a.open)
    if type(room) == 'string' and rooms[room] then
        change(src, room, 'doors', ('Added door %s to %s'):format(name, rooms[room].label), function()
            rooms[room].doors = rooms[room].doors or {}
            table.insert(rooms[room].doors, door.id)
            return true
        end)
    end
    doorHistory(src, door.id, 'door-create', ('Made door %s'):format(name), nil)
    return true, door.id
end)

-- Before the admin's game removes a door, keep a full copy so History can put it back.
lib.callback.register('dps-studio:doorBeforeRemove', function(src, id)
    if not doorAllowed(src) then return false, 'Removing doors needs the door permission (command.doorlock)' end
    if type(id) ~= 'number' then return false end
    local raw = doorRaw(id)
    if not raw then return false, 'That door is gone' end
    raw.marks = { staff = staffDoors[id] == true, open = openDoors[id] == true, room = doorRoom[id] }
    doorHistory(src, id, 'door-remove', ('Removed door %s (put it back from History)'):format(raw.name), raw)
    local room = doorRoom[id]
    if room and rooms[room] and rooms[room].doors then
        change(src, room, 'doors', ('Removed door %s from %s'):format(raw.name, rooms[room].label), function()
            for i, d in ipairs(rooms[room].doors) do if d == id then table.remove(rooms[room].doors, i) break end end
            return true
        end)
    end
    unmarkDoor(id)
    return true
end)

-- History for a door line: returns the saved copy. The admin's game recreates it when it is gone.
lib.callback.register('dps-studio:doorRestore', function(src, historyId)
    if not allowed(src) then return false end
    local row = type(historyId) == 'number' and MySQL.single.await('SELECT room, before_data FROM dps_studio_history WHERE id = ?', { historyId })
    if not row or not row.before_data then return false, 'Nothing to put back for this line' end
    local ok, raw = pcall(json.decode, row.before_data)
    if not ok or type(raw) ~= 'table' then return false, 'That copy cannot be read' end
    local id = tonumber(tostring(row.room):match('^door:(%d+)$'))
    local ok2, data = pcall(json.decode, raw.data or '{}')
    if not ok2 or type(data) ~= 'table' then return false, 'That copy cannot be read' end
    if id and doorRaw(id) then
        local fields = { name = raw.name, state = data.state, groups = data.groups or '', items = data.items or '',
                         characters = data.characters or '', passcode = data.passcode or '', autolock = data.autolock or '',
                         lockpick = data.lockpick == true, maxDistance = data.maxDistance }
        local okE, err = pcall(function() exports.ox_doorlock:editDoor(id, fields) end)
        if not okE then return false, tostring(err):sub(1, 120) end
        doorHistory(src, id, 'door', ('Put door %s back'):format(raw.name), nil)
        return true
    end
    data.name = raw.name
    return true, { recreate = data, marks = raw.marks }
end)

-- Change who may open every door of a server location at once (and its Studio door).
lib.callback.register('dps-studio:roomAccess', function(src, name, access)
    if not allowed(src) then return false, 'Studio is for admins' end
    local room = rooms[name]
    if not room then return false, 'No room with that name' end
    local a = Studio.CleanAccess(access)
    local okAll = change(src, name, 'access', ('New access for %s'):format(room.label), function()
        room.access = a
        return true
    end)
    if not okAll then return false, 'Not saved' end
    for _, id in ipairs(room.doors or {}) do saveDoor(src, id, { access = a }, 'Access for') end
    return true
end)

-- ---------------------------------------------------------------- drive-in rooms
-- DPS 2026-10-21 (Damon): a car driven through a drive-in room's door takes everyone in it along.
-- The driver's game moves the car; this tells the passengers' games they are inside (or out).
RegisterNetEvent('dps-studio:carried', function(name, on, ids)
    local src = source
    local room = type(name) == 'string' and rooms[name]
    if not room or room.kind ~= 'ipl' or Studio.InteriorMode(room.ipl) ~= 'drive' or type(ids) ~= 'table' then return end
    local me = GetPlayerPed(src)
    local car = me ~= 0 and GetVehiclePedIsIn(me, false) or 0
    if car == 0 or GetPedInVehicleSeat(car, -1) ~= me then return end
    for i = 1, math.min(#ids, 16) do
        local id = tonumber(ids[i])
        local ped = id and GetPlayerPed(id) or 0
        if ped ~= 0 and id ~= src and GetVehiclePedIsIn(ped, false) == car then
            TriggerClientEvent('dps-studio:carried', id, name, on == true)
        end
    end
end)


-- ---------------------------------------------------------------- room managers
-- DPS 2026-11-12 (Damon): "it can be managed by the owner or group leaders or whoever they choose so
-- admins don't have to support it". Staff set a room's owner once (/roomowner). After that the owner
-- side and the managers they name run the list from the door (G Manage, or /roommanage).
-- The rules live in shared/logic.lua (Studio.MayManage, Studio.ManageApply) and are tested there.
-- Every change goes through change(), so it is in History and can be put back.

---This player as the manage rules see them. Read on the server, never taken from the client.
local function person(src)
    local out = { staff = allowed(src) and true or false }
    pcall(function()
        local p = exports.qbx_core:GetPlayer(src)
        local pd = p and p.PlayerData or {}
        local job, gang, ci = pd.job or {}, pd.gang or {}, pd.charinfo or {}
        out.citizenid = pd.citizenid
        out.job, out.jobBoss = job.name, job.isboss == true
        out.grade = type(job.grade) == 'table' and job.grade.level or tonumber(job.grade)
        out.gang, out.gangBoss = gang.name, gang.isboss == true
        out.gangGrade = type(gang.grade) == 'table' and gang.grade.level or tonumber(gang.grade)
        out.name = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    end)
    return out
end

local groupCache, groupSetCache
---Every job and gang with its ranks (and which ranks are boss), for the pickers and the checks.
local function groupList()
    if groupCache then return groupCache, groupSetCache end
    local list, set = {}, {}
    local function add(src, kind)
        for name, g in pairs(src or {}) do
            if type(name) == 'string' and name ~= 'none' and name ~= 'unemployed' and type(g) == 'table' then
                local grades = {}
                for lvl, gr in pairs(type(g.grades) == 'table' and g.grades or {}) do
                    grades[#grades + 1] = { level = tonumber(lvl) or 0, name = type(gr) == 'table' and gr.name or tostring(gr), boss = type(gr) == 'table' and gr.isboss == true }
                end
                table.sort(grades, function(a, b) return a.level < b.level end)
                list[#list + 1] = { name = name, label = g.label or name, kind = kind, grades = grades }
                set[name] = true
            end
        end
    end
    pcall(function() add(exports.qbx_core:GetJobs(), 'job') end)
    pcall(function() add(exports.qbx_core:GetGangs(), 'gang') end)
    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    if #list > 0 then groupCache, groupSetCache = list, set end   -- keep only a real load
    return list, set
end

local function namesFor(cids)
    local out = {}
    if #cids == 0 then return out end
    local marks = string.rep('?,', #cids):sub(1, -2)
    for _, r in ipairs(MySQL.query.await('SELECT citizenid, charinfo FROM players WHERE citizenid IN (' .. marks .. ')', cids) or {}) do
        local ok, ci = pcall(json.decode, r.charinfo)
        local n = ok and type(ci) == 'table' and ((ci.firstname or '') .. ' ' .. (ci.lastname or '')) or ''
        out[r.citizenid] = n:gsub('^%s+', ''):gsub('%s+$', '')
    end
    return out
end

---Players standing within 15 m (the people a manager can add without typing an id).
local function nearby(src)
    local out = {}
    local ped = GetPlayerPed(src)
    if ped == 0 then return out end
    local at = GetEntityCoords(ped)
    for _, pid in ipairs(GetPlayers()) do
        pid = tonumber(pid)
        local other = pid and pid ~= src and GetPlayerPed(pid) or 0
        if other ~= 0 and #(GetEntityCoords(other) - at) <= 15.0 then
            local p = person(pid)
            if p.citizenid then out[#out + 1] = { cid = p.citizenid, name = (p.name and p.name ~= '') and p.name or ('id ' .. pid) } end
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

-- DPS 2026-11-12 (Damon: "the portal is like a door really, should have the same perms"): everything
-- below works on a room (its name) or on a portal ('portal:<id>'). Same owner, managers and lock.
local portalByKey, portalKeep   -- filled in by the portals section further down

local function manageTarget(key)
    if type(key) ~= 'string' then return nil end
    local id = key:match('^portal:(%d+)$')
    if id then return portalByKey and portalByKey(tonumber(id)) or nil, 'portal' end
    return rooms[key], 'room'
end

local itemCache, itemSetCache
---Every inventory item (name, label), for the key item picker and its check.
local function itemList()
    if itemCache then return itemCache, itemSetCache end
    local list, set = {}, {}
    pcall(function()
        for name, it in pairs(exports.ox_inventory:Items() or {}) do
            if type(name) == 'string' then list[#list + 1] = { name = name, label = type(it) == 'table' and it.label or name }; set[name] = true end
        end
    end)
    table.sort(list, function(a, b) return tostring(a.label):lower() < tostring(b.label):lower() end)
    if #list > 0 then itemCache, itemSetCache = list, set end
    return list, set
end

---What the door menu shows. nil when this player does not manage the room or portal.
lib.callback.register('dps-studio:manageInfo', function(src, name)
    local room = manageTarget(name)
    if not room then return nil end
    local me = person(src)
    if not Studio.MayManage(room.manage, me) then return nil end
    local access, manage = Studio.CleanAccess(room.access), Studio.CleanManage(room.manage)
    local cids, seen = {}, {}
    local function want(c) if c and not seen[c] then seen[c] = true; cids[#cids + 1] = c end end
    for _, c in ipairs(access.characters) do want(c) end
    if manage then
        for _, c in ipairs(manage.characters) do want(c) end
        if manage.owner.kind == 'person' then want(manage.owner.id) end
    end
    return { name = name, label = room.label, access = access, manage = manage,
             ownerSide = Studio.IsOwnerSide(room.manage, me), staff = me.staff,
             names = namesFor(cids), groups = groupList(), nearby = nearby(src), items = itemList() }
end)

local lastManage = {}
---One change from the door menu. The right is checked here against the live room.
lib.callback.register('dps-studio:manageDo', function(src, name, op, arg)
    local now = GetGameTimer()
    if lastManage[src] and now - lastManage[src] < 300 then return false, 'One change at a time' end
    lastManage[src] = now
    local room, kind = manageTarget(name)
    if not room then return false, 'That is gone' end
    if type(op) ~= 'string' or type(arg) ~= 'table' then return false, 'Bad request' end
    local me = person(src)
    local _, set = groupList()
    local _, items = itemList()
    -- try it on a copy first: a refused change never touches the room, and the history line is known
    local trial = Studio.Copy(room)
    local ok, words = Studio.ManageApply(trial, me, op, arg, next(set) and set or nil, next(items) and items or nil)
    if not ok then return false, words end
    if (op == 'person_add' or op == 'manager_add') and not MySQL.scalar.await('SELECT 1 FROM players WHERE citizenid = ?', { arg.cid }) then
        return false, 'Nobody has that citizen ID'
    end
    if kind == 'portal' then
        room.access, room.manage = trial.access, trial.manage
        portalKeep(src, room, words)
        return true, words
    end
    local saved, err = change(src, name, 'manage', words, function()
        room.access, room.manage = trial.access, trial.manage
        return true
    end)
    if not saved then return false, err or 'Not saved' end
    -- doors the room owns (ox_doorlock) follow the same list, as they do when staff change it
    for _, id in ipairs(room.doors or {}) do pcall(saveDoor, src, id, { access = room.access }, 'Access for') end
    return true, words
end)
AddEventHandler('playerDropped', function() lastManage[source] = nil end)

---Staff: who owns a room. owner = { kind = 'person', id = citizen id } | { kind = 'group', id = job or gang } | nil (no owner).
---A new owner starts with no managers: the old owner's choices do not carry over.
lib.callback.register('dps-studio:roomOwner', function(src, name, owner)
    if not allowed(src) then return false, 'Setting the owner is for staff' end
    local room, kind = manageTarget(name)
    if not room then return false, 'Nothing with that name' end
    local manage, words
    if owner ~= nil then
        manage = Studio.CleanManage({ owner = owner })
        if not manage then return false, 'Pick a person or a job or gang' end
        if manage.owner.kind == 'group' then
            local _, set = groupList()
            if next(set) and not set[manage.owner.id] then return false, 'That job or gang does not exist' end
            words = ('%s is now owned by %s (its boss rank manages)'):format(room.label, manage.owner.id)
        else
            if not MySQL.scalar.await('SELECT 1 FROM players WHERE citizenid = ?', { manage.owner.id }) then return false, 'Nobody has that citizen ID' end
            words = ('%s is now owned by %s'):format(room.label, namesFor({ manage.owner.id })[manage.owner.id] or manage.owner.id)
        end
    else
        words = ('%s has no owner now (staff only)'):format(room.label)
    end
    if kind == 'portal' then
        room.manage = manage
        portalKeep(src, room, words)
        return true, words
    end
    local ok, err = change(src, name, 'owner', words, function()
        room.manage = manage
        return true
    end)
    if not ok then return false, err or 'Not saved' end
    return true, words
end)

---Staff: the people near me and the group list, for the /roomowner picker.
lib.callback.register('dps-studio:ownerPickers', function(src)
    if not allowed(src) then return nil end
    local me = person(src)
    return { me = me.citizenid and { cid = me.citizenid, name = me.name } or nil, nearby = nearby(src), groups = groupList() }
end)

---Staff: one more door pair for a shell room. inside = a world spot inside the room, outside = a world spot.
lib.callback.register('dps-studio:roomExitAdd', function(src, name, inside, outside)
    if not allowed(src) then return false, 'Adding a door is for staff' end
    local room = type(name) == 'string' and rooms[name]
    if not room then return false, 'No room with that name' end
    if room.kind == 'ipl' then return false, 'Extra doors work on shell rooms only' end
    if not Studio.ValidSpot(inside) or not Studio.ValidSpot(outside) then return false, 'Bad spot' end
    local from = Studio.ToLocal(Studio.ShellAt(room), inside)   -- an offset inside the shell, wherever it sits or faces
    if not Studio.ValidOffset(from) then return false, 'The inside spot must be inside this room' end
    local list = Studio.CleanExits(room.exits) or {}
    if #list >= 4 then return false, 'A room keeps up to 4 extra doors' end
    list[#list + 1] = { from = from, to = { x = outside.x, y = outside.y, z = outside.z, h = outside.h } }
    local clean = Studio.CleanExits(list)
    if not clean or #clean ~= #list then return false, 'Bad spot' end
    local ok, err = change(src, name, 'exit', ('Extra door %d added to %s'):format(#clean, room.label), function()
        room.exits = clean
        return true
    end)
    if not ok then return false, err or 'Not saved' end
    return true, #clean
end)

lib.callback.register('dps-studio:roomExitRemove', function(src, name, index)
    if not allowed(src) then return false, 'Removing a door is for staff' end
    local room = type(name) == 'string' and rooms[name]
    if not room then return false, 'No room with that name' end
    local list = Studio.CleanExits(room.exits) or {}
    index = tonumber(index)
    if not index or not list[index] then return false, 'That extra door is gone' end
    table.remove(list, index)
    local ok, err = change(src, name, 'exit', ('Extra door %d removed from %s'):format(index, room.label), function()
        room.exits = #list > 0 and list or nil
        return true
    end)
    if not ok then return false, err or 'Not saved' end
    return true
end)

-- ---------------------------------------------------------------- room depth
-- DPS 2026-11-12 (Damon, Cayo Corp on a roof): "I think it's putting the shell inside the building".
-- A shell sits Studio.DEPTH (60 m) under its door. Under a 97 m roof that is inside the tower. Staff
-- give that room its own depth: /roomdepth <metres> at the room, or from the server console
-- studio_roomdepth <room name> <metres>. Minus = above the door. "default" puts it back to 60.
local function setDepth(src, name, value)
    local room = type(name) == 'string' and rooms[name]
    if not room then return false, 'No room with that name' end
    if room.kind == 'ipl' then return false, 'An interior room sits where the game put it' end
    local depth
    if value ~= nil and value ~= 'default' then
        depth = tonumber(value)
        if not depth or depth ~= depth or math.abs(depth) < 20 or math.abs(depth) > 1500 then return false, 'Depth is 20 to 1500 metres. Minus puts the room above its door.' end
    end
    local words = depth and ('%s now sits %d m %s its door'):format(room.label, math.abs(depth), depth > 0 and 'under' or 'above')
        or ('%s is back to the usual %d m under its door'):format(room.label, Studio.DEPTH)
    local ok, err = change(src, name, 'depth', words, function()
        room.depth = depth
        return true
    end)
    if not ok then return false, err or 'Not saved' end
    return true, words
end

lib.callback.register('dps-studio:roomDepth', function(src, name, value)
    if not allowed(src) then return false, 'Moving a room is for staff' end
    return setDepth(src, name, value)
end)

RegisterCommand('studio_roomdepth', function(src, args)
    if src ~= 0 and not allowed(src) then return end
    local ok, words = setDepth(src, args[1], args[2])
    print(('[dps-studio] studio_roomdepth: %s'):format(words or (ok and 'saved' or 'not saved')))
end, true)

-- ---------------------------------------------------------------- place the shell
-- DPS 2026-11-12 (Damon): "we need a better understanding of where the shell is and how to manoeuvre
-- it in place during creation". Staff see the shell in the world and move or turn it (/roomshell,
-- and straight after a new room is made). at = nil puts it back under its door.
lib.callback.register('dps-studio:roomShellAt', function(src, name, at)
    if not allowed(src) then return false, 'Moving a shell is for staff' end
    local room = type(name) == 'string' and rooms[name]
    if not room then return false, 'No room with that name' end
    if room.kind == 'ipl' then return false, 'An interior room sits where the game put it' end
    local clean, words
    if at ~= nil then
        if not Studio.ValidSpot(at) then return false, 'Bad spot' end
        local e = room.entrance
        if math.abs(at.x - e.x) > 1500 or math.abs(at.y - e.y) > 1500 or math.abs(at.z - e.z) > 1500 then return false, 'Keep the shell within 1500 m of its door' end
        clean = { x = at.x + 0.0, y = at.y + 0.0, z = at.z + 0.0, h = at.h % 360.0 }
        words = ('%s: shell placed %.0f m from its door, %.0f m %s, facing %.0f'):format(room.label,
            math.sqrt((at.x - e.x) ^ 2 + (at.y - e.y) ^ 2), math.abs(at.z - e.z), at.z <= e.z and 'under' or 'above', clean.h)
    else
        words = ('%s: shell back under its door'):format(room.label)
    end
    local ok, err = change(src, name, 'shell', words, function()
        room.at = clean
        return true
    end)
    if not ok then return false, err or 'Not saved' end
    return true, words
end)

-- ---------------------------------------------------------------- portals
-- DPS 2026-11-12 (Damon): "stand anywhere, create one side of the portal, stop, go to the location or do
-- whatever until I get to the destination, then pull up admin and edit the portal again adding the other
-- end". A portal with one side is kept and listed for staff; players see it once it has both sides.
-- Staff only for now (/portal, /portals, the door button on the panel). The lock uses the room rules.
local portals = {}          -- id -> portal (Studio.CleanPortal shape)
local portalsReady = false

local function portalPublic()
    local out = {}
    for _, p in pairs(portals) do
        local pub = Studio.PublicPortal(p)
        if pub then out[#out + 1] = pub end
    end
    return out
end

local function portalBroadcast() TriggerClientEvent('dps-studio:portals', -1, portalPublic()) end
portalByKey = function(id) return portals[id] end

local function portalSave(src, p, words)
    MySQL.update.await('UPDATE dps_studio_portals SET data = ? WHERE id = ?', { json.encode(p), p.id })
    MySQL.insert.await('INSERT INTO dps_studio_history (by_name, action, room, summary) VALUES (?, ?, ?, ?)',
        { who(src), 'portal', ('portal:%d'):format(p.id), words:sub(1, 200) })
    lib.print.info(('%s: %s'):format(who(src), words))
    portalBroadcast()
end
portalKeep = portalSave

CreateThread(function()
    while not ready do Wait(200) end   -- the tables exist once the room start-up has run
    for _, row in ipairs(MySQL.query.await('SELECT id, data FROM dps_studio_portals') or {}) do
        local ok, d = pcall(json.decode, row.data)
        local p = ok and Studio.CleanPortal(d)
        if p then p.id = row.id; portals[row.id] = p
        else lib.print.warn(('portal %s has unreadable data and was skipped'):format(tostring(row.id))) end
    end
    portalsReady = true
    local n, live = 0, #portalPublic()
    for _ in pairs(portals) do n = n + 1 end
    lib.print.info(('portals: %d saved, %d live'):format(n, live))
    portalBroadcast()
end)

lib.callback.register('dps-studio:portals', function() return portalPublic() end)

---Staff: every portal, finished or not, for the /portals list.
lib.callback.register('dps-studio:portalList', function(src)
    if not allowed(src) then return nil end
    local out, cids, seen = {}, {}, {}
    for _, p in pairs(portals) do
        out[#out + 1] = Studio.Copy(p)
        for _, c in ipairs(p.access and p.access.characters or {}) do if not seen[c] then seen[c] = true; cids[#cids + 1] = c end end
    end
    table.sort(out, function(a, b) return a.label:lower() < b.label:lower() end)
    return { list = out, names = namesFor(cids), groups = groupList(), nearby = nearby(src) }
end)

---Staff: a new portal with one side, where they stand.
lib.callback.register('dps-studio:portalCreate', function(src, label, spot)
    if not allowed(src) then return false, 'Portals are made by staff' end
    if not portalsReady then return false, 'Studio is still starting, try again in a moment' end
    local p = Studio.CleanPortal({ label = label, a = spot })
    if not p then return false, 'Give it a name of 1 to 40 letters' end
    local n = 0
    for _ in pairs(portals) do n = n + 1 end
    if n >= 300 then return false, 'There are 300 portals already' end
    local id = MySQL.insert.await('INSERT INTO dps_studio_portals (data) VALUES (?)', { json.encode(p) })
    if not id then return false, 'Not saved' end
    p.id = id
    portals[id] = p
    portalSave(src, p, ('Portal %s started (one side)'):format(p.label))
    return true, id
end)

---Staff: one change to a portal. what = a | b | label | wordsA | wordsB | car | delete, or a lock change
---(open, group_set, group_remove, person_add, person_remove, passcode: the same rules as a room).
lib.callback.register('dps-studio:portalSet', function(src, id, what, value)
    if not allowed(src) then return false, 'Portals are changed by staff' end
    local p = portals[tonumber(id) or -1]
    if not p then return false, 'That portal is gone' end
    local words
    if what == 'delete' then
        portals[p.id] = nil
        MySQL.query.await('DELETE FROM dps_studio_portals WHERE id = ?', { p.id })
        MySQL.insert.await('INSERT INTO dps_studio_history (by_name, action, room, summary, before_data) VALUES (?, ?, ?, ?, ?)',
            { who(src), 'portal', ('portal:%d'):format(p.id), ('Portal %s removed'):format(p.label), json.encode(p) })
        lib.print.info(('%s: Portal %s removed'):format(who(src), p.label))
        portalBroadcast()
        return true, 'Removed'
    elseif what == 'a' or what == 'b' then
        if not Studio.ValidSpot(value) then return false, 'Bad spot' end
        local had = p[what] ~= nil
        p[what] = { x = value.x + 0.0, y = value.y + 0.0, z = value.z + 0.0, h = value.h % 360.0 }
        words = ('Portal %s: %s side %s'):format(p.label, what == 'a' and 'first' or 'second', had and 'moved' or 'added')
    elseif what == 'label' then
        local l = Studio.CleanLabel(value)
        if not l then return false, 'A name is 1 to 40 letters' end
        words = ('Portal %s renamed to %s'):format(p.label, l)
        p.label = l
    elseif what == 'wordsA' or what == 'wordsB' then
        if value == nil or value == '' then p[what] = nil
        else
            local l = Studio.CleanLabel(value)
            if not l then return false, 'The words are 1 to 40 letters' end
            p[what] = l
        end
        words = ('Portal %s: new words at the %s side'):format(p.label, what == 'wordsA' and 'first' or 'second')
    elseif what == 'car' then
        p.car = value == true
        words = ('Portal %s: cars %s'):format(p.label, p.car and 'allowed' or 'not allowed')
    else
        local _, set = groupList()
        local trial = Studio.Copy(p)
        local ok, err = Studio.ManageApply(trial, { staff = true }, what, type(value) == 'table' and value or {}, next(set) and set or nil)
        if not ok then return false, err end
        if what == 'person_add' and not MySQL.scalar.await('SELECT 1 FROM players WHERE citizenid = ?', { value.cid }) then return false, 'Nobody has that citizen ID' end
        p.access = trial.access
        words = err:gsub('^' .. p.label:gsub('%p', '%%%0') .. ':', 'Portal ' .. p.label .. ':')
    end
    portalSave(src, p, words)
    return true, words
end)

-- ---------------------------------------------------------------- passcodes
-- A room or portal with a passcode: the player types it at the door and the server says yes or no.
-- The code itself is never sent to anyone's game. Five tries a minute.
local codeTries = {}
lib.callback.register('dps-studio:code', function(src, kind, key, code)
    local now = os.time()
    local t = codeTries[src]
    if not t or now - t.at > 60 then t = { at = now, n = 0 }; codeTries[src] = t end
    t.n = t.n + 1
    if t.n > 5 then return false, 'Too many tries. Wait a minute.' end
    local access
    if kind == 'room' then access = type(key) == 'string' and rooms[key] and rooms[key].access
    elseif kind == 'portal' then access = portals[tonumber(key) or -1] and portals[tonumber(key)].access end
    if not access then return false, 'Nothing to open here' end
    if Studio.CodeOpens(access, code) then t.n = 0 return true end
    return false, 'Wrong code'
end)
AddEventHandler('playerDropped', function() codeTries[source] = nil end)
