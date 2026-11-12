-- CLIENT. Room managers (DPS 2026-11-12, Damon): the owner of a room, the leaders of an owner
-- group and the people they name change who gets in, from the room's own door. No staff needed.
--   G at a room door (shown as "G Manage" to those who may), or /roommanage near a door or inside.
-- Staff set things up once:
--   /roomowner            who owns the room you are at (a person, a job or gang, or nobody)
--   /roomexit             add one more door: run it inside at the spot (face into the room), then outside at the spot (face away)
--   /roomexit remove      take an extra door away        /roomexit cancel   forget the inside spot
--   /roomshell            see the room's shell in the world and move or turn it   (/roomshell reset)
--   /roomdepth <metres>   the quick way: how far under its door the shell sits (minus = above)
-- Menus are ox_lib menus. Every change is checked and saved on the server (shared/logic.lua rules).

StudioC = StudioC or {}

local function note(kind, text) lib.notify({ type = kind, description = text }) end

---The room this player is in, or the one whose door (or extra door) they stand at.
local function roomNear()
    local here = StudioC.RoomHere and StudioC.RoomHere()
    if here then return here end
    local me = GetEntityCoords(cache.ped)
    local best, bestD
    for name, r in pairs(StudioC.rooms or {}) do
        local d = #(me - r.door)
        for _, e in ipairs(r.data.kind ~= 'ipl' and r.data.exits or {}) do
            d = math.min(d, #(me - vec3(e.to.x, e.to.y, e.to.z)))
        end
        if d <= 4.0 and (not bestD or d < bestD) then best, bestD = name, d end
    end
    return best
end

---May this player manage that room? Used for the door prompt; the server checks again on every change.
function StudioC.MayManage(name)
    local r = StudioC.rooms and StudioC.rooms[name]
    if not r then return false end
    if StudioC.isAdmin then return true end
    return Studio.MayManage(r.data.manage, StudioC.Me())
end

local function isStaff()
    if not StudioC.isAdmin then StudioC.isAdmin = lib.callback.await('dps-studio:isAdmin', false) and true or false end
    return StudioC.isAdmin
end

-- ---------------------------------------------------------------- words
local function groupOf(info, name)
    for _, g in ipairs(info.groups or {}) do if g.name == name then return g end end
end

local function groupLabel(info, name)
    local g = groupOf(info, name)
    return g and g.label or name
end

local function rankName(info, group, level)
    local g = groupOf(info, group)
    for _, gr in ipairs(g and g.grades or {}) do if gr.level == level then return gr.name end end
    return ('rank %d'):format(level)
end

local function personName(info, cid)
    local n = info.names and info.names[cid]
    return (n and n ~= '') and n or cid
end

local function ownerWords(info)
    local m = info.manage
    if not m then return 'No owner yet (staff only)' end
    if m.owner.kind == 'person' then return personName(info, m.owner.id) end
    return groupLabel(info, m.owner.id)
end

local function leaderWords(info)
    local m = info.manage
    if not m or m.owner.kind ~= 'group' then return nil end
    if m.grade then return ('%s and up, plus the boss'):format(rankName(info, m.owner.id, m.grade)) end
    return 'Boss rank only'
end

-- ---------------------------------------------------------------- pickers
---Pick a person: someone standing near, or a typed citizen ID. Returns a citizen id or nil.
local function pickPerson(info, title)
    local opts = {}
    for _, p in ipairs(info.nearby or {}) do opts[#opts + 1] = { value = p.cid, label = p.name } end
    opts[#opts + 1] = { value = '_type', label = 'Type a citizen ID' }
    local got = lib.inputDialog(title, {
        { type = 'select', label = 'Who', description = #opts > 1 and 'People standing near you' or 'Nobody is standing near you', options = opts, required = true, searchable = true },
    })
    if not got or not got[1] then return nil end
    if got[1] ~= '_type' then return got[1] end
    local typed = lib.inputDialog(title, { { type = 'input', label = 'Citizen ID', description = 'Shown on their ID card', required = true, min = 3, max = 20 } })
    local cid = typed and typed[1] and typed[1]:gsub('%s', '')
    return (cid and cid ~= '') and cid or nil
end

---Pick a job or gang and its lowest rank. Returns group name, rank level (or nil).
local function pickGroup(info, title, preset)
    local group = preset
    if not group then
        local opts = {}
        for _, g in ipairs(info.groups or {}) do opts[#opts + 1] = { value = g.name, label = ('%s (%s)'):format(g.label, g.kind) } end
        if #opts == 0 then note('error', 'The job and gang list did not load. Try again.'); return nil end
        local got = lib.inputDialog(title, { { type = 'select', label = 'Job or gang', options = opts, required = true, searchable = true } })
        if not got or not got[1] then return nil end
        group = got[1]
    end
    local g = groupOf(info, group)
    local ranks = {}
    for _, gr in ipairs(g and g.grades or {}) do
        ranks[#ranks + 1] = { value = tostring(gr.level), label = ('%d · %s%s'):format(gr.level, gr.name, gr.boss and ' (boss)' or '') }
    end
    if #ranks == 0 then ranks[1] = { value = '0', label = '0' } end
    local got = lib.inputDialog(('%s · %s'):format(title, g and g.label or group), {
        { type = 'select', label = 'Lowest rank', description = 'This rank and every rank above it', options = ranks, required = true, default = ranks[1].value },
    })
    if not got or not got[1] then return nil end
    return group, tonumber(got[1]) or 0
end

-- ---------------------------------------------------------------- the menu
local open   -- forward

---Sends one change, says what happened, and opens the menu again on the fresh list.
local function send(name, op, arg, back)
    local ok, words = lib.callback.await('dps-studio:manageDo', false, name, op, arg or {})
    note(ok and 'success' or 'error', words or (ok and 'Saved' or 'Not saved'))
    open(name, back)
end

local function confirm(header, text)
    return lib.alertDialog({ header = header, content = text, centered = true, cancel = true }) == 'confirm'
end

local function peopleMenu(info, name, forManagers)
    local list = forManagers and (info.manage and info.manage.characters or {}) or info.access.characters
    local id = forManagers and 'dps_room_mpeople' or 'dps_room_people'
    local opts = {
        { title = forManagers and 'Add a manager' or 'Add a person', icon = 'user-plus', onSelect = function()
            local cid = pickPerson(info, forManagers and 'Add a manager' or 'Add a person')
            if not cid then return open(name, id) end
            send(name, forManagers and 'manager_add' or 'person_add', { cid = cid }, id)
        end },
    }
    for _, cid in ipairs(list) do
        opts[#opts + 1] = { title = personName(info, cid), description = 'Select to remove', icon = 'user', onSelect = function()
            if confirm('Remove ' .. personName(info, cid) .. '?', forManagers and 'They will no longer manage this room.' or 'They will no longer get in by name.') then
                send(name, forManagers and 'manager_remove' or 'person_remove', { cid = cid }, id)
            else open(name, id) end
        end }
    end
    lib.registerContext({ id = id, title = forManagers and 'Managers · people' or 'Who gets in · people', menu = forManagers and 'dps_room_managers' or 'dps_room_manage', options = opts })
end

local function groupsMenu(info, name, forManagers)
    local list = forManagers and (info.manage and info.manage.groups or {}) or info.access.groups
    local id = forManagers and 'dps_room_mgroups' or 'dps_room_groups'
    local setOp, delOp = forManagers and 'mgroup_set' or 'group_set', forManagers and 'mgroup_remove' or 'group_remove'
    local opts = {
        { title = 'Add a job or gang', icon = 'users', onSelect = function()
            local g, grade = pickGroup(info, 'Add a job or gang')
            if not g then return open(name, id) end
            send(name, setOp, { group = g, grade = grade }, id)
        end },
    }
    local names = {}
    for g in pairs(list) do names[#names + 1] = g end
    table.sort(names)
    for _, g in ipairs(names) do
        opts[#opts + 1] = { title = groupLabel(info, g), description = ('%s and up. Select to change or remove'):format(rankName(info, g, list[g])), icon = 'users', onSelect = function()
            local got = lib.inputDialog(groupLabel(info, g), { { type = 'select', label = 'What to do', required = true, options = {
                { value = 'rank', label = 'Change the lowest rank' }, { value = 'remove', label = 'Remove this group' } } } })
            if not got or not got[1] then return open(name, id) end
            if got[1] == 'remove' then return send(name, delOp, { group = g }, id) end
            local _, grade = pickGroup(info, 'Lowest rank', g)
            if grade == nil then return open(name, id) end
            send(name, setOp, { group = g, grade = grade }, id)
        end }
    end
    lib.registerContext({ id = id, title = forManagers and 'Managers · jobs and gangs' or 'Who gets in · jobs and gangs', menu = forManagers and 'dps_room_managers' or 'dps_room_manage', options = opts })
end

local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

local function build(info, name)
    local a, m = info.access, info.manage
    peopleMenu(info, name, false)
    groupsMenu(info, name, false)

    local opts = {
        { title = 'Owner: ' .. ownerWords(info), description = leaderWords(info) and ('Leaders: ' .. leaderWords(info)) or nil, icon = 'crown', readOnly = true },
        { title = a.open and 'Open to everyone' or 'Locked to the list', description = a.open and 'Anyone can walk in. Select to lock it to the list below.' or 'Only the list below gets in. Select to open it to everyone.',
          icon = a.open and 'lock-open' or 'lock', onSelect = function() send(name, 'open', { on = not a.open }) end },
        { title = ('People (%d)'):format(#a.characters), description = 'Named people who get in', icon = 'user', menu = 'dps_room_people', arrow = true },
        { title = ('Jobs and gangs (%d)'):format(count(a.groups)), description = 'Groups that get in, from a rank up', icon = 'users', menu = 'dps_room_groups', arrow = true },
        { title = a.passcode and 'Passcode: set' or 'Passcode: none', description = 'Anyone with the code gets in. Select to set, change or clear it.', icon = 'key', onSelect = function()
            local got = lib.inputDialog('Passcode', { { type = 'input', label = 'New passcode', description = 'Letters and numbers, up to 12. Leave empty to clear it.', max = 12, password = true } })
            if not got then return open(name) end
            send(name, 'passcode', { code = got[1] and got[1] ~= '' and got[1] or nil })
        end },
    }

    if info.ownerSide and m then
        peopleMenu(info, name, true)
        groupsMenu(info, name, true)
        local mopts = {
            { title = ('People (%d)'):format(#m.characters), description = 'Named people who may change the list', icon = 'user-gear', menu = 'dps_room_mpeople', arrow = true },
            { title = ('Jobs and gangs (%d)'):format(count(m.groups)), description = 'Groups that may change the list, from a rank up', icon = 'users-gear', menu = 'dps_room_mgroups', arrow = true },
        }
        if m.owner.kind == 'group' then
            mopts[#mopts + 1] = { title = 'Leaders: ' .. leaderWords(info), description = ('Which ranks of %s lead this room. The boss rank always does.'):format(groupLabel(info, m.owner.id)), icon = 'ranking-star', onSelect = function()
                local got = lib.inputDialog('Leaders', { { type = 'select', label = 'Who leads', required = true, options = {
                    { value = 'boss', label = 'Boss rank only' }, { value = 'rank', label = 'A rank and up, plus the boss' } } } })
                if not got or not got[1] then return open(name, 'dps_room_managers') end
                if got[1] == 'boss' then return send(name, 'leader_grade', {}, 'dps_room_managers') end
                local _, grade = pickGroup(info, 'Leaders', m.owner.id)
                if grade == nil then return open(name, 'dps_room_managers') end
                send(name, 'leader_grade', { grade = grade }, 'dps_room_managers')
            end }
        end
        lib.registerContext({ id = 'dps_room_managers', title = 'Who manages this room', menu = 'dps_room_manage', options = mopts })
        opts[#opts + 1] = { title = 'Managers', description = 'Who else may change this list', icon = 'user-shield', menu = 'dps_room_managers', arrow = true }
    elseif not m then
        opts[#opts + 1] = { title = 'No owner yet', description = 'Staff: stand here and type /roomowner', icon = 'circle-info', readOnly = true }
    end

    lib.registerContext({ id = 'dps_room_manage', title = 'Manage · ' .. info.label, options = opts })
end

open = function(name, menu)
    local info = lib.callback.await('dps-studio:manageInfo', false, name)
    if not info then return note('error', 'You do not manage this room') end
    build(info, name)
    lib.showContext(menu or 'dps_room_manage')
end

---Opens the manage menu for a room (never blocks the caller: door prompts call this every frame loop).
function StudioC.OpenManage(name)
    CreateThread(function() open(name) end)
end

RegisterCommand('roommanage', function()
    local name = roomNear()
    if not name then return note('error', 'Stand at a room door, or inside the room') end
    StudioC.OpenManage(name)
end, false)

-- ---------------------------------------------------------------- staff: owner
RegisterCommand('roomowner', function()
    if not isStaff() then return note('error', 'Staff only') end
    local name = roomNear()
    if not name then return note('error', 'Stand at a room door, or inside the room') end
    local r = StudioC.rooms[name]
    local pick = lib.callback.await('dps-studio:ownerPickers', false)
    if not pick then return note('error', 'Staff only') end
    local opts = {}
    if pick.me then opts[#opts + 1] = { value = 'p:' .. pick.me.cid, label = 'Me (' .. ((pick.me.name and pick.me.name ~= '') and pick.me.name or pick.me.cid) .. ')' } end
    for _, p in ipairs(pick.nearby or {}) do opts[#opts + 1] = { value = 'p:' .. p.cid, label = p.name .. ' (near you)' } end
    opts[#opts + 1] = { value = 'type', label = 'A person, by citizen ID' }
    opts[#opts + 1] = { value = 'group', label = 'A job or gang' }
    opts[#opts + 1] = { value = 'none', label = 'Nobody (staff only)' }
    local got = lib.inputDialog('Owner of ' .. r.data.label, { { type = 'select', label = 'Who owns this room', required = true, options = opts, searchable = true } })
    if not got or not got[1] then return end
    local owner
    if got[1] == 'none' then
        owner = nil
    elseif got[1] == 'type' then
        local typed = lib.inputDialog('Owner of ' .. r.data.label, { { type = 'input', label = 'Citizen ID', required = true, min = 3, max = 20 } })
        if not typed or not typed[1] then return end
        owner = { kind = 'person', id = (typed[1]:gsub('%s', '')) }
    elseif got[1] == 'group' then
        local gopts = {}
        for _, g in ipairs(pick.groups or {}) do gopts[#gopts + 1] = { value = g.name, label = ('%s (%s)'):format(g.label, g.kind) } end
        local g = lib.inputDialog('Owner of ' .. r.data.label, { { type = 'select', label = 'Job or gang', description = 'Its boss rank manages the room', required = true, options = gopts, searchable = true } })
        if not g or not g[1] then return end
        owner = { kind = 'group', id = g[1] }
    else
        owner = { kind = 'person', id = got[1]:sub(3) }
    end
    local ok, words = lib.callback.await('dps-studio:roomOwner', false, name, owner)
    note(ok and 'success' or 'error', words or (ok and 'Saved' or 'Not saved'))
end, false)

-- ---------------------------------------------------------------- staff: extra doors
local pending   -- { name, spot } after the inside half of /roomexit

local function mySpot()
    local c = GetEntityCoords(cache.ped)
    return { x = c.x, y = c.y, z = c.z, h = GetEntityHeading(cache.ped) }
end

RegisterCommand('roomexit', function(_, args)
    if not isStaff() then return note('error', 'Staff only') end
    local word = args[1] and args[1]:lower()
    if word == 'cancel' then pending = nil; return note('inform', 'Extra door cancelled') end

    if word == 'remove' then
        local name = roomNear()
        local r = name and StudioC.rooms[name]
        if not r then return note('error', 'Stand at a room door, or inside the room') end
        local exits = r.data.exits or {}
        if #exits == 0 then return note('inform', r.data.label .. ' has no extra doors') end
        local opts = {}
        for i, e in ipairs(exits) do opts[#opts + 1] = { value = tostring(i), label = ('Door %d, outside at %.0f, %.0f, %.0f'):format(i, e.to.x, e.to.y, e.to.z) } end
        local got = lib.inputDialog('Remove an extra door', { { type = 'select', label = 'Which door', required = true, options = opts } })
        if not got or not got[1] then return end
        local ok, err = lib.callback.await('dps-studio:roomExitRemove', false, name, tonumber(got[1]))
        return note(ok and 'success' or 'error', ok and 'Extra door removed' or (err or 'Not removed'))
    end

    local here = StudioC.RoomHere and StudioC.RoomHere()
    if not pending then
        if not here then return note('error', 'Start inside the room: stand where the new door should be, facing into the room, and type /roomexit') end
        if StudioC.rooms[here].data.kind == 'ipl' then return note('error', 'Extra doors work on shell rooms only') end
        pending = { name = here, spot = mySpot() }
        return note('inform', 'Inside spot saved. Now stand at the outside spot, facing away from the building, and type /roomexit again. /roomexit cancel to stop.')
    end
    if here then return note('error', 'You are still inside a room. Go to the outside spot, then type /roomexit. /roomexit cancel to stop.') end
    local spot = mySpot()   -- people leaving by this door arrive here, facing the way you face now
    local ok, res = lib.callback.await('dps-studio:roomExitAdd', false, pending.name, pending.spot, spot)
    if ok then
        note('success', ('Extra door %s added. It uses the room\'s own lock.'):format(tostring(res)))
        pending = nil
    else
        note('error', res or 'Not added')
    end
end, false)

-- ---------------------------------------------------------------- staff: depth
-- /roomdepth <metres>   how far under its door this room's shell sits (minus = above). /roomdepth default = 60.
-- For a room on a tall roof, whose shell would otherwise land inside the building below.
RegisterCommand('roomdepth', function(_, args)
    if not isStaff() then return note('error', 'Staff only') end
    local name = roomNear()
    if not name then return note('error', 'Stand at a room door, or inside the room') end
    if not args[1] then
        return note('inform', ('%s sits %d m %s its door. /roomdepth <metres> to change, minus for above.')
            :format(StudioC.rooms[name].data.label, math.abs(Studio.RoomDepth(StudioC.rooms[name].data)), Studio.RoomDepth(StudioC.rooms[name].data) > 0 and 'under' or 'above'))
    end
    local ok, words = lib.callback.await('dps-studio:roomDepth', false, name, args[1])
    note(ok and 'success' or 'error', words or (ok and 'Saved' or 'Not saved'))
end, false)

-- ---------------------------------------------------------------- staff: place the shell
-- /roomshell          see this room's shell in the world and move or turn it (client/place.lua)
-- /roomshell reset    put it back under its door
RegisterCommand('roomshell', function(_, args)
    if not isStaff() then return note('error', 'Staff only') end
    local name = roomNear()
    if not name then return note('error', 'Stand at a room door, or inside the room') end
    if args[1] and args[1]:lower() == 'reset' then
        local ok, words = lib.callback.await('dps-studio:roomShellAt', false, name, nil)
        return note(ok and 'success' or 'error', words or (ok and 'Saved' or 'Not saved'))
    end
    CreateThread(function() StudioC.PlaceShell(name) end)
end, false)
