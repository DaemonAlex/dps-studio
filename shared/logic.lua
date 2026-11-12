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

---An interior room either names a bob74 interior, or is simply a place in the world:
---'at:x,y,z' (rounded to whole metres), for any interior or map the admin walked to.
function Studio.IsPlaceKey(s)
    return type(s) == 'string' and #s <= 40 and s:match('^at:%-?%d+,%-?%d+,%-?%d+$') ~= nil
end

function Studio.PlaceKey(p)
    return ('at:%d,%d,%d'):format(math.floor(p.x + 0.5), math.floor(p.y + 0.5), math.floor(p.z + 0.5))
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
             entrance = room.entrance, exit = room.exit, exits = room.exits, look = look and look.id or nil,
             access = Studio.PublicAccess(room.access),
             manage = Studio.CleanManage(room.manage), depth = room.depth, at = room.at,
             style = look and copyStyle(look.style) or nil, pieces = look and copyPieces(look.pieces) or {} }
end

---What the admin panel lists for a room.
function Studio.RoomSummary(room)
    local looks = {}
    for i, l in ipairs(room.looks) do looks[i] = { id = l.id, name = l.name, count = #l.pieces } end
    local active = Studio.ActiveLook(room)
    return { name = room.name, label = room.label, shell = room.shell, kind = room.kind or 'shell', ipl = room.ipl,
             style = active and copyStyle(active.style) or nil, entrance = room.entrance, exit = room.exit,
             access = room.access and Studio.CleanAccess(room.access) or { open = true }, doors = room.doors or {},
             manage = Studio.CleanManage(room.manage), exits = room.exits, depth = Studio.RoomDepth(room), at = room.at,
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
        if type(room.ipl) ~= 'string' or not ((iplSet or {})[room.ipl] or Studio.IsPlaceKey(room.ipl)) then return nil, 'Its interior is not in the list', 0 end
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

---Who may open a door (ox_doorlock door or a Studio room door). Anyone who matches ANY part:
---groups[job or gang] = lowest grade, items = key item names, characters = citizen ids,
---staff = admins, passcode. open = true means everyone, and wins over the rest.
function Studio.CleanAccess(a)
    if type(a) ~= 'table' then return { open = true } end
    local out = { open = a.open == true, staff = a.staff == true, groups = {}, items = {}, characters = {} }
    local n = 0
    for g, grade in pairs(type(a.groups) == 'table' and a.groups or {}) do
        n = n + 1
        if n > 40 then break end
        if type(g) == 'string' and g:match('^[%w_%-]+$') and #g <= 40 then
            out.groups[g] = math.max(0, math.min(50, math.floor(tonumber(grade) or 0)))
        end
    end
    for i, it in ipairs(type(a.items) == 'table' and a.items or {}) do
        if i > 20 then break end
        if type(it) == 'string' and it:match('^[%w_%-]+$') and #it <= 60 then out.items[#out.items + 1] = it end
    end
    for i, c in ipairs(type(a.characters) == 'table' and a.characters or {}) do
        if i > 40 then break end
        if type(c) == 'string' and c:match('^[%w]+$') and #c <= 20 then out.characters[#out.characters + 1] = c end
    end
    if type(a.passcode) == 'string' and a.passcode:match('^[%w]+$') and #a.passcode <= 12 then out.passcode = a.passcode end
    return out
end

---The ox_doorlock fields for an access. '' clears a field in ox_doorlock's editDoor.
function Studio.AccessToOx(a)
    a = Studio.CleanAccess(a)
    if a.open then return { groups = '', items = '', characters = '', passcode = '' } end
    return {
        groups = next(a.groups) and a.groups or '',
        items = #a.items > 0 and a.items or '',
        characters = #a.characters > 0 and a.characters or '',
        passcode = a.passcode or '',
    }
end

---Whether a player (job, grade, gang, gang grade, citizen id, has(item), isStaff) passes an access.
function Studio.AccessAllows(a, who)
    a = Studio.CleanAccess(a)
    if a.open then return true end
    if a.staff and who.staff then return true end
    for g, grade in pairs(a.groups) do
        if (who.job == g and (who.grade or 0) >= grade) or (who.gang == g and (who.gangGrade or 0) >= grade) then return true end
    end
    for _, c in ipairs(a.characters) do if c == who.citizenid then return true end end
    for _, it in ipairs(a.items) do if who.has and who.has(it) then return true end end
    return false
end

-- ---------------------------------------------------------------- room managers
-- DPS 2026-11-12 (Damon): a room is run by its owner, not by staff. The owner is a person or a
-- group (job or gang). A group owner follows the rank, never the name: whoever holds the boss
-- rank manages, until the leader lowers the bar or names other people or groups.
--   manage = { owner = { kind = 'person'|'group', id = citizen id | job or gang name },
--              grade = lowest rank of the owner group that counts as its leader (nil = boss ranks only),
--              characters = { citizen ids named as managers }, groups = { [job or gang] = lowest rank } }
-- Owner side (the owner, or the owner group's leaders) may change who manages.
-- Managers may change who gets in. Staff may do both and are the only ones who set the owner.
-- who = { citizenid, job, grade, jobBoss, gang, gangGrade, gangBoss, staff }

local function idOk(s, max) return type(s) == 'string' and s:match('^[%w_%-]+$') ~= nil and #s <= (max or 40) end
local function rank(v) return math.max(0, math.min(50, math.floor(tonumber(v) or 0))) end

---A checked copy of a room's manage block, or nil when it has no owner (then only staff manage).
function Studio.CleanManage(m)
    if type(m) ~= 'table' or type(m.owner) ~= 'table' then return nil end
    local o = m.owner
    if (o.kind ~= 'person' and o.kind ~= 'group') or not idOk(o.id) then return nil end
    local out = { owner = { kind = o.kind, id = o.id }, characters = {}, groups = {} }
    if o.kind == 'group' and m.grade ~= nil then out.grade = rank(m.grade) end
    for i, c in ipairs(type(m.characters) == 'table' and m.characters or {}) do
        if i > 40 then break end
        if type(c) == 'string' and c:match('^[%w]+$') and #c <= 20 then out.characters[#out.characters + 1] = c end
    end
    local n = 0
    for g, grade in pairs(type(m.groups) == 'table' and m.groups or {}) do
        n = n + 1
        if n > 20 then break end
        if idOk(g) then out.groups[g] = rank(grade) end
    end
    return out
end

---The owner, or a leader of the owner group. Staff count too.
function Studio.IsOwnerSide(m, who)
    if type(who) ~= 'table' then return false end
    if who.staff then return true end
    m = Studio.CleanManage(m)
    if not m then return false end
    local o = m.owner
    if o.kind == 'person' then return who.citizenid ~= nil and who.citizenid == o.id end
    for _, side in ipairs({ { who.job, who.grade, who.jobBoss }, { who.gang, who.gangGrade, who.gangBoss } }) do
        if side[1] == o.id then
            if side[3] == true then return true end                       -- the boss rank always leads
            if m.grade and (tonumber(side[2]) or 0) >= m.grade then return true end
        end
    end
    return false
end

---May this player change who gets into the room?
function Studio.MayManage(m, who)
    if Studio.IsOwnerSide(m, who) then return true end
    m = Studio.CleanManage(m)
    if not m or type(who) ~= 'table' then return false end
    for _, c in ipairs(m.characters) do if c == who.citizenid then return true end end
    for g, grade in pairs(m.groups) do
        if (who.job == g and (tonumber(who.grade) or 0) >= grade) or (who.gang == g and (tonumber(who.gangGrade) or 0) >= grade) then return true end
    end
    return false
end

local OWNER_OPS = { manager_add = true, manager_remove = true, mgroup_set = true, mgroup_remove = true, leader_grade = true }
local MANAGE_OPS = { person_add = true, person_remove = true, group_set = true, group_remove = true, passcode = true, open = true,
                     item_add = true, item_remove = true }

local function has(list, v) for i, x in ipairs(list) do if x == v then return i end end end

---One change made from the door menu. Checks the right, the values and the limits, then edits
---room.access or room.manage. Works the same on a room and on a portal (a portal is a door).
---groupSet (optional) = names that are real jobs or gangs; itemSet (optional) = real item names.
---@return boolean ok, string words (the error, or the history line)
function Studio.ManageApply(room, who, op, arg, groupSet, itemSet)
    if type(room) ~= 'table' or type(arg) ~= 'table' then return false, 'Bad request' end
    if not (OWNER_OPS[op] or MANAGE_OPS[op]) then return false, 'Unknown change' end
    local m = Studio.CleanManage(room.manage)
    if OWNER_OPS[op] then
        if not m then return false, 'This room has no owner yet. Staff set the owner first.' end
        if not Studio.IsOwnerSide(m, who) then return false, 'Only the owner or its leaders can change who manages' end
    elseif not Studio.MayManage(m, who) then
        return false, 'You do not manage this room'
    end
    local a = Studio.CleanAccess(room.access)
    local label = room.label or room.name or 'room'
    local function group()
        if not idOk(arg.group) then return nil, 'Pick a job or gang' end
        if groupSet and not groupSet[arg.group] then return nil, 'That job or gang does not exist' end
        return arg.group
    end
    local function person()
        if type(arg.cid) ~= 'string' or not arg.cid:match('^[%w]+$') or #arg.cid > 20 then return nil, 'Pick a person' end
        return arg.cid
    end
    local words

    if op == 'person_add' then
        local c, e = person(); if not c then return false, e end
        if has(a.characters, c) then return false, 'That person is already on the list' end
        if #a.characters >= 40 then return false, 'The list is full (40 people)' end
        a.characters[#a.characters + 1] = c
        words = ('%s: person added to access'):format(label)
    elseif op == 'person_remove' then
        local c, e = person(); if not c then return false, e end
        local i = has(a.characters, c); if not i then return false, 'That person is not on the list' end
        table.remove(a.characters, i)
        words = ('%s: person removed from access'):format(label)
    elseif op == 'group_set' then
        local g, e = group(); if not g then return false, e end
        local n = 0; for _ in pairs(a.groups) do n = n + 1 end
        if not a.groups[g] and n >= 40 then return false, 'The list is full (40 groups)' end
        a.groups[g] = rank(arg.grade)
        words = ('%s: %s rank %d and up may enter'):format(label, g, a.groups[g])
    elseif op == 'group_remove' then
        local g, e = group(); if not g then return false, e end
        if a.groups[g] == nil then return false, 'That group is not on the list' end
        a.groups[g] = nil
        words = ('%s: %s removed from access'):format(label, g)
    elseif op == 'item_add' or op == 'item_remove' then
        local it = arg.item
        if type(it) ~= 'string' or not it:match('^[%w_%-]+$') or #it > 60 then return false, 'Pick a key item' end
        local i = has(a.items, it)
        if op == 'item_add' then
            if itemSet and not itemSet[it] then return false, 'That item does not exist' end
            if i then return false, 'That item is already a key' end
            if #a.items >= 20 then return false, 'The list is full (20 key items)' end
            a.items[#a.items + 1] = it
            words = ('%s: %s is now a key'):format(label, it)
        else
            if not i then return false, 'That item is not a key here' end
            table.remove(a.items, i)
            words = ('%s: %s is no longer a key'):format(label, it)
        end
    elseif op == 'passcode' then
        if arg.code == nil or arg.code == '' then
            a.passcode = nil
            words = ('%s: passcode cleared'):format(label)
        else
            if type(arg.code) ~= 'string' or not arg.code:match('^[%w]+$') or #arg.code > 12 then return false, 'A passcode is 1 to 12 letters or numbers' end
            a.passcode = arg.code
            words = ('%s: passcode changed'):format(label)
        end
    elseif op == 'open' then
        a.open = arg.on == true
        words = ('%s: %s'):format(label, a.open and 'open to everyone' or 'locked to its list')
    elseif op == 'manager_add' then
        local c, e = person(); if not c then return false, e end
        if has(m.characters, c) then return false, 'That person already manages this room' end
        if #m.characters >= 40 then return false, 'The list is full (40 managers)' end
        m.characters[#m.characters + 1] = c
        words = ('%s: manager added'):format(label)
    elseif op == 'manager_remove' then
        local c, e = person(); if not c then return false, e end
        local i = has(m.characters, c); if not i then return false, 'That person is not a manager' end
        table.remove(m.characters, i)
        words = ('%s: manager removed'):format(label)
    elseif op == 'mgroup_set' then
        local g, e = group(); if not g then return false, e end
        local n = 0; for _ in pairs(m.groups) do n = n + 1 end
        if not m.groups[g] and n >= 20 then return false, 'The list is full (20 groups)' end
        m.groups[g] = rank(arg.grade)
        words = ('%s: %s rank %d and up may manage'):format(label, g, m.groups[g])
    elseif op == 'mgroup_remove' then
        local g, e = group(); if not g then return false, e end
        if m.groups[g] == nil then return false, 'That group does not manage this room' end
        m.groups[g] = nil
        words = ('%s: %s no longer manages'):format(label, g)
    elseif op == 'leader_grade' then
        if m.owner.kind ~= 'group' then return false, 'Only a group owner has ranks' end
        if arg.grade == nil then
            m.grade = nil
            words = ('%s: only the boss rank of %s leads'):format(label, m.owner.id)
        else
            m.grade = rank(arg.grade)
            words = ('%s: %s rank %d and up lead'):format(label, m.owner.id, m.grade)
        end
    end

    room.access = a
    if m then room.manage = m end
    return true, words
end

---May this player walk through the room's doors? Its managers always may (nobody locks the owner out).
function Studio.MayEnterRoom(room, who)
    if type(room) ~= 'table' then return false end
    local a = room.access
    if not a or a.open then return true end
    if Studio.AccessAllows(a, who) then return true end
    return Studio.MayManage(room.manage, who)
end

---How far under its door a shell room sits. Most rooms use Studio.DEPTH. A room on a tall roof
---needs another value, or its shell lands inside the building below (DPS 2026-11-12, Cayo Corp).
---Positive = under the door, negative = above it. 20 to 1500 m either way.
function Studio.RoomDepth(room)
    local d = type(room) == 'table' and tonumber(room.depth)
    if d and d == d and math.abs(d) >= 20 and math.abs(d) <= 1500 then return d + 0.0 end
    return Studio.DEPTH
end

---Where a shell room's shell sits and which way it faces: { x, y, z, h }, in the world.
---room.at when staff placed it by hand (/roomshell), else straight under (or above) its door, unturned.
function Studio.ShellAt(room)
    local e, a = room.entrance, room.at
    if type(a) == 'table' and Studio.ValidSpot(a) and math.abs(a.x - e.x) <= 1500 and math.abs(a.y - e.y) <= 1500 and math.abs(a.z - e.z) <= 1500 then
        return { x = a.x + 0.0, y = a.y + 0.0, z = a.z + 0.0, h = a.h % 360.0 }
    end
    return { x = e.x + 0.0, y = e.y + 0.0, z = e.z - Studio.RoomDepth(room), h = 0.0 }
end

---A spot saved inside a shell (an offset: the way out, a piece, an extra door) to its place in the
---world. A turned shell turns everything in it. With h = 0 this is the plain sum it always was.
function Studio.ToWorld(at, off)
    local r = math.rad(at.h or 0.0)
    local c, sn = math.cos(r), math.sin(r)
    return { x = at.x + off.x * c - off.y * sn, y = at.y + off.x * sn + off.y * c, z = at.z + off.z,
             h = ((off.h or 0.0) + (at.h or 0.0)) % 360.0 }
end

---The other way: a spot in the world to its offset inside the shell.
function Studio.ToLocal(at, w)
    local r = math.rad(at.h or 0.0)
    local c, sn = math.cos(r), math.sin(r)
    local dx, dy = w.x - at.x, w.y - at.y
    return { x = dx * c + dy * sn, y = -dx * sn + dy * c, z = w.z - at.z,
             h = ((w.h or 0.0) - (at.h or 0.0)) % 360.0 }
end

---Extra door pairs of a shell room: from = spot inside the shell (offset), to = spot in the world.
function Studio.CleanExits(list)
    local out = {}
    for i, e in ipairs(type(list) == 'table' and list or {}) do
        if #out >= 4 then break end
        if type(e) == 'table' and Studio.ValidOffset(e.from) and Studio.ValidSpot(e.to) then
            out[#out + 1] = { from = { x = e.from.x, y = e.from.y, z = e.from.z, h = e.from.h },
                              to = { x = e.to.x, y = e.to.y, z = e.to.z, h = e.to.h },
                              label = type(e.label) == 'string' and Studio.CleanLabel(e.label) or nil }
        end
    end
    return #out > 0 and out or nil
end

---The access every player's game is told about. The passcode itself never leaves the server:
---players only learn that there is one (code = true), and the server checks what they type.
function Studio.PublicAccess(a)
    if not a then return { open = true } end
    local out = Studio.CleanAccess(a)
    out.code = out.passcode ~= nil or nil
    out.passcode = nil
    return out
end

---Does this typed code open it? (server side)
function Studio.CodeOpens(a, code)
    a = Studio.CleanAccess(a)
    return a.passcode ~= nil and type(code) == 'string' and code == a.passcode
end

-- ---------------------------------------------------------------- portals
-- DPS 2026-11-12 (Damon): a portal joins two places. Staff make one side where they stand, go
-- wherever the other side is by any means, and add it later from the panel. A portal with one
-- side is saved but shows nothing to players until it has both.
--   portal = { id, label, a = spot, b = spot|nil, car = bool, wordsA, wordsB, access, manage }

---A checked copy of a portal as stored, or nil.
function Studio.CleanPortal(p)
    if type(p) ~= 'table' then return nil end
    local label = Studio.CleanLabel(p.label)
    if not label or not Studio.ValidSpot(p.a) then return nil end
    local function spot(s) return { x = s.x + 0.0, y = s.y + 0.0, z = s.z + 0.0, h = s.h % 360.0 } end
    local out = { id = tonumber(p.id), label = label, a = spot(p.a), car = p.car == true }
    if Studio.ValidSpot(p.b) then out.b = spot(p.b) end
    out.wordsA = type(p.wordsA) == 'string' and Studio.CleanLabel(p.wordsA) or nil
    out.wordsB = type(p.wordsB) == 'string' and Studio.CleanLabel(p.wordsB) or nil
    out.access = p.access and Studio.CleanAccess(p.access) or { open = true, staff = false, groups = {}, items = {}, characters = {} }
    out.manage = Studio.CleanManage(p.manage)
    return out
end

---What every player's game needs to run a portal. nil while it has only one side.
function Studio.PublicPortal(p)
    p = Studio.CleanPortal(p)
    if not p or not p.b then return nil end
    return { id = p.id, label = p.label, a = p.a, b = p.b, car = p.car,
             wordsA = p.wordsA or ('Enter ' .. p.label), wordsB = p.wordsB or ('Leave ' .. p.label),
             access = Studio.PublicAccess(p.access), manage = p.manage }
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
