-- lua5.4 tests/run.lua [qs-housing config/main.lua] [qs-housing config/furniture.lua]
-- Loads shared/logic.lua and checks every rule the server relies on. Exits non-zero on a failure.
local function vec(...) return { ... } end
vec3, vec4, vector3, vector4 = vec3 or vec, vec4 or vec, vector3 or vec, vector4 or vec
dofile('shared/logic.lua')
dofile('shared/shellmeta.lua')
dofile('shared/ipls.lua')

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
print(('%d checks, %s'):format(n, fails == 0 and 'ALL PASS' or (fails .. ' FAILED')))
os.exit(fails == 0 and 0 or 1)
