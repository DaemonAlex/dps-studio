-- CLIENT (every player). Runs every room: the shell and the active look's pieces sit
-- Studio.DEPTH metres under the door, spawned only while the player is within 250 m and
-- deleted when they leave (client-only objects, ox_lib points, no polling loops).
-- The door and the way out are 2 m points: E fades the screen and moves the player.
-- Prompts are drawn by the Studio NUI page in the DPS look (no focus taken).
-- The server sends one room at a time when it changes, so an edit only redraws that room.

StudioC = StudioC or {}
StudioC.rooms = {}            -- name -> { data = public room, shellPos, out, door }
StudioC.pieceByEntity = {}    -- entity -> { name, id, model }

local points = {}             -- name -> { point, point, point }
local shells, pieces = {}, {} -- name -> entity / { entities }
local gen = {}                -- name -> number, bumped whenever a room is torn down
local spawning = {}           -- name -> true while its models load
local prompt                  -- the key of the prompt showing
local inside = {}             -- name -> true while this player is inside that room

-- DPS 2026-10-18: /roomlight <timecycle> <0-1> tries an indoor light inside a room, for this
-- admin only (a shell is lit like outdoors). Leaving the room puts normal light back.
local roomLight
RegisterCommand('roomlight', function(_, args)
    if not StudioC.isAdmin then
        StudioC.isAdmin = lib.callback.await('dps-studio:isAdmin', false) and true or false
        if not StudioC.isAdmin then return lib.notify({ type = 'error', description = 'Admins only' }) end
    end
    local name = args[1]
    if name == 'info' then   -- what this game is drawing right now, written to the client log
        local ped = cache.ped
        local p = GetEntityCoords(ped)
        local gw = GlobalState.weather
        local line = ('[dps-studio] roomlight info: clock %02d:%02d | weather %s -> %s | timecycle %d | transition %d | extra %d | interior %d | rain %.2f | at %.1f %.1f %.1f | inside %s | server weather %s')
            :format(GetClockHours(), GetClockMinutes(), tostring(GetPrevWeatherTypeHashName()), tostring(GetNextWeatherTypeHashName()),
                GetTimecycleModifierIndex(), GetTimecycleTransitionModifierIndex(), GetExtraTimecycleModifierIndex(),
                GetInteriorFromEntity(ped), GetRainLevel(), p.x, p.y, p.z, json.encode(inside),
                type(gw) == 'table' and json.encode(gw):sub(1, 200) or tostring(gw))
        print(line)
        return lib.notify({ type = 'inform', description = ('Clock %02d:%02d written to your log'):format(GetClockHours(), GetClockMinutes()) })
    end
    if not name or name == 'off' then
        ClearTimecycleModifier()
        roomLight = nil
        return lib.notify({ type = 'inform', description = 'Room light back to normal' })
    end
    local s = math.max(0.0, math.min(1.0, tonumber(args[2]) or 1.0))
    SetTimecycleModifier(name)
    SetTimecycleModifierStrength(s)
    roomLight = name
    print(('[dps-studio] roomlight %s %.2f'):format(name, s))
    lib.notify({ type = 'inform', description = ('Room light: %s at %.2f. /roomlight off to undo'):format(name, s) })
end, false)

-- Inside a room the world clock and rain are paused for this player only, through the same
-- events the house system uses (dps-fixes weather bridge turns them into night light, no rain).
local function setInside(name, on)
    if (inside[name] or false) == on then return end
    inside[name] = on or nil
    if not on and roomLight then ClearTimecycleModifier(); roomLight = nil end
    local r = StudioC.rooms[name]
    if r and r.data.kind == 'ipl' then
        -- a real interior (each serves one room): show the room's style and furniture to the
        -- people who came in through its door; the real place stays as it was for everyone else
        if on then
            StudioC.IplApply(r.data.ipl, r.data.style)
            CreateThread(function() StudioC.SpawnRoom(name) end)
        else
            StudioC.IplReset(r.data.ipl)
            StudioC._despawn(name)
        end
        return
    end
    -- a shell is a prop: pause the world clock so the sun never lights it (dps-fixes weather bridge)
    TriggerEvent(on and 'qb-weathersync:client:DisableSync' or 'qb-weathersync:client:EnableSync')
end

local function hasShell(name)
    local sh = shells[name]
    return sh == 'ipl' or (sh ~= nil and DoesEntityExist(sh))
end

local function nui(msg) SendNUIMessage(msg) end

---Busy while placing, fine tuning or walking a shell. The inventory is held shut through its
---own busy flag, so Tab (fine tune) never opens it; the flag goes back to what it was after.
function StudioC.SetBusy(on)
    on = on and true or false
    if on == (StudioC.busy or false) then return end
    StudioC.busy = on
    if on then
        StudioC._invPrev = LocalPlayer.state.invBusy
        LocalPlayer.state:set('invBusy', true, false)
    else
        LocalPlayer.state:set('invBusy', StudioC._invPrev or false, false)
        StudioC._invPrev = nil
    end
end

local function spawn(model, pos, h)
    local hash = joaat(model)
    if not IsModelInCdimage(hash) or not pcall(lib.requestModel, hash, 15000) then return end
    local o = CreateObjectNoOffset(hash, pos.x, pos.y, pos.z, false, false, false)
    SetEntityHeading(o, (h or 0.0) + 0.0)
    FreezeEntityPosition(o, true)
    SetModelAsNoLongerNeeded(hash)
    return o
end

local function despawn(name)
    return StudioC._despawn(name)
end

function StudioC._despawn(name)
    gen[name] = (gen[name] or 0) + 1   -- any spawn still loading for this room drops its objects
    spawning[name] = nil
    if type(shells[name]) == 'number' and DoesEntityExist(shells[name]) then DeleteEntity(shells[name]) end
    shells[name] = nil
    for _, o in ipairs(pieces[name] or {}) do
        StudioC.pieceByEntity[o] = nil
        if DoesEntityExist(o) then DeleteEntity(o) end
    end
    pieces[name] = nil
end

---The live shell object of a room, if it is spawned (place the shell hides it while its ghost is moved).
function StudioC.ShellEntity(name)
    local sh = shells[name]
    return type(sh) == 'number' and DoesEntityExist(sh) and sh or nil
end

---Spawns a room's shell and pieces if they are not there. Safe to call twice: the
---second call waits for the first. Returns true when the shell exists.
function StudioC.SpawnRoom(name)
    local r = StudioC.rooms[name]
    if not r then return false end
    if hasShell(name) then return true end
    if spawning[name] then
        -- another call is loading it: the floor is enough, the furniture can follow
        local t = GetGameTimer() + 20000
        while spawning[name] and not shells[name] and GetGameTimer() < t do Wait(50) end
        return hasShell(name)
    end
    spawning[name] = true
    local ok, res = pcall(function() return StudioC._spawnBody(name, r) end)
    if not ok then
        spawning[name] = nil
        print(('^1[dps-studio] room %s did not spawn: %s^7'):format(name, tostring(res)))
        return false
    end
    return res
end

function StudioC._spawnBody(name, r)
    local my = gen[name] or 0
    local function stale(o)
        if (gen[name] or 0) ~= my or StudioC.rooms[name] ~= r then
            if o and DoesEntityExist(o) then DeleteEntity(o) end
            return true
        end
    end
    local shell = r.data.kind == 'ipl' and 'ipl' or spawn(r.data.shell, r.shellPos, r.at.h)   -- an interior needs no shell
    if shell ~= 'ipl' and stale(shell) then return false end
    if not shell then spawning[name] = nil; return false end
    shells[name] = shell
    if shell ~= 'ipl' then
        local mn, mx = GetModelDimensions(GetEntityModel(shell))
        r.box = { mn, mx }   -- the shell's own size, for "am I inside it" on a hand-placed room
    end
    local list = {}
    pieces[name] = list
    for _, q in ipairs(r.data.pieces or {}) do
        local w = Studio.ToWorld(r.at, q)
        local o = spawn(q.model, vec3(w.x, w.y, w.z), w.h)
        if stale(o) then return false end
        if o then
            list[#list + 1] = o
            StudioC.pieceByEntity[o] = { name = name, id = q.id, model = q.model, at = q }
        end
    end
    spawning[name] = nil
    return true
end

---The room the player is inside: under its door and near its shell.
function StudioC.RoomHere()
    local me = GetEntityCoords(cache.ped)
    local best, bestD
    for name, r in pairs(StudioC.rooms) do
        local d = #(me - r.shellPos)
        local inRoom
        if r.data.kind == 'ipl' then
            -- inside means inside that interior, not just near it
            r.int = r.int or GetInteriorAtCoords(r.out.x, r.out.y, r.out.z)
            local mine = GetInteriorFromEntity(cache.ped)
            inRoom = d < 80.0 and ((r.int ~= 0 and mine == r.int) or (r.int == 0 and d < 25.0))
        elseif r.data.at then
            -- a hand-placed shell can sit right beside its door: inside means inside the shell's own box
            local b = r.box
            if b and d < 200.0 then
                local l = Studio.ToLocal(r.at, me)
                inRoom = l.x >= b[1].x - 1.0 and l.x <= b[2].x + 1.0 and l.y >= b[1].y - 1.0 and l.y <= b[2].y + 1.0
                    and l.z >= b[1].z - 1.0 and l.z <= b[2].z + 2.0
            end
        else
            -- between the door and the shell, on the shell's side (a room can sit under or above its door)
            local dep = Studio.RoomDepth(r.data)
            inRoom = d < 120.0 and ((dep > 0 and me.z < r.door.z - dep / 2) or (dep < 0 and me.z > r.door.z - dep / 2))
        end
        if inRoom and (not bestD or d < bestD) then best, bestD = name, d end
    end
    return best
end

---Fade, move, face, fade back. When moving into a room, its shell must exist first,
---or the player stays where they are (never dropped under the map).
function StudioC.Move(to, heading, roomName)
    if cache.vehicle then return lib.notify({ type = 'error', description = 'Get out of the vehicle first' }) end
    DoScreenFadeOut(300)
    Wait(350)
    if roomName and not StudioC.SpawnRoom(roomName) then
        DoScreenFadeIn(300)
        return lib.notify({ type = 'error', description = 'This room did not load. Try again in a moment.' })
    end
    local ped = cache.ped
    FreezeEntityPosition(ped, true)
    RequestCollisionAtCoord(to.x, to.y, to.z)
    SetEntityCoords(ped, to.x, to.y, to.z - 1.0, false, false, false, false)
    SetEntityHeading(ped, (heading or 0.0) + 0.0)
    if roomName then setInside(roomName, true) end   -- a door or a Studio teleport is the way in
    Wait(500)
    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(300)
    return true
end

---DPS 2026-10-21 (Damon): a drive-in room. The driver takes the car through the door with
---everyone in it; the passengers' games hear from the server that they are inside (or out).
function StudioC.MoveCar(to, heading, roomName, on)
    local car = cache.vehicle
    if not car or GetPedInVehicleSeat(car, -1) ~= cache.ped then
        return lib.notify({ type = 'inform', description = 'The driver takes the car through' })
    end
    DoScreenFadeOut(300)
    Wait(350)
    if on and not StudioC.SpawnRoom(roomName) then
        DoScreenFadeIn(300)
        return lib.notify({ type = 'error', description = 'This room did not load. Try again in a moment.' })
    end
    FreezeEntityPosition(car, true)
    RequestCollisionAtCoord(to.x, to.y, to.z)
    SetEntityCoords(car, to.x, to.y, to.z, false, false, false, false)
    SetEntityHeading(car, (heading or 0.0) + 0.0)
    local t = GetGameTimer() + 3000
    while not HasCollisionLoadedAroundEntity(car) and GetGameTimer() < t do Wait(50) end
    SetVehicleOnGroundProperly(car)
    local ids = {}
    for seat = 0, GetVehicleMaxNumberOfPassengers(car) - 1 do
        local ped = GetPedInVehicleSeat(car, seat)
        local pl = ped ~= 0 and NetworkGetPlayerIndexFromPed(ped) or -1
        if pl ~= -1 then ids[#ids + 1] = GetPlayerServerId(pl) end
    end
    if #ids > 0 then TriggerServerEvent('dps-studio:carried', roomName, on, ids) end
    FreezeEntityPosition(car, false)
    DoScreenFadeIn(300)
    return true
end

-- manageOf = the room's name: its owner and managers also see "G Manage" at this door (DPS 2026-11-12)
local function door(key, coords, text, onUse, dist, manageOf)
    return lib.points.new({
        coords = coords,
        distance = dist or 2.0,   -- a drive-in door is wider, so a car can pull up to it
        onEnter = function()
            prompt = key
            local t = type(text) == 'function' and text() or text
            local locked = t:find('^Locked') ~= nil
            if manageOf and not locked and StudioC.MayManage and StudioC.MayManage(manageOf) then t = t .. '  ·  G  Manage' end
            nui({ action = 'prompt', key = locked and '' or 'E', text = t })
        end,
        onExit = function() if prompt == key then prompt = nil; nui({ action = 'prompt' }) end end,
        nearby = function()
            if manageOf and IsControlJustPressed(0, 47) and not StudioC.busy and not StudioC.moving
                and StudioC.MayManage and StudioC.MayManage(manageOf) then
                return StudioC.OpenManage(manageOf)
            end
            if IsControlJustPressed(0, 38) and not StudioC.busy and not StudioC.moving then
                local t = type(text) == 'function' and text() or text
                if t:find('^Locked') then return lib.notify({ type = 'error', description = t:gsub('^Locked · ', '') .. ' is locked' }) end
                prompt = nil
                nui({ action = 'prompt' })
                StudioC.moving = true
                CreateThread(function()
                    pcall(onUse)
                    StudioC.moving = false
                end)
            end
        end,
    })
end

local function removeRoom(name)
    setInside(name, false)
    for _, p in ipairs(points[name] or {}) do p:remove() end
    points[name] = nil
    if prompt and prompt:find(name .. ':', 1, true) == 1 then prompt = nil; nui({ action = 'prompt' }) end
    local had = shells[name] ~= nil
    despawn(name)
    StudioC.rooms[name] = nil
    return had
end

---Every door prompt of a room, made from its current data: the door, the way out and any
---extra door pairs. Called again whenever the words, the lock, the managers or the doors change.
---The shell and the furniture are not touched, so nobody loses the floor.
local function buildDoors(name)
    local r, pts = StudioC.rooms[name], points[name]
    if not r or not pts then return end
    for i = #pts, 2, -1 do pts[i]:remove(); pts[i] = nil end
    if prompt and prompt:find(name .. ':', 1, true) == 1 then prompt = nil; nui({ action = 'prompt' }) end
    local p = r.data
    local doorPos, out, shellPos = r.door, r.out, r.shellPos
    local drive = p.kind == 'ipl' and Studio.InteriorMode(p.ipl) == 'drive'
    local reach = drive and 6.0 or nil
    -- on the list: Enter. Not on it but the room has a passcode: E asks for the code. Otherwise locked.
    local function enterText()
        if StudioC.MayEnter(p) then return 'Enter ' .. p.label end
        return (p.access and p.access.code) and ('Enter the code · ' .. p.label) or ('Locked · ' .. p.label)
    end
    local function mayPass()
        if StudioC.MayEnter(p) then return true end
        if p.access and p.access.code and StudioC.AskCode and StudioC.AskCode('room', name, p.label) then return true end
        lib.notify({ type = 'error', description = p.label .. ' is locked' })
        return false
    end
    pts[2] = door(name .. ':in', doorPos, enterText, function()
        if not mayPass() then return end
        if drive and cache.vehicle then
            if StudioC.MoveCar(out, r.outH, name, true) == true then setInside(name, true) end
        elseif StudioC.Move(out, r.outH, name) then setInside(name, true) end
    end, reach, name)
    pts[3] = door(name .. ':out', out, 'Leave ' .. p.label, function()
        if drive and cache.vehicle then
            if StudioC.MoveCar(doorPos, (p.entrance.h + 180.0) % 360.0, name, false) == true then setInside(name, false) end
        elseif StudioC.Move(doorPos, (p.entrance.h + 180.0) % 360.0) then setInside(name, false) end
    end, reach, name)
    -- DPS 2026-10-19 (Damon): extra door pairs, e.g. the airport ops office's second exit into the terminal.
    -- p.exits = { { from = offset inside the shell {x,y,z,h}, to = world spot outside {x,y,z,h} }, ... }
    -- DPS 2026-11-12: staff add them in game with /roomexit; they use the room's own lock.
    for i, e in ipairs(p.kind ~= 'ipl' and p.exits or {}) do
        local w = Studio.ToWorld(r.at, e.from)
        local inPos, world = vec3(w.x, w.y, w.z), vec3(e.to.x, e.to.y, e.to.z)
        pts[#pts + 1] = door(name .. ':x' .. i .. 'out', inPos, 'Leave ' .. p.label, function() if StudioC.Move(world, e.to.h) then setInside(name, false) end end, nil, name)
        pts[#pts + 1] = door(name .. ':x' .. i .. 'in', world, enterText, function()
            if not mayPass() then return end
            if StudioC.Move(inPos, w.h, name) then setInside(name, true) end
        end, nil, name)
    end
end

local function addRoom(p, respawn)
    local name = p.name
    if type(name) ~= 'string' or (p.kind ~= 'ipl' and type(p.shell) ~= 'string') then return end
    local doorPos = vec3(p.entrance.x, p.entrance.y, p.entrance.z)
    local shellPos, out, at, outH
    if p.kind == 'ipl' then
        -- an interior sits where the game put it; its way out is a world spot and the anchor for pieces
        out = vec3(p.exit.x, p.exit.y, p.exit.z)
        shellPos = out
    else
        -- DPS 2026-11-12: the shell sits where staff placed it (/roomshell), or under its door; it may be turned
        at = Studio.ShellAt(p)
        shellPos = vec3(at.x, at.y, at.z)
        local o = Studio.ToWorld(at, p.exit)
        out, outH = vec3(o.x, o.y, o.z), o.h
    end
    StudioC.rooms[name] = { data = p, shellPos = shellPos, out = out, door = doorPos,
                            at = at or { x = shellPos.x, y = shellPos.y, z = shellPos.z, h = 0.0 }, outH = outH or p.exit.h }
    points[name] = {
        lib.points.new({
            coords = shellPos,
            distance = 250.0,
            -- shells load for anyone nearby; an interior room's furniture only for people inside it
            onEnter = function() if p.kind ~= 'ipl' then CreateThread(function() StudioC.SpawnRoom(name) end) end end,
            onExit = function() despawn(name) end,
        }),
    }
    buildDoors(name)
    if respawn and (p.kind ~= 'ipl' or inside[name]) then CreateThread(function() StudioC.SpawnRoom(name) end) end   -- redraw at once after an edit
end

local function setAll(list)
    for name in pairs(StudioC.rooms) do removeRoom(name) end
    for _, p in ipairs(list or {}) do addRoom(p, false) end
end

local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z and a.h == b.h end

---Only the furniture changed: keep the shell (nobody loses the floor) and swap just the
---pieces that were added, moved or removed.
local function updatePieces(name, p)
    local r = StudioC.rooms[name]
    local list = pieces[name]
    if not list or spawning[name] then
        -- still loading: start that room over, so the new pieces are the ones that load
        removeRoom(name)
        return addRoom(p, true)
    end
    r.data = p
    local want = {}
    for _, q in ipairs(p.pieces or {}) do want[q.id] = q end
    local keep = {}
    for _, o in ipairs(list) do
        local info = StudioC.pieceByEntity[o]
        local q = info and want[info.id]
        local cur = DoesEntityExist(o) and GetEntityCoords(o)
        if q and info.model == q.model and info.at and same(info.at, q) and cur and IsEntityVisible(o) then
            keep[#keep + 1] = o
            want[info.id] = nil
        else
            StudioC.pieceByEntity[o] = nil
            if DoesEntityExist(o) then DeleteEntity(o) end
        end
    end
    pieces[name] = keep
    local my = gen[name] or 0
    CreateThread(function()
        for _, q in pairs(want) do
            local w = Studio.ToWorld(r.at, q)
            local o = spawn(q.model, vec3(w.x, w.y, w.z), w.h)
            if (gen[name] or 0) ~= my or pieces[name] ~= keep then
                if o and DoesEntityExist(o) then DeleteEntity(o) end
                return
            end
            if o then
                keep[#keep + 1] = o
                StudioC.pieceByEntity[o] = { name = name, id = q.id, model = q.model, at = q }
            end
        end
    end)
end

-- One room changed (p = false when it was removed).
RegisterNetEvent('dps-studio:room', function(name, p)
    local old = StudioC.rooms[name]
    if p and old and old.data.shell == p.shell and old.data.ipl == p.ipl and same(old.data.entrance, p.entrance) and same(old.data.exit, p.exit) and shells[name]
        and old.data.depth == p.depth and json.encode(old.data.at or {}) == json.encode(p.at or {}) then   -- a moved shell is a full rebuild
        if p.kind == 'ipl' and inside[name] then StudioC.IplApply(p.ipl, p.style) end   -- a new style shows at once
        local function changed(k) return json.encode(old.data[k] or {}) ~= json.encode(p[k] or {}) end
        if old.data.label ~= p.label or changed('access') or changed('manage') or changed('exits') then
            -- new door words, lock, managers or extra doors: redo only the prompts, the shell stays under everyone
            old.data = p
            buildDoors(name)
        end
        return updatePieces(name, p)
    end
    -- the room is about to be taken away and rebuilt (new shell, new door, new depth): anyone standing
    -- in it goes to its door first, so nobody is left in mid air
    if old and inside[name] and old.data.kind ~= 'ipl' and StudioC.RoomHere() == name then
        SetEntityCoords(cache.ped, old.door.x, old.door.y, old.door.z, false, false, false, false)
    end
    local had = removeRoom(name)
    if p then addRoom(p, had) end
end)

RegisterNetEvent('dps-studio:rooms', setAll)

-- Other ways in or out (teleports, Decorate, respawn): a slow, steady check. It only acts on a
-- clear change of room, so walking round inside never flips the light.
CreateThread(function()
    while true do
        Wait(2000)
        local here = StudioC.RoomHere()
        for name in pairs(inside) do
            if name ~= here then setInside(name, false) end
        end
        -- walking into a shell room's space means being inside it; an interior (IPL) can be a
        -- real place people walk into, so only a door or a teleport switches its private copy on
        if here and StudioC.rooms[here] and StudioC.rooms[here].data.kind ~= 'ipl' then setInside(here, true) end
    end
end)

CreateThread(function()
    setAll(lib.callback.await('dps-studio:rooms', false))
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    StudioC.SetBusy(false)
    -- anyone inside a room goes back to its door before the room disappears
    local here = StudioC.RoomHere()
    local r = here and StudioC.rooms[here]
    if r then SetEntityCoords(cache.ped, r.door.x, r.door.y, r.door.z, false, false, false, false) end
    FreezeEntityPosition(cache.ped, false)
    if IsScreenFadedOut() or IsScreenFadingOut() then DoScreenFadeIn(0) end
    for name in pairs(StudioC.rooms) do removeRoom(name) end
end)

-- DPS 2026-10-21: the driver of a drive-in room's car took us through its door
RegisterNetEvent('dps-studio:carried', function(name, on)
    if type(name) ~= 'string' or not StudioC.rooms[name] then return end
    setInside(name, on == true)
end)

