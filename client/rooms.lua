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

-- Inside a room the world clock and rain are paused for this player only, through the same
-- events the house system uses (dps-weatherbridge turns them into night light, no rain).
local function setInside(name, on)
    if (inside[name] or false) == on then return end
    inside[name] = on or nil
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
    -- a shell is a prop: pause the world clock so the sun never lights it (dps-weatherbridge)
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
    local shell = r.data.kind == 'ipl' and 'ipl' or spawn(r.data.shell, r.shellPos)   -- an interior needs no shell
    if shell ~= 'ipl' and stale(shell) then return false end
    if not shell then spawning[name] = nil; return false end
    shells[name] = shell
    local list = {}
    pieces[name] = list
    for _, q in ipairs(r.data.pieces or {}) do
        local o = spawn(q.model, r.shellPos + vec3(q.x, q.y, q.z), q.h)
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
        else
            inRoom = d < 120.0 and me.z < r.door.z - Studio.DEPTH / 2
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

local function door(key, coords, text, onUse)
    return lib.points.new({
        coords = coords,
        distance = 2.0,
        onEnter = function()
            prompt = key
            local t = type(text) == 'function' and text() or text
            nui({ action = 'prompt', key = t:find('^Locked') and '' or 'E', text = t })
        end,
        onExit = function() if prompt == key then prompt = nil; nui({ action = 'prompt' }) end end,
        nearby = function()
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

local function addRoom(p, respawn)
    local name = p.name
    if type(name) ~= 'string' or (p.kind ~= 'ipl' and type(p.shell) ~= 'string') then return end
    local doorPos = vec3(p.entrance.x, p.entrance.y, p.entrance.z)
    local shellPos, out
    if p.kind == 'ipl' then
        -- an interior sits where the game put it; its way out is a world spot and the anchor for pieces
        out = vec3(p.exit.x, p.exit.y, p.exit.z)
        shellPos = out
    else
        shellPos = doorPos - vec3(0.0, 0.0, Studio.DEPTH)
        out = shellPos + vec3(p.exit.x, p.exit.y, p.exit.z)
    end
    StudioC.rooms[name] = { data = p, shellPos = shellPos, out = out, door = doorPos }
    points[name] = {
        lib.points.new({
            coords = shellPos,
            distance = 250.0,
            -- shells load for anyone nearby; an interior room's furniture only for people inside it
            onEnter = function() if p.kind ~= 'ipl' then CreateThread(function() StudioC.SpawnRoom(name) end) end end,
            onExit = function() despawn(name) end,
        }),
        door(name .. ':in', doorPos, function() return StudioC.MayEnter(p) and ('Enter ' .. p.label) or ('Locked · ' .. p.label) end, function()
            if not StudioC.MayEnter(p) then return lib.notify({ type = 'error', description = p.label .. ' is locked' }) end
            if StudioC.Move(out, p.exit.h, name) then setInside(name, true) end
        end),
        door(name .. ':out', out, 'Leave ' .. p.label, function() if StudioC.Move(doorPos, (p.entrance.h + 180.0) % 360.0) then setInside(name, false) end end),
    }
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
            local o = spawn(q.model, r.shellPos + vec3(q.x, q.y, q.z), q.h)
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
    if p and old and old.data.shell == p.shell and old.data.ipl == p.ipl and same(old.data.entrance, p.entrance) and same(old.data.exit, p.exit) and shells[name] then
        if p.kind == 'ipl' and inside[name] then StudioC.IplApply(p.ipl, p.style) end   -- a new style shows at once
        if old.data.label ~= p.label or json.encode(old.data.access or {}) ~= json.encode(p.access or {}) then
            -- new door words: swap only the two door prompts, the shell stays under everyone
            local pts = points[name]
            for i = 2, 3 do if pts[i] then pts[i]:remove() end end
            if prompt and prompt:find(name .. ':', 1, true) == 1 then prompt = nil; nui({ action = 'prompt' }) end
            local r = old
            pts[2] = door(name .. ':in', r.door, function() return StudioC.MayEnter(p) and ('Enter ' .. p.label) or ('Locked · ' .. p.label) end, function()
                if not StudioC.MayEnter(p) then return lib.notify({ type = 'error', description = p.label .. ' is locked' }) end
                if StudioC.Move(r.out, p.exit.h, name) then setInside(name, true) end
            end)
            pts[3] = door(name .. ':out', r.out, 'Leave ' .. p.label, function() if StudioC.Move(r.door, (p.entrance.h + 180.0) % 360.0) then setInside(name, false) end end)
        end
        return updatePieces(name, p)
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
