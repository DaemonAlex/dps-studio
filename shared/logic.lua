-- SHARED (pure Lua, no game natives). Everything here is unit tested by tests/run.lua.
-- Parsing of the qs-housing config files, and the checks every room, look, piece
-- and spot passes before the server saves it.

Studio = Studio or {}

Studio.MAX_PIECES = 400      -- pieces per look; keeps a busy room smooth
Studio.MAX_LOOKS = 12        -- saved looks per room
Studio.DEPTH = 60.0          -- the shell sits this far under its door

local function num(v, lim) return type(v) == 'number' and v == v and math.abs(v) <= lim end

---Room keys: short, lower case, letters digits - _
function Studio.CleanName(s)
    if type(s) ~= 'string' then return nil end
    s = s:lower():gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', '_')
    if #s == 0 or #s > 32 or not s:match('^[%w_%-]+$') then return nil end
    return s
end

---Words a player reads: trimmed, 1..40 characters, no control characters or markup brackets
function Studio.CleanLabel(s, max)
    if type(s) ~= 'string' then return nil end
    s = s:gsub('[%c<>]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if #s == 0 or #s > (max or 40) then return nil end
    return s
end

---Reads the shell model names out of qs-housing's Config.Shells block.
---@return string[]
function Studio.ParseShells(src)
    local out, seen = {}, {}
    if type(src) ~= 'string' then return out end
    local s = src:find('Config%.Shells%s*=')
    if not s then return out end
    local first = true
    for line in src:sub(s):gmatch('[^\n]*') do
        if not first and line:match('^Config%.') then break end
        first = false
        if not line:match('^%s*%-%-') then
            local m = line:match("model%s*=%s*'([^']+)'") or line:match('model%s*=%s*"([^"]+)"')
            if m and not seen[m] then
                seen[m] = true
                out[#out + 1] = m
            end
        end
    end
    return out
end

---Reads qs-housing's furniture catalogue in a sandbox that only sees a Config table.
---@return table[] cats { key, label, items = { { object, label, img } } }
---@return table<string, boolean> models
function Studio.ParseFurniture(src, imagePath, vec)
    local cats, models = {}, {}
    if type(src) ~= 'string' then return cats, models end
    vec = vec or {}
    -- read-only views of the libraries, so the file cannot change them for our own code
    local function view(t) return setmetatable({}, { __index = t, __newindex = function() error('read only') end }) end
    local base = { math = view(math), string = view(string), table = view(table), pairs = pairs, ipairs = ipairs,
                   vector3 = vec.vector3, vec3 = vec.vec3, vector4 = vec.vector4, vec4 = vec.vec4 }
    local env = setmetatable({ Config = { ImagePath = imagePath or '' } }, { __index = base })
    local chunk = load(src, 'furniture', 't', env)
    if not chunk then return cats, models end
    -- a step limit, so a broken file can never hang the server
    local co = coroutine.create(chunk)
    if debug and debug.sethook then debug.sethook(co, function() error('furniture file ran too long') end, '', 5e7) end
    local ok = coroutine.resume(co)
    if not ok or coroutine.status(co) ~= 'dead' then return cats, models end
    -- A piece may sit in several groups (the vendor file repeats them), so duplicates are only
    -- dropped inside a group. Groups holding exactly the same pieces are shown once, with all
    -- their names ("Table · PC table · Couch table").
    local keys = {}
    for key in pairs(type(env.Config.Furniture) == 'table' and env.Config.Furniture or {}) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local bySig = {}
    for _, key in ipairs(keys) do
        local c = env.Config.Furniture[key]
        local items, seen, objs = {}, {}, {}
        for _, it in ipairs(type(c) == 'table' and type(c.items) == 'table' and c.items or {}) do
            local obj = type(it) == 'table' and it.object or nil
            if type(obj) == 'string' and obj:match('^[%w_%-]+$') and not seen[obj] then
                seen[obj] = true
                models[obj] = true
                objs[#objs + 1] = obj
                items[#items + 1] = { object = obj, label = tostring(it.label or obj), img = type(it.img) == 'string' and it.img or nil }
            end
        end
        if #items > 0 then
            table.sort(objs)
            local sig = table.concat(objs, ',')
            local label = tostring(type(c) == 'table' and c.label or key)
            local same = bySig[sig]
            if same then
                if not same.names[label] then
                    same.names[label] = true
                    same.label = same.label .. ' · ' .. label
                end
            else
                table.sort(items, function(x, y) return x.label < y.label end)
                local cat = { key = key, label = label, items = items, names = { [label] = true } }
                bySig[sig] = cat
                cats[#cats + 1] = cat
            end
        end
    end
    for _, c in ipairs(cats) do c.names = nil end
    table.sort(cats, function(x, y) return x.label < y.label end)
    return cats, models
end

---A world spot the player stood on: {x,y,z,h}
function Studio.ValidSpot(p)
    return type(p) == 'table' and num(p.x, 20000) and num(p.y, 20000) and num(p.z, 3000) and num(p.h, 720)
end

---An offset inside a shell: {x,y,z,h}, each within 300 m of the shell's spawn point
function Studio.ValidOffset(p)
    return type(p) == 'table' and num(p.x, 300) and num(p.y, 300) and num(p.z, 300) and num(p.h, 720)
end

---Checks a piece before it is saved.
function Studio.ValidPiece(p, models)
    if type(p) ~= 'table' or type(p.model) ~= 'string' or not models[p.model] then return false, 'Not a furniture item' end
    if not Studio.ValidOffset(p) then return false, 'The piece must be inside the room' end
    return true
end

---An interior style: which bob74 look an interior room shows.
---preset: 'default' (bob74's own), 'full' (everything on), 'empty' (all extras off), 'custom'.
---choice[group] = option key (one per group); on[group][option] = true (toggle groups).
local PRESETS = { default = true, full = true, empty = true, custom = true }
local function word(v) return type(v) == 'string' and #v > 0 and #v <= 48 and not v:find('[%c<>]') end
function Studio.CleanStyle(st)
    if type(st) ~= 'table' then return { preset = 'default' } end
    local out = { preset = PRESETS[st.preset] and st.preset or 'default', choice = {}, on = {} }
    local n = 0
    for g, o in pairs(type(st.choice) == 'table' and st.choice or {}) do
        n = n + 1
        if n > 40 then break end
        if word(g) and word(o) then out.choice[g] = o end
    end
    n = 0
    for g, set in pairs(type(st.on) == 'table' and st.on or {}) do
        n = n + 1
        if n > 40 then break end
        if word(g) and type(set) == 'table' then
            local t, m = {}, 0
            for k, v in pairs(set) do
                m = m + 1
                if m > 60 then break end
                if word(k) and v == true then t[k] = true end
            end
            out.on[g] = t
        end
    end
    return out
end

local function copyStyle(st) return st and Studio.CleanStyle(st) or nil end

local function copyPieces(list)
    local out = {}
    for i, q in ipairs(list or {}) do out[i] = { id = q.id, model = q.model, x = q.x, y = q.y, z = q.z, h = q.h } end
    return out
end

---A fresh interior (IPL) room: the way out is a spot inside the interior in world terms.
function Studio.NewIplRoom(name, label, ipl, entrance, exit, style)
    local room = Studio.NewRoom(name, label, nil, entrance, exit)
    room.kind, room.ipl = 'ipl', ipl
    room.looks[1].style = Studio.CleanStyle(style)
    return room
end

---A fresh room with one empty look called Default.
function Studio.NewRoom(name, label, shell, entrance, exit)
    return {
        name = name, label = label, shell = shell,
        entrance = { x = entrance.x, y = entrance.y, z = entrance.z, h = entrance.h },
        exit = { x = exit.x, y = exit.y, z = exit.z, h = exit.h },
        look = 1, nextLook = 2,
        looks = { { id = 1, name = 'Default', pieces = {}, nextPiece = 1 } },
    }
end

function Studio.FindLook(room, id)
    for i, l in ipairs(room.looks or {}) do if l.id == id then return l, i end end
end

function Studio.ActiveLook(room)
    return Studio.FindLook(room, room.look) or (room.looks or {})[1]
end

---Adds a look. copyFrom = a look id to copy pieces from, or nil for an empty look.
function Studio.AddLook(room, name, copyFrom)
    if #room.looks >= Studio.MAX_LOOKS then return nil, ('A room keeps up to %d looks'):format(Studio.MAX_LOOKS) end
    for _, l in ipairs(room.looks) do
        if l.name:lower() == name:lower() then return nil, 'That look name is taken' end
    end
    local src = copyFrom and Studio.FindLook(room, copyFrom)
    local look = { id = room.nextLook, name = name, pieces = src and copyPieces(src.pieces) or {}, nextPiece = src and src.nextPiece or 1,
                   style = src and copyStyle(src.style) or (room.kind == 'ipl' and { preset = 'default' } or nil) }
    room.nextLook = room.nextLook + 1
    room.looks[#room.looks + 1] = look
    return look
end

function Studio.RemoveLook(room, id)
    if #room.looks <= 1 then return false, 'A room needs at least one look' end
    if room.look == id then return false, 'Switch to another look first' end
    local _, i = Studio.FindLook(room, id)
    if not i then return false, 'That look is gone' end
    table.remove(room.looks, i)
    return true
end

---Adds a piece (id nil) or moves one (id given) in a look.
function Studio.PutPiece(look, p, id)
    local piece = { model = p.model, x = p.x, y = p.y, z = p.z, h = p.h % 360.0 }
    if id then
        for i, q in ipairs(look.pieces) do
            if q.id == id then piece.id = id; look.pieces[i] = piece; return piece end
        end
        return nil, 'That piece is gone'
    end
    if #look.pieces >= Studio.MAX_PIECES then return nil, ('This look is full (%d pieces)'):format(Studio.MAX_PIECES) end
    piece.id = look.nextPiece
    look.nextPiece = look.nextPiece + 1
    look.pieces[#look.pieces + 1] = piece
    return piece
end

function Studio.RemovePiece(look, id)
    for i, q in ipairs(look.pieces) do
        if q.id == id then table.remove(look.pieces, i); return true end
    end
    return false, 'That piece is gone'
end

---What every player needs to run a room: door, way out, shell and the active look's pieces.
function Studio.PublicRoom(room)
    local look = Studio.ActiveLook(room)
    return { name = room.name, label = room.label, shell = room.shell, kind = room.kind or 'shell', ipl = room.ipl,
             entrance = room.entrance, exit = room.exit, look = look and look.id or nil,
             style = look and copyStyle(look.style) or nil, pieces = look and copyPieces(look.pieces) or {} }
end

---What the admin panel lists for a room.
function Studio.RoomSummary(room)
    local looks = {}
    for i, l in ipairs(room.looks) do looks[i] = { id = l.id, name = l.name, count = #l.pieces } end
    local active = Studio.ActiveLook(room)
    return { name = room.name, label = room.label, shell = room.shell, kind = room.kind or 'shell', ipl = room.ipl,
             style = active and copyStyle(active.style) or nil, entrance = room.entrance, exit = room.exit,
             look = room.look, lookName = active and active.name or '', count = active and #active.pieces or 0,
             max = Studio.MAX_PIECES, looks = looks, updatedBy = room.updatedBy, updatedAt = room.updatedAt }
end

---Checks a whole room (from import or a History snapshot) before it goes live.
---Refuses a room whose shell or spots are wrong; drops pieces not in the catalogue.
---models may be nil when the catalogue is not loaded: then pieces are kept as they are.
---@return table|nil room, string|nil err, integer dropped
function Studio.CleanRoom(room, shellSet, models, iplSet)
    if type(room) ~= 'table' then return nil, 'Unreadable room', 0 end
    if room.kind == 'ipl' then
        if type(room.ipl) ~= 'string' or not (iplSet or {})[room.ipl] then return nil, 'Its interior is not in the list', 0 end
        if not Studio.ValidSpot(room.exit) then return nil, 'Bad way out', 0 end
    else
        room.kind = nil
        if type(room.shell) ~= 'string' or not shellSet[room.shell] then return nil, 'Its shell is not in the housing list', 0 end
        if not Studio.ValidOffset(room.exit) then return nil, 'Bad way out', 0 end
    end
    if not Studio.CleanName(room.name) or type(room.label) ~= 'string' then return nil, 'Bad name', 0 end
    if not Studio.ValidSpot(room.entrance) then return nil, 'Bad door', 0 end
    if type(room.looks) ~= 'table' or #room.looks == 0 then return nil, 'No looks', 0 end
    local dropped = 0
    for _, l in ipairs(room.looks) do
        local keep, top = {}, 0
        for _, q in ipairs(type(l.pieces) == 'table' and l.pieces or {}) do
            if type(q) == 'table' and type(q.model) == 'string' and (not models or models[q.model]) and Studio.ValidOffset(q) then
                keep[#keep + 1] = q
                if type(q.id) == 'number' and q.id > top then top = q.id end
            else
                dropped = dropped + 1
            end
        end
        l.pieces = keep
        l.nextPiece = math.max(tonumber(l.nextPiece) or 1, top + 1)
        l.style = room.kind == 'ipl' and Studio.CleanStyle(l.style) or nil
    end
    if not Studio.FindLook(room, room.look) then room.look = room.looks[1].id end
    return room, nil, dropped
end

---Deep copy through plain tables (rooms hold only strings, numbers, booleans and tables).
function Studio.Copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = Studio.Copy(v) end
    return o
end

-- Old dps-markspot line:
-- n | time | player | label | vec3(x, y, z) | heading h | prop <hash> @ <d>m | street | zone
function Studio.ParseSpotLine(line)
    if type(line) ~= 'string' then return nil end
    local parts = {}
    for p in (line .. ' | '):gmatch('(.-) | ') do parts[#parts + 1] = p end
    if #parts < 7 then return nil end
    local x, y, z = parts[5]:match('vec3%(([%-%d%.]+),%s*([%-%d%.]+),%s*([%-%d%.]+)%)')
    local h = parts[6]:match('heading%s+([%-%d%.]+)')
    if not (x and y and z and h) then return nil end
    local hash, dist = parts[7]:match('prop%s+(%-?%d+)%s+@%s+([%-%d%.]+)m')
    return {
        kind = 'spot', at = parts[2], by = parts[3], label = parts[4] ~= '-' and parts[4] or '',
        x = tonumber(x), y = tonumber(y), z = tonumber(z), h = tonumber(h),
        propHash = tonumber(hash), propDist = tonumber(dist),
        street = parts[8] or '', zone = parts[9] or '',
    }
end

-- Old dps-whatobject F3 line:
-- [2026-09-03 12:00:00] Name | vector4(x, y, z, h)  heading=h
function Studio.ParsePosLine(line)
    if type(line) ~= 'string' then return nil end
    local at, by, x, y, z, h = line:match('^%[(.-)%]%s+(.-)%s+|%s+vector4%(([%-%d%.]+),%s*([%-%d%.]+),%s*([%-%d%.]+),%s*([%-%d%.]+)%)')
    if not at then return nil end
    return { kind = 'pos', at = at, by = by, label = '', x = tonumber(x), y = tonumber(y), z = tonumber(z), h = tonumber(h), street = '', zone = '' }
end

---Search words for a shell: its name plus pack, use, type and note from ShellMeta.
function Studio.ShellWords(model, meta)
    local m = meta and meta[model]
    if not m then return model:lower() end
    return (model .. ' ' .. m.pack .. ' ' .. m.use .. ' ' .. m.type .. ' ' .. (m.furnished and 'furnished' or 'empty') .. ' ' .. m.note):lower()
end

return Studio
