-- lua5.4 tests/run.lua [qs-housing config/main.lua] [qs-housing config/furniture.lua]
-- Loads shared/logic.lua and checks every rule the server relies on. Exits non-zero on a failure.
local function vec(...) return { ... } end
vec3, vec4, vector3, vector4 = vec3 or vec, vec4 or vec, vector3 or vec, vector4 or vec
dofile('shared/logic.lua')
dofile('shared/shellmeta.lua')
dofile('shared/ipls.lua')
dofile('shared/gameinteriors.lua')
dofile('shared/crowds.lua')

local fails, n = 0, 0
local function check(name, ok) n = n + 1; print((ok and 'PASS ' or 'FAIL ') .. name); if not ok then fails = fails + 1 end end

-- names and labels
check('name: lower-cased and spaces become _', Studio.CleanName('Green Room') == 'green_room')
check('name: bad characters refused', Studio.CleanName('green!room') == nil)
check('name: too long refused', Studio.CleanName(string.rep('a', 33)) == nil)
check('name: not a string refused', Studio.CleanName(5) == nil)
check('label: trimmed', Studio.CleanLabel('  Green Room  ') == 'Green Room')
check('label: markup brackets removed', Studio.CleanLabel('<b>Hi</b>') == 'bHi/b')
check('label: empty refused', Studio.CleanLabel('   ') == nil)
check('label: max respected', Studio.CleanLabel(string.rep('a', 41)) == nil and Studio.CleanLabel(string.rep('a', 41), 80) ~= nil)

-- shells
local shellsSrc = "Config.Other = { model = 'x' }\nConfig.Shells = {\n  { model = 'a' },\n  -- { model = 'off' },\n  { model = \"b\" },\n  { model = 'a' },\n}\nConfig.After = { model = 'y' }\n"
local sh = Studio.ParseShells(shellsSrc)
check('shells: only the block, no comments, no dups', #sh == 2 and sh[1] == 'a' and sh[2] == 'b')
check('shells: nil gives empty', #Studio.ParseShells(nil) == 0)

-- furniture
local fsrc = "Config.Furniture = { ['t'] = { label = 'Toilet', items = { { object = 'prop_a', label = 'A', img = Config.ImagePath .. 'a.png' }, { object = 'prop_b', label = 'B' }, { object = 'bad name!', label = 'C' } } }, ['e'] = { label = 'E', items = {} } }"
local cats, models = Studio.ParseFurniture(fsrc, 'nui://x/', { vec4 = vec })
check('furniture: one group, two good items', #cats == 1 and #cats[1].items == 2)
check('furniture: image path joined', cats[1].items[1].img == 'nui://x/a.png')
check('furniture: bad model name refused', models['bad name!'] == nil and models.prop_a)
check('furniture: sandbox cannot reach os', #Studio.ParseFurniture('os.exit(1)', '') == 0)
check('furniture: broken file gives empty', #Studio.ParseFurniture('this is not lua', '') == 0)
local dsrc = "Config.Furniture = { ['a'] = { label = 'Table', items = { { object = 'p1', label = 'One' }, { object = 'p2', label = 'Two' } } }, ['b'] = { label = 'PC table', items = { { object = 'p2', label = 'Two' }, { object = 'p1', label = 'One' } } }, ['c'] = { label = 'Chair', items = { { object = 'p1', label = 'One' }, { object = 'p3', label = 'Three' }, { object = 'p3', label = 'Three' } } } }"
local dc = Studio.ParseFurniture(dsrc, '', {})
local byLabel = {}; for _, c in ipairs(dc) do byLabel[c.label] = c end
check('furniture: a piece shared by groups shows in each group', byLabel['Chair'] and #byLabel['Chair'].items == 2)
check('furniture: groups with the same pieces show once, with both names', #dc == 2 and byLabel['Table · PC table'] ~= nil)
local d2 = Studio.ParseFurniture("Config.Furniture = { ['a'] = { label = 'Couch Table', items = { { object = 'p1' } } }, ['b'] = { label = 'Table', items = { { object = 'p1' } } } }", '', {})
check('furniture: a name inside another name still shows', #d2 == 1 and d2[1].label == 'Couch Table · Table')

-- spots and offsets
check('spot valid', Studio.ValidSpot({ x = 1, y = 2, z = 3, h = 4 }))
check('spot NaN refused', not Studio.ValidSpot({ x = 0/0, y = 2, z = 3, h = 4 }))
check('spot missing heading refused', not Studio.ValidSpot({ x = 1, y = 2, z = 3 }))
check('offset far refused', not Studio.ValidOffset({ x = 301, y = 0, z = 0, h = 0 }))

-- rooms, looks, pieces
local room = Studio.NewRoom('greenroom', 'Green Room', 'k4_x', { x = 690, y = 588, z = 131, h = 343 }, { x = 0, y = 1, z = 0.4, h = 2 })
check('room: starts with Default look showing', #room.looks == 1 and room.look == 1 and room.looks[1].name == 'Default')
local look = Studio.ActiveLook(room)
local p1 = Studio.PutPiece(look, { model = 'prop_a', x = 1, y = 1, z = 0, h = 370 })
check('piece: added with id 1 and heading wrapped', p1 and p1.id == 1 and p1.h == 10)
local p2 = Studio.PutPiece(look, { model = 'prop_b', x = 2, y = 1, z = 0, h = 0 })
check('piece: second gets id 2', p2 and p2.id == 2)
local mv = Studio.PutPiece(look, { model = 'prop_b', x = 3, y = 3, z = 0, h = 90 }, 2)
check('piece: move keeps id and count', mv and mv.id == 2 and #look.pieces == 2 and look.pieces[2].x == 3)
check('piece: move of missing id refused', Studio.PutPiece(look, { model = 'prop_b', x = 0, y = 0, z = 0, h = 0 }, 99) == nil)
check('piece: valid checks model list', Studio.ValidPiece({ model = 'prop_a', x = 0, y = 0, z = 0, h = 0 }, models) and not Studio.ValidPiece({ model = 'nope', x = 0, y = 0, z = 0, h = 0 }, models))
local l2 = Studio.AddLook(room, 'Halloween', room.look)
check('look: copy has the same pieces', l2 and #l2.pieces == 2 and l2.id == 2)
l2.pieces[1].x = 99
check('look: copy is separate from the original', look.pieces[1].x == 1)
check('look: duplicate name refused', select(2, Studio.AddLook(room, 'halloween')) ~= nil)
local l3 = Studio.AddLook(room, 'Empty')
check('look: empty look has no pieces', l3 and #l3.pieces == 0)
check('look: cannot remove the one showing', not Studio.RemoveLook(room, room.look))
check('look: can remove another', Studio.RemoveLook(room, l3.id) and #room.looks == 2)
room.look = 2
check('public room: shows the active look only', #Studio.PublicRoom(room).pieces == 2 and Studio.PublicRoom(room).pieces[1].x == 99)
local sum = Studio.RoomSummary(room)
check('summary: look name and count', sum.lookName == 'Halloween' and sum.count == 2 and #sum.looks == 2)
check('piece: remove works then refuses again', Studio.RemovePiece(look, 1) and not Studio.RemovePiece(look, 1))
local full = { pieces = {}, nextPiece = 1 }
for i = 1, Studio.MAX_PIECES do Studio.PutPiece(full, { model = 'prop_a', x = 0, y = 0, z = 0, h = 0 }) end
check('look: piece limit enforced', Studio.PutPiece(full, { model = 'prop_a', x = 0, y = 0, z = 0, h = 0 }) == nil)
local cp = Studio.Copy(room)
cp.looks[1].pieces[1] = nil
check('copy: deep', #room.looks[1].pieces == 1)
local r2 = Studio.NewRoom('a', 'A', 's', { x = 0, y = 0, z = 0, h = 0 }, { x = 0, y = 0, z = 0, h = 0 })
for i = 2, Studio.MAX_LOOKS do Studio.AddLook(r2, 'L' .. i) end
check('look: look limit enforced', Studio.AddLook(r2, 'one more') == nil)

-- clean-up check used by import and restore
local shellSet = { k4_x = true }
local snap = Studio.Copy(room)
check('public room carries the look id', Studio.PublicRoom(room).look == room.look)
local cr, cerr, dropped = Studio.CleanRoom(snap, shellSet, models)
check('clean room: good room passes, nothing dropped', cr ~= nil and cerr == nil and dropped == 0)
local bad = Studio.Copy(room); bad.shell = 'not_a_shell'
check('clean room: unknown shell refused', Studio.CleanRoom(bad, shellSet, models) == nil)
local junk = Studio.Copy(room); junk.looks[1].pieces[#junk.looks[1].pieces + 1] = { id = 50, model = 'evil_prop', x = 0, y = 0, z = 0, h = 0 }
local jr, _, jd = Studio.CleanRoom(junk, shellSet, models)
check('clean room: piece not in catalogue dropped', jr and jd == 1)
local far = Studio.Copy(room); far.exit = { x = 999, y = 0, z = 0, h = 0 }
check('clean room: way out far away refused', Studio.CleanRoom(far, shellSet, models) == nil)
local lost = Studio.Copy(room); lost.look = 77
check('clean room: missing active look falls back to first', Studio.CleanRoom(lost, shellSet, models).look == lost.looks[1].id)
local ids = Studio.Copy(room); ids.looks[1].nextPiece = 1; ids.looks[1].pieces = { { id = 9, model = 'prop_a', x = 0, y = 0, z = 0, h = 0 } }
check('clean room: next piece id moves past the highest', Studio.CleanRoom(ids, shellSet, models).looks[1].nextPiece == 10)
check('clean room: not a table refused', Studio.CleanRoom('x', shellSet, models) == nil)
local slow = 'local i = 0 while true do i = i + 1 end'
check('furniture: endless file is stopped', #Studio.ParseFurniture(slow, '') == 0)
check('furniture: file cannot change the string library', #Studio.ParseFurniture("string.format = nil Config.Furniture = {}", '') == 0 and string.format ~= nil)

-- interior (IPL) rooms and styles
local ist = Studio.CleanStyle({ preset = 'custom', choice = { Walls = 'plain', ['<b>'] = 'x', Big = string.rep('a', 60) }, on = { Details = { chairs = true, bad = 'yes' } } })
check('style: keeps good choices, drops bad ones', ist.preset == 'custom' and ist.choice.Walls == 'plain' and ist.choice['<b>'] == nil and ist.choice.Big == nil and ist.on.Details.chairs and ist.on.Details.bad == nil)
check('style: unknown preset becomes default', Studio.CleanStyle({ preset = 'rainbow' }).preset == 'default' and Studio.CleanStyle(nil).preset == 'default')
local iroom = Studio.NewIplRoom('club', 'Club', 'GetBikerClubhouse1Object', { x = 1, y = 2, z = 3, h = 0 }, { x = 1107, y = -3157, z = -37.5, h = 90 }, { preset = 'full' })
check('ipl room: kind, interior and style on the first look', iroom.kind == 'ipl' and iroom.ipl == 'GetBikerClubhouse1Object' and iroom.looks[1].style.preset == 'full')
local ipub = Studio.PublicRoom(iroom)
check('ipl room: public data carries kind, interior and style', ipub.kind == 'ipl' and ipub.ipl == 'GetBikerClubhouse1Object' and ipub.style.preset == 'full')
local il2 = Studio.AddLook(iroom, 'Night', iroom.look)
check('ipl room: a copied look copies the style', il2.style.preset == 'full')
local il3 = Studio.AddLook(iroom, 'Bare')
check('ipl room: a new empty look starts on the default style', il3.style.preset == 'default')
check('ipl room: clean passes with the interior in the list', Studio.CleanRoom(Studio.Copy(iroom), {}, nil, { GetBikerClubhouse1Object = true }) ~= nil)
check('ipl room: clean refuses an unknown interior', Studio.CleanRoom(Studio.Copy(iroom), {}, nil, {}) == nil)
check('shell room: public data says shell', Studio.PublicRoom(room).kind == 'shell')
check('place key: made from a spot, rounded', Studio.PlaceKey({ x = -1011.6, y = -478.2, z = 50.4 }) == 'at:-1012,-478,50')
check('place key: accepted shape only', Studio.IsPlaceKey('at:-1012,-478,50') and not Studio.IsPlaceKey('at:1,2') and not Studio.IsPlaceKey('GetX'))
local proom = Studio.NewIplRoom('movie', 'Movie Office', 'at:-1012,-478,50', { x = 1, y = 2, z = 3, h = 0 }, { x = -1011.6, y = -478.2, z = 50.4, h = 0 }, nil)
check('place room: clean passes without being in the interior list', Studio.CleanRoom(Studio.Copy(proom), {}, nil, {}) ~= nil)

-- door and room access
local acc = Studio.CleanAccess({ groups = { police = 0, bcso = '2', ['bad job!'] = 1 }, items = { 'keycard', 'no good!' }, characters = { 'ABC123' }, passcode = '1234' })
check('access: good parts kept, bad parts dropped', acc.groups.police == 0 and acc.groups.bcso == 2 and acc.groups['bad job!'] == nil and #acc.items == 1 and acc.characters[1] == 'ABC123' and acc.passcode == '1234')
check('access: nothing given means open', Studio.CleanAccess(nil).open == true)
local ox = Studio.AccessToOx(acc)
check('access to ox: fields filled', ox.groups.police == 0 and ox.items[1] == 'keycard' and ox.passcode == '1234')
local oxo = Studio.AccessToOx({ open = true })
check('access to ox: open clears every field', oxo.groups == '' and oxo.items == '' and oxo.characters == '' and oxo.passcode == '')
check('access to ox: empty lists clear', Studio.AccessToOx({ groups = {} }).groups == '')
local who = { job = 'bcso', grade = 3, citizenid = 'XYZ', has = function(i) return i == 'keycard' end }
check('allows: job at or above the grade', Studio.AccessAllows(acc, who))
check('allows: job below the grade refused', not Studio.AccessAllows({ groups = { bcso = 4 } }, who))
check('allows: key item', Studio.AccessAllows({ items = { 'keycard' } }, { has = function(i) return i == 'keycard' end }))
check('allows: named character', Studio.AccessAllows({ characters = { 'XYZ' } }, { citizenid = 'XYZ' }))
check('allows: staff only lets staff in, no one else', Studio.AccessAllows({ staff = true }, { staff = true }) and not Studio.AccessAllows({ staff = true }, { job = 'police' }))
check('allows: gang grade', Studio.AccessAllows({ groups = { ballas = 1 } }, { gang = 'ballas', gangGrade = 2 }))

-- old files
local s = Studio.ParseSpotLine('210 | 2026-09-30 07:21:11 | Schtoop | greenroom | vec3(690.36, 588.38, 131.06) | heading 343.8 | no prop within 6m | Marlowe Dr | Vinewood Hills')
check('spot line: parsed', s and s.label == 'greenroom' and s.x == 690.36 and s.h == 343.8 and s.street == 'Marlowe Dr' and s.zone == 'Vinewood Hills' and s.propHash == nil)
local s2 = Studio.ParseSpotLine('5 | 2026-09-25 10:00:00 | Schtoop | - | vec3(-1.5, 2.25, 3.0) | heading 10.0 | prop -802505806 @ 0.4m | A St | B')
check('spot line: prop and empty label', s2 and s2.label == '' and s2.propHash == -802505806 and s2.propDist == 0.4)
check('spot line: junk refused', Studio.ParseSpotLine('hello') == nil)
local p = Studio.ParsePosLine('[2026-09-03 12:00:00] Schtoop | vector4(1.00, -2.50, 3.25, 90.0)  heading=90.0')
check('pos line: parsed', p and p.x == 1 and p.y == -2.5 and p.h == 90 and p.by == 'Schtoop')
check('shell words: meta used', Studio.ShellWords('loft_shell', ShellMeta):find('fury') ~= nil)

-- live files, when given
if arg[1] then
    local f = assert(io.open(arg[1])); local live = Studio.ParseShells(f:read('a')); f:close()
    local seen, dup, missing = {}, false, 0
    for _, m in ipairs(live) do if seen[m] then dup = true end; seen[m] = true; if not ShellMeta[m] then missing = missing + 1 end end
    print(('live shells: %d, %d without a type'):format(#live, missing))
    check('live shells: some, no duplicates', #live > 0 and not dup)
end
if arg[2] then
    local f = assert(io.open(arg[2])); local lc, lm = Studio.ParseFurniture(f:read('a'), 'nui://qs-housing/web/images/', { vec4 = vec, vector4 = vec, vec3 = vec, vector3 = vec }); f:close()
    local k = 0; for _ in pairs(lm) do k = k + 1 end
    print(('live furniture: %d groups, %d pieces'):format(#lc, k))
    check('live furniture: some', k > 0)
end

local iseen, idup = {}, false
for _, e in ipairs(StudioIpls) do if iseen[e.export] then idup = true end; iseen[e.export] = true end
check('interior list: filled, no duplicates', #StudioIpls > 50 and not idup)
-- DPS 2026-10-21: the game's own closed interiors (walk-in / drive-in, one use each)
local gdup, gbad, walk, drive = false, false, 0, 0
for _, e in ipairs(StudioGameInteriors) do
    if iseen[e.key] then gdup = true end
    iseen[e.key] = true
    if type(e.name) ~= 'string' or type(e.ipl) ~= 'string' or type(e.label) ~= 'string' or type(e.at) ~= 'table' then gbad = true end
    if e.mode == 'walk' then walk = walk + 1 elseif e.mode == 'drive' then drive = drive + 1 else gbad = true end
end
check('game interiors: filled, no duplicate keys across both lists', #StudioGameInteriors > 50 and not gdup)
check('game interiors: every row complete, mode walk or drive', not gbad and walk > 0 and drive > 0)
check('game interiors: Split Sides is offered', StudioInteriorInfo.gi_v_comedy_2 ~= nil and StudioInteriorInfo.gi_v_comedy_2.label == 'Split Sides comedy club')
check('interior info: open-world bob74 places are hidden', StudioInteriorInfo.GetBahamaMamasObject.hide == true)
check('interior info: mode lookup', Studio.InteriorMode('GetGunrunningBunkerObject') == 'drive' and Studio.InteriorMode('gi_v_comedy_2') == 'walk' and Studio.InteriorMode('at:1,2,3') == 'walk')
-- DPS 2026-10-22: club crowds
local ah = StudioCrowd.DEFAULTS.after_hours
check('crowds: After Hours starts packed with a dance floor and a DJ', ah.level == 'packed' and #ah.dance >= 40 and ah.staff[1].kind == 'dj')
check('crowds: dances and patron models listed', #StudioCrowd.DANCES >= 50 and #StudioCrowd.MODELS >= 10)
check('crowds: levels off < light < packed', StudioCrowd.LEVELS.off == 0 and StudioCrowd.LEVELS.light < StudioCrowd.LEVELS.packed)
check('crowds: venue names cleaned', StudioCrowd.CleanKey('Split Sides') == 'split_sides' and StudioCrowd.CleanKey('x') == nil and StudioCrowd.CleanKey(5) == nil)
print(('interiors offered: %d walk-in, %d drive-in game ones + bob74'):format(walk, drive))
-- room managers (DPS 2026-11-12): owner = person or group, ranks respected, staff not needed
do
    local boss   = { citizenid = 'BOSS1', job = 'police', grade = 4, jobBoss = true }
    local sgt    = { citizenid = 'SGT1',  job = 'police', grade = 2, jobBoss = false }
    local cadet  = { citizenid = 'CAD1',  job = 'police', grade = 0, jobBoss = false }
    local medic  = { citizenid = 'MED1',  job = 'ambulance', grade = 3, jobBoss = false, gang = 'ballas', gangGrade = 2, gangBoss = false }
    local gboss  = { citizenid = 'GB1',   job = 'unemployed', grade = 0, gang = 'ballas', gangGrade = 3, gangBoss = true }
    local staff  = { citizenid = 'ADM1',  staff = true }
    local nobody = { citizenid = 'NOB1',  job = 'unemployed', grade = 0 }
    local groups = { police = true, ambulance = true, ballas = true }
    local function room(manage, access) return { name = 'office', label = 'Office', manage = manage, access = access or { open = false } } end

    check('manage: no owner means nil', Studio.CleanManage({ characters = { 'A' } }) == nil and Studio.CleanManage(nil) == nil)
    check('manage: bad owner kind refused', Studio.CleanManage({ owner = { kind = 'robot', id = 'x' } }) == nil)
    check('manage: bad owner id refused', Studio.CleanManage({ owner = { kind = 'person', id = 'a b;c' } }) == nil)
    local cm = Studio.CleanManage({ owner = { kind = 'group', id = 'police' }, grade = 99, characters = { 'OK1', 'bad id!' }, groups = { ballas = -5 } })
    check('manage: grade clamped, bad ids dropped', cm.grade == 50 and #cm.characters == 1 and cm.groups.ballas == 0)
    check('manage: a person owner keeps no grade', Studio.CleanManage({ owner = { kind = 'person', id = 'P1' }, grade = 3 }).grade == nil)

    local personRoom = room({ owner = { kind = 'person', id = 'BOSS1' } })
    check('owner person: the owner manages', Studio.MayManage(personRoom.manage, boss))
    check('owner person: a colleague does not', not Studio.MayManage(personRoom.manage, sgt))
    check('owner person: staff always manage', Studio.MayManage(personRoom.manage, staff))
    check('no owner: only staff manage', not Studio.MayManage(nil, boss) and Studio.MayManage(nil, staff))

    local groupRoom = room({ owner = { kind = 'group', id = 'police' } })
    check('owner group: the boss rank leads', Studio.IsOwnerSide(groupRoom.manage, boss))
    check('owner group: a lower rank does not lead', not Studio.IsOwnerSide(groupRoom.manage, sgt) and not Studio.MayManage(groupRoom.manage, sgt))
    check('owner group: another group boss does not lead', not Studio.IsOwnerSide(groupRoom.manage, gboss))
    check('owner group: a gang can own a room', Studio.IsOwnerSide({ owner = { kind = 'group', id = 'ballas' } }, gboss) and not Studio.IsOwnerSide({ owner = { kind = 'group', id = 'ballas' } }, medic))
    -- follows the rank, not the name: the old boss demoted, a new boss promoted
    local oldBoss = { citizenid = 'BOSS1', job = 'police', grade = 2, jobBoss = false }
    local newBoss = { citizenid = 'SGT1', job = 'police', grade = 4, jobBoss = true }
    check('owner group: follows the rank, not the person', not Studio.IsOwnerSide(groupRoom.manage, oldBoss) and Studio.IsOwnerSide(groupRoom.manage, newBoss))

    -- the leader lowers the bar
    local ok, words = Studio.ManageApply(groupRoom, boss, 'leader_grade', { grade = 2 }, groups)
    check('leader: lowers the bar to rank 2', ok and groupRoom.manage.grade == 2 and Studio.IsOwnerSide(groupRoom.manage, sgt) and not Studio.IsOwnerSide(groupRoom.manage, cadet))
    check('leader: the boss still leads below any bar', Studio.IsOwnerSide({ owner = { kind = 'group', id = 'police' }, grade = 50 }, boss))
    ok = Studio.ManageApply(groupRoom, boss, 'leader_grade', {}, groups)
    check('leader: bar cleared, boss only again', ok and groupRoom.manage.grade == nil and not Studio.IsOwnerSide(groupRoom.manage, sgt))
    check('leader: a person owner has no ranks', not Studio.ManageApply(personRoom, boss, 'leader_grade', { grade = 1 }, groups))

    -- the leader grants a person and another group
    ok = Studio.ManageApply(groupRoom, boss, 'manager_add', { cid = 'NOB1' }, groups)
    check('leader: names a person as manager', ok and Studio.MayManage(groupRoom.manage, nobody) and not Studio.IsOwnerSide(groupRoom.manage, nobody))
    check('leader: same person twice refused', not Studio.ManageApply(groupRoom, boss, 'manager_add', { cid = 'NOB1' }, groups))
    ok = Studio.ManageApply(groupRoom, boss, 'mgroup_set', { group = 'ballas', grade = 3 }, groups)
    check('leader: another group manages from its rank up', ok and Studio.MayManage(groupRoom.manage, gboss) and not Studio.MayManage(groupRoom.manage, medic))
    check('leader: unknown group refused', not Studio.ManageApply(groupRoom, boss, 'mgroup_set', { group = 'ghosts', grade = 0 }, groups))
    check('manager: cannot change who manages', not Studio.ManageApply(groupRoom, nobody, 'manager_add', { cid = 'MED1' }, groups))
    check('manager: cannot move the leader bar', not Studio.ManageApply(groupRoom, nobody, 'leader_grade', { grade = 0 }, groups))
    check('outsider: cannot change access', not Studio.ManageApply(groupRoom, cadet, 'person_add', { cid = 'CAD1' }, groups))

    -- managers change who gets in
    ok = Studio.ManageApply(groupRoom, nobody, 'group_set', { group = 'police', grade = 2 }, groups)
    check('access: group added with a lowest rank', ok and Studio.AccessAllows(groupRoom.access, sgt) and not Studio.AccessAllows(groupRoom.access, cadet))
    ok = Studio.ManageApply(groupRoom, nobody, 'group_set', { group = 'police', grade = 0 }, groups)
    check('access: rank changed in place', ok and Studio.AccessAllows(groupRoom.access, cadet))
    ok = Studio.ManageApply(groupRoom, nobody, 'person_add', { cid = 'MED1' }, groups)
    check('access: person added', ok and Studio.AccessAllows(groupRoom.access, medic))
    ok = Studio.ManageApply(groupRoom, nobody, 'person_remove', { cid = 'MED1' }, groups)
    check('access: person removed', ok and not Studio.AccessAllows(groupRoom.access, medic))
    check('access: removing someone not listed refused', not Studio.ManageApply(groupRoom, nobody, 'person_remove', { cid = 'MED1' }, groups))
    ok = Studio.ManageApply(groupRoom, nobody, 'group_remove', { group = 'police' }, groups)
    check('access: group removed', ok and not Studio.AccessAllows(groupRoom.access, sgt))
    check('access: passcode set', Studio.ManageApply(groupRoom, nobody, 'passcode', { code = 'abc123' }, groups) and groupRoom.access.passcode == 'abc123')
    check('access: bad passcode refused', not Studio.ManageApply(groupRoom, nobody, 'passcode', { code = 'has space' }, groups) and groupRoom.access.passcode == 'abc123')
    check('access: passcode cleared', Studio.ManageApply(groupRoom, nobody, 'passcode', {}, groups) and groupRoom.access.passcode == nil)
    check('access: open to everyone and back', Studio.ManageApply(groupRoom, nobody, 'open', { on = true }, groups) and groupRoom.access.open == true
        and Studio.ManageApply(groupRoom, nobody, 'open', { on = false }, groups) and groupRoom.access.open == false)
    check('access: unknown change refused', not Studio.ManageApply(groupRoom, boss, 'delete_room', {}, groups))
    check('access: no owner, a player changes nothing', not Studio.ManageApply(room(nil), boss, 'person_add', { cid = 'X1' }, groups))
    check('access: no owner, staff still can', Studio.ManageApply(room(nil), staff, 'person_add', { cid = 'X1' }, groups))
    check('owner ops: no owner, even staff are told to set one', not Studio.ManageApply(room(nil), staff, 'manager_add', { cid = 'X1' }, groups))

    -- nobody is locked out of their own room
    local locked = room({ owner = { kind = 'group', id = 'police' } }, { open = false })
    check('entry: the leader gets in with an empty list', Studio.MayEnterRoom(locked, boss) and not Studio.MayEnterRoom(locked, sgt))
    check('entry: a named manager gets in', Studio.MayEnterRoom(room({ owner = { kind = 'person', id = 'P9' }, characters = { 'NOB1' } }), nobody))
    check('entry: an open room lets everyone in', Studio.MayEnterRoom(room(nil, { open = true }), nobody))
    -- a named manager who leaves the group keeps the right; a rank holder who loses the rank does not
    local left = { citizenid = 'NOB1', job = 'unemployed', grade = 0 }
    check('named manager keeps the right after leaving a group', Studio.MayManage(groupRoom.manage, left))
    local demoted = { citizenid = 'GB1', gang = 'ballas', gangGrade = 1, gangBoss = false }
    check('rank manager loses the right with the rank', not Studio.MayManage(groupRoom.manage, demoted))

    -- the manage block reaches players and the panel, and survives a copy
    local pub = Studio.PublicRoom({ name = 'o', label = 'O', shell = 's', entrance = {}, exit = {}, look = 1, looks = { { id = 1, name = 'Default', pieces = {} } }, manage = groupRoom.manage })
    check('public room carries the manage block', pub.manage and pub.manage.owner.id == 'police')

    -- extra doors
    local ex = Studio.CleanExits({ { from = { x = 1, y = 2, z = 0, h = 90 }, to = { x = 100, y = 200, z = 30, h = 0 } }, { from = { x = 999, y = 0, z = 0, h = 0 }, to = { x = 1, y = 1, z = 1, h = 0 } }, 'junk' })
    check('exits: good pair kept, bad ones dropped', ex and #ex == 1 and ex[1].to.x == 100)
    check('exits: none gives nil', Studio.CleanExits({}) == nil and Studio.CleanExits(nil) == nil)
    local many = {}
    for i = 1, 9 do many[i] = { from = { x = 0, y = 0, z = 0, h = 0 }, to = { x = i, y = 0, z = 0, h = 0 } } end
    check('exits: at most 4', #Studio.CleanExits(many) == 4)
end


-- room depth (DPS 2026-11-12): a roof room needs its own depth
check('depth: default when not set', Studio.RoomDepth({}) == Studio.DEPTH and Studio.RoomDepth(nil) == Studio.DEPTH)
check('depth: own value used, under or above', Studio.RoomDepth({ depth = 140 }) == 140 and Studio.RoomDepth({ depth = -400 }) == -400)
check('depth: too small, too big or junk falls back', Studio.RoomDepth({ depth = 5 }) == Studio.DEPTH and Studio.RoomDepth({ depth = 9999 }) == Studio.DEPTH and Studio.RoomDepth({ depth = 'x' }) == Studio.DEPTH)

-- place the shell (DPS 2026-11-12): a hand-placed, turned shell carries everything inside it
do
    local function near(a, b) return math.abs(a - b) < 1e-6 end
    local door = { x = 100, y = 200, z = 97, h = 0 }
    local under = Studio.ShellAt({ entrance = door })
    check('shell: default is straight under the door, unturned', under.x == 100 and under.y == 200 and under.z == 97 - Studio.DEPTH and under.h == 0)
    check('shell: own depth respected', Studio.ShellAt({ entrance = door, depth = -400 }).z == 497)
    local placed = Studio.ShellAt({ entrance = door, at = { x = 110, y = 190, z = 50, h = 450 } })
    check('shell: hand-placed spot wins, heading wrapped', placed.x == 110 and placed.z == 50 and placed.h == 90)
    check('shell: a spot too far from the door is ignored', Studio.ShellAt({ entrance = door, at = { x = 9000, y = 200, z = 50, h = 0 } }).z == 97 - Studio.DEPTH)
    check('shell: junk spot is ignored', Studio.ShellAt({ entrance = door, at = { x = 'a' } }).z == 97 - Studio.DEPTH)
    local off = { x = 3, y = 4, z = 1, h = 10 }
    local w0 = Studio.ToWorld(under, off)
    check('offset: unturned shell is the plain sum, as before', w0.x == 103 and w0.y == 204 and w0.z == 97 - Studio.DEPTH + 1 and w0.h == 10)
    local at90 = { x = 0, y = 0, z = 0, h = 90 }
    local w90 = Studio.ToWorld(at90, { x = 0, y = 1, z = 0, h = 0 })
    check('offset: heading 90 turns forward to face west', near(w90.x, -1) and near(w90.y, 0) and w90.h == 90)
    local wr = Studio.ToWorld(at90, { x = 1, y = 0, z = 2, h = 350 })
    check('offset: right turns to north, heading wraps', near(wr.x, 0) and near(wr.y, 1) and wr.z == 2 and wr.h == 80)
    local any = { x = 12.5, y = -40.25, z = 7, h = 123 }
    local back = Studio.ToLocal(any, Studio.ToWorld(any, off))
    check('offset: there and back gives the same spot', near(back.x, 3) and near(back.y, 4) and near(back.z, 1) and near(back.h, 10))
    local pub = Studio.PublicRoom({ name = 'o', label = 'O', shell = 's', entrance = door, exit = off, look = 1, looks = { { id = 1, name = 'Default', pieces = {} } }, at = { x = 1, y = 2, z = 3, h = 4 } })
    check('public room carries the shell spot', pub.at and pub.at.z == 3)
end

-- portals and passcodes (DPS 2026-11-12)
do
    local A, B = { x = 1, y = 2, z = 3, h = 370 }, { x = 100, y = 200, z = 30, h = 90 }
    check('portal: needs a label and one good side', Studio.CleanPortal({ label = 'Lift', a = A }) ~= nil and Studio.CleanPortal({ label = '', a = A }) == nil and Studio.CleanPortal({ label = 'Lift', a = { x = 'no' } }) == nil)
    check('portal: one side is saved but not shown to players', Studio.CleanPortal({ label = 'Lift', a = A }).b == nil and Studio.PublicPortal({ label = 'Lift', a = A }) == nil)
    local pub = Studio.PublicPortal({ id = 7, label = 'Lift', a = A, b = B })
    check('portal: both sides make it live, heading wrapped', pub and pub.id == 7 and pub.a.h == 10 and pub.b.x == 100)
    check('portal: default words from the label', pub.wordsA == 'Enter Lift' and pub.wordsB == 'Leave Lift')
    check('portal: own words kept', Studio.PublicPortal({ label = 'Lift', a = A, b = B, wordsA = 'Go up', wordsB = 'Go down' }).wordsA == 'Go up')
    check('portal: open to everyone unless locked', pub.access.open == true)
    local locked = Studio.PublicPortal({ label = 'Lift', a = A, b = B, access = { open = false, groups = { police = 2 }, passcode = 'abc' } })
    check('portal: lock carried, passcode hidden', locked.access.open == false and locked.access.groups.police == 2 and locked.access.passcode == nil and locked.access.code == true)
    check('passcode: never sent to players for rooms either', Studio.PublicRoom({ name = 'o', label = 'O', shell = 's', entrance = {}, exit = {}, look = 1, looks = { { id = 1, name = 'D', pieces = {} } }, access = { open = false, passcode = 'xyz' } }).access.passcode == nil)
    check('passcode: right code opens, wrong or missing does not', Studio.CodeOpens({ passcode = 'abc' }, 'abc') and not Studio.CodeOpens({ passcode = 'abc' }, 'abd') and not Studio.CodeOpens({ passcode = 'abc' }, nil) and not Studio.CodeOpens({}, ''))
    local port = { label = 'Lift', a = A, b = B, access = { open = false } }
    check('portal: staff set its lock with the same rules as a room', Studio.ManageApply(port, { staff = true }, 'group_set', { group = 'police', grade = 1 }, { police = true }) and port.access.groups.police == 1)
    check('portal: a locked portal lets the listed rank through', Studio.MayEnterRoom(port, { job = 'police', grade = 1 }) and not Studio.MayEnterRoom(port, { job = 'police', grade = 0 }))
end

-- a portal is a door: the same owner, managers, groups, people, key items and passcode (DPS 2026-11-12)
do
    local A, B = { x = 1, y = 2, z = 3, h = 0 }, { x = 9, y = 9, z = 9, h = 0 }
    local boss = { citizenid = 'B1', job = 'police', grade = 4, jobBoss = true }
    local cop = { citizenid = 'C1', job = 'police', grade = 1 }
    local key = { citizenid = 'K1', has = function(i) return i == 'office_key' end }
    local nokey = { citizenid = 'N1', has = function() return false end }
    local port = { label = 'Lift', a = A, b = B, access = { open = false }, manage = { owner = { kind = 'group', id = 'police' } } }
    check('portal owner: the group boss manages, a lower rank does not', Studio.MayManage(port.manage, boss) and not Studio.MayManage(port.manage, cop))
    check('portal owner: the boss walks through a locked portal', Studio.MayEnterRoom(port, boss) and not Studio.MayEnterRoom(port, cop))
    check('key item: the owner adds one', Studio.ManageApply(port, boss, 'item_add', { item = 'office_key' }, nil, { office_key = true }) and port.access.items[1] == 'office_key')
    check('key item: whoever holds it gets through', Studio.MayEnterRoom(port, key) and not Studio.MayEnterRoom(port, nokey))
    check('key item: unknown item refused', not Studio.ManageApply(port, boss, 'item_add', { item = 'made_up' }, nil, { office_key = true }))
    check('key item: same item twice refused', not Studio.ManageApply(port, boss, 'item_add', { item = 'office_key' }, nil, { office_key = true }))
    check('key item: an outsider cannot add one', not Studio.ManageApply(port, cop, 'item_add', { item = 'office_key' }, nil, { office_key = true }))
    check('key item: removed again', Studio.ManageApply(port, boss, 'item_remove', { item = 'office_key' }) and #port.access.items == 0 and not Studio.MayEnterRoom(port, key))
    local pub = Studio.PublicPortal(port)
    check('portal: players are told its owner and key items, never its code', pub.manage.owner.id == 'police' and pub.access.passcode == nil)
    check('portal: the boss names a manager, who then changes the list', Studio.ManageApply(port, boss, 'manager_add', { cid = 'C1' }) and Studio.ManageApply(port, cop, 'group_set', { group = 'police', grade = 1 }, { police = true }) and Studio.MayEnterRoom(port, cop))
end

print(('%d checks, %s'):format(n, fails == 0 and 'ALL PASS' or (fails .. ' FAILED')))
os.exit(fails == 0 and 0 or 1)
