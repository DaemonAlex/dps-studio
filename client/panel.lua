-- CLIENT (admin). /admin opens DPS Studio: one panel, tabs for Rooms, Place, Shells,
-- Inspect, Spots, Doors and History. The page (html/) renders; this file owns the game
-- side: focus, the shell preview camera, walking in, marking the way out, teleports.
-- Nothing here polls: the only per-frame loops run while previewing or walking a shell.

StudioC = StudioC or {}
StudioC.isAdmin = false

local BASE = vec3(-2200.0, -4200.0, 1100.0)   -- sky over the sea south of LSIA, for previews
local open, tab = false, 'rooms'
local boot                                     -- cached boot data (shells, furniture)

-- preview state
local pv = { on = false, obj = nil, hash = nil, cam = nil, back = nil, wasGod = false, token = 0,
             center = BASE, minZ = BASE.z, radius = 20.0, heading = 45.0, tilt = 0.35, model = nil, walking = false }
local pick   -- { name, label, entrance = {x,y,z,h} } while making or redoing a room

local function nui(msg) SendNUIMessage(msg) end
local function notify(ok, text) lib.notify({ type = ok and 'success' or 'error', description = text }) end

-- ---------------------------------------------------------------- admin flag
RegisterNetEvent('dps-studio:admin', function(v) StudioC.isAdmin = v and true or false end)
CreateThread(function() StudioC.isAdmin = lib.callback.await('dps-studio:isAdmin', false) and true or false end)

-- ---------------------------------------------------------------- open / close
local function focus(on) SetNuiFocus(on, on) end

local function show(t)
    open = true
    tab = t or tab
    focus(true)
    nui({ action = 'open', tab = tab, here = StudioC.RoomHere(), pick = pick and { name = pick.name, label = pick.label } or false,
          previewing = pv.on and pv.model or false })
end

local function hide()
    open = false
    focus(false)
    nui({ action = 'hide' })
end

-- ---------------------------------------------------------------- shell preview
local function placeCam()
    local r = math.rad(pv.heading)
    local pos = pv.center + vec3(math.cos(r) * pv.radius, math.sin(r) * pv.radius, pv.radius * pv.tilt)
    SetCamCoord(pv.cam, pos.x, pos.y, pos.z)
    -- aim a little to the left of the shell, so it sits in the open right side of the
    -- screen and not under the panel, which docks on the left
    local toCam = pos - pv.center
    local right = vec3(-toCam.y, toCam.x, 0.0)
    local len = #right
    local look = pv.center
    if len > 0.01 then look = pv.center - right / len * (pv.radius * 0.35) end
    PointCamAtCoord(pv.cam, look.x, look.y, look.z)
end

local function hidePed()
    local ped = cache.ped
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    SetEntityCoords(ped, pv.center.x, pv.center.y, pv.center.z, false, false, false, false)
end

local function clearShell()
    if pv.obj and DoesEntityExist(pv.obj) then DeleteEntity(pv.obj) end
    if pv.hash then SetModelAsNoLongerNeeded(pv.hash) end
    pv.obj, pv.hash = nil, nil
end

local function previewStart()
    if pv.on then return end
    local ped = cache.ped
    local p = GetEntityCoords(ped)
    pv.back = { x = p.x, y = p.y, z = p.z, h = GetEntityHeading(ped) }
    pv.wasGod = GetPlayerInvincible(cache.playerId) or not GetEntityCanBeDamaged(ped)   -- either kind of god mode
    SetEntityInvincible(ped, true)
    pv.cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', BASE.x, BASE.y, BASE.z + 20.0, 0.0, 0.0, 0.0, 60.0, false, 0)
    SetCamActive(pv.cam, true)
    RenderScriptCams(true, false, 0, true, true)
    pv.on, pv.walking = true, false
end

---Ends the preview and puts the player back where they stood (or at `to`).
local function previewStop(to)
    if not pv.on then return end
    pv.token = pv.token + 1
    clearShell()
    RenderScriptCams(false, false, 0, true, true)
    if pv.cam then DestroyCam(pv.cam, false) end
    pv.cam, pv.on, pv.walking, pv.model = nil, false, false, nil
    local ped = cache.ped
    local b = to or pv.back
    -- land safely: hold the player still until the ground at the return spot has loaded
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, true, true)
    RequestCollisionAtCoord(b.x, b.y, b.z)
    SetEntityCoords(ped, b.x, b.y, b.z, false, false, false, false)
    SetEntityHeading(ped, b.h + 0.0)
    SetEntityVisible(ped, true, false)
    if not pv.wasGod then SetEntityInvincible(ped, false) end   -- frozen while landing, so no god mode needed
    nui({ action = 'keys' })
    if StudioC.stopping then FreezeEntityPosition(ped, false) return end   -- no threads run while stopping
    CreateThread(function()
        local t = GetGameTimer() + 4000
        while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < t do
            RequestCollisionAtCoord(b.x, b.y, b.z)
            Wait(50)
        end
        if not pv.on then FreezeEntityPosition(ped, false) end
    end)
end

---Leaves the panel for another screen: a preview that is still showing ends first.
local function leave()
    if pv.on and not pv.walking then previewStop() end
    pick = nil
    hide()
end

local function previewShell(model)
    if type(model) ~= 'string' then return false, 'No shell' end
    previewStart()
    pv.token = pv.token + 1
    local my = pv.token
    clearShell()
    pv.model = model
    local h = joaat(model)
    pv.center, pv.minZ = BASE, BASE.z
    if not IsModelInCdimage(h) then return false, model .. ' is in the housing list but its file is not streamed' end
    if not pcall(lib.requestModel, h, 15000) then return false, model .. ' did not load in time' end
    -- the preview may have ended, or another shell been picked, while this one loaded
    if not pv.on or pv.token ~= my then SetModelAsNoLongerNeeded(h); return false end
    clearShell()
    pv.hash = h
    pv.obj = CreateObjectNoOffset(h, BASE.x, BASE.y, BASE.z, false, false, false)
    FreezeEntityPosition(pv.obj, true)
    local mn, mx = GetModelDimensions(h)
    pv.center = BASE + (mn + mx) / 2
    pv.minZ = BASE.z + mn.z
    pv.radius = math.min(400.0, math.max(8.0, #(mx - mn) * 0.9))
    if not pv.walking then hidePed() end
    RequestCollisionAtCoord(pv.center.x, pv.center.y, pv.center.z)
    placeCam()
    return true
end

local function floorPoint()
    local c = pv.center
    local ray = StartExpensiveSynchronousShapeTestLosProbe(c.x, c.y, c.z, c.x, c.y, pv.minZ - 5.0, 1 | 16, cache.ped, 7)
    local _, hit, pos = GetShapeTestResult(ray)
    if hit == 1 then return pos + vec3(0.0, 0.0, 1.0) end
    return vec3(c.x, c.y, pv.minZ + 1.0)
end

local walkKeys
local function walk()
    if not pv.obj then return notify(false, 'Pick a shell that loads first') end
    hide()
    pv.walking = true
    StudioC.SetBusy(true)
    local ped = cache.ped
    RenderScriptCams(false, false, 0, true, true)
    local p = floorPoint()
    SetEntityCollision(ped, true, true)
    SetEntityCoords(ped, p.x, p.y, p.z, false, false, false, false)
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    walkKeys()
    CreateThread(function()
        local nextFall = 0
        local calm = GetGameTimer() + 300   -- ignore the Enter that opened this
        while pv.walking do
            DisableControlAction(0, 191, true); DisableControlAction(0, 194, true); DisableControlAction(0, 177, true); DisableControlAction(0, 47, true)
            DisableControlAction(0, 199, true); DisableControlAction(0, 200, true)   -- Esc leaves too, never the pause menu
            if GetGameTimer() < calm then
                -- wait out the key press that started walking
            elseif IsDisabledControlJustPressed(0, 191) then          -- Enter: back to the panel view
                pv.walking = false
                hidePed()
                RenderScriptCams(true, false, 0, true, true)
                placeCam()
                nui({ action = 'keys' })
                StudioC.SetBusy(false)
                show('shells')
            elseif pick and IsDisabledControlJustPressed(0, 47) then -- G: the way out is here
                local ped2 = cache.ped
                local off = GetEntityCoords(ped2) - BASE
                local d = { name = pick.name, label = pick.label, shell = pv.model, entrance = pick.entrance, redo = pick.redo == true,
                            exit = { x = off.x, y = off.y, z = off.z, h = GetEntityHeading(ped2) } }
                local ok, err = lib.callback.await('dps-studio:roomCreate', false, d)
                if ok then
                    pv.walking = false
                    StudioC.SetBusy(false)
                    local e = pick.entrance
                    pick = nil
                    previewStop({ x = e.x, y = e.y, z = e.z, h = e.h })
                    notify(true, ('%s is ready. Press E at the door to try it.'):format(d.label))
                else
                    notify(false, err or 'Not saved')
                end
            elseif IsDisabledControlJustPressed(0, 194) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then -- Backspace / Esc: leave
                pv.walking = false
                StudioC.SetBusy(false)
                previewStop()
                show('rooms')
            else
                local now = GetGameTimer()
                if now > nextFall then
                    nextFall = now + 500
                    if GetEntityCoords(cache.ped).z < pv.minZ - 20.0 then
                        local f = floorPoint()
                        SetEntityCoords(cache.ped, f.x, f.y, f.z, false, false, false, false)
                    end
                end
            end
            Wait(0)
        end
    end)
end

walkKeys = function()
    local list = { { 'Walk', 'look around inside' }, { 'Enter', 'back to the panel' } }
    if pick then list[#list + 1] = { 'G', 'the way out of ' .. pick.label .. ' is here' } end
    list[#list + 1] = { 'Backspace', 'leave the preview' }
    nui({ action = 'keys', title = pv.model or 'Shell', keys = list })
end

-- ---------------------------------------------------------------- /admin
RegisterCommand('admin', function()
    if not StudioC.isAdmin then
        local r = lib.callback.await('dps-studio:isAdmin', false)
        print(('[dps-studio] /admin permission check answered: %s'):format(tostring(r)))
        StudioC.isAdmin = r and true or false
        if not StudioC.isAdmin then
            return lib.notify({ type = 'error', description = 'Studio needs the admin permission (dps.entityselector).' })
        end
    end
    if StudioC.busy then
        return lib.notify({ type = 'inform', description = 'Finish placing or walking first (Backspace leaves).' })
    end
    print(('[dps-studio] /admin %s'):format(open and 'closing' or 'opening'))
    if open then hide() else show() end
end, false)

TriggerEvent('chat:addSuggestion', '/admin', 'DPS Studio: rooms, furniture, shells, spots and doors (admin)')

-- ---------------------------------------------------------------- NUI: general
local function tpTo(x, y, z, h, roomName)
    CreateThread(function() StudioC.Move(vec3(x, y, z), h, roomName) end)
end

-- Checks every library model once per session and tells the page which ones this game cannot
-- spawn, so the list never offers a dead entry. Runs in small steps so it never stutters.
local libChecked = false
local function checkLibrary()
    if libChecked then return end
    libChecked = true
    CreateThread(function()
        local ok, data = pcall(json.decode, LoadResourceFile(GetCurrentResourceName(), 'html/library.json') or '')
        if not ok or type(data) ~= 'table' then return end
        local bad, n = {}, 0
        for _, g in ipairs(data.groups or {}) do
            for _, it in ipairs(g.items or {}) do
                n = n + 1
                if not IsModelInCdimage(joaat(it[1])) then bad[#bad + 1] = it[1] end
                if n % 600 == 0 then Wait(0) end
            end
        end
        print(('[dps-studio] library: %d models, %d not in this game'):format(n, #bad))
        nui({ action = 'libBad', names = bad })
    end)
end

RegisterNUICallback('boot', function(_, cb)
    checkLibrary()
    local b = boot or lib.callback.await('dps-studio:boot', false)
    if not b then return cb({ ok = false }) end
    local shells = type(b.shells) == 'table' and b.shells or {}
    local furniture = type(b.furniture) == 'table' and b.furniture or {}
    if #shells > 0 and #furniture > 0 then boot = b end   -- keep it only when both lists loaded
    cb({ ok = true, shells = shells, meta = ShellMeta, furniture = furniture, max = b.maxPieces,
         missing = (#shells == 0 and 'shells ' or '') .. (#furniture == 0 and 'furniture' or '') })
end)

RegisterNUICallback('close', function(_, cb)
    if pv.on then previewStop() end
    pick = nil
    hide()
    cb({ ok = true })
end)

RegisterNUICallback('tab', function(d, cb)
    tab = d.tab or tab
    if tab ~= 'shells' and pv.on then previewStop() end
    cb({ ok = true, here = StudioC.RoomHere() })
end)

RegisterNUICallback('rooms', function(_, cb) cb(lib.callback.await('dps-studio:roomList', false) or {}) end)
RegisterNUICallback('spots', function(_, cb) cb(lib.callback.await('dps-studio:spots', false) or {}) end)
RegisterNUICallback('history', function(_, cb) cb(lib.callback.await('dps-studio:history', false) or {}) end)
RegisterNUICallback('scans', function(_, cb) cb(StudioC.scans) end)

local function call(name, ...)
    local ok, err = lib.callback.await(name, false, ...)
    return { ok = ok == true, err = err }
end

local function mySpot()
    local p = GetEntityCoords(cache.ped)
    return { x = p.x, y = p.y, z = p.z, h = GetEntityHeading(cache.ped) }
end

-- ---------------------------------------------------------------- NUI: rooms
RegisterNUICallback('roomGo', function(d, cb)
    local r = StudioC.rooms[d.name]
    if not r then return cb({ ok = false, err = 'That room is gone' }) end
    leave()
    if d.inside then tpTo(r.out.x, r.out.y, r.out.z, r.data.exit.h, d.name)
    else tpTo(r.door.x, r.door.y, r.door.z, (r.data.entrance.h + 180.0) % 360.0) end
    cb({ ok = true })
end)

RegisterNUICallback('roomNew', function(d, cb)
    -- d.name, d.label; d.keepDoor = redo an existing room's shell / way out
    local okName, errName = lib.callback.await('dps-studio:nameCheck', false, d.name, d.label, d.keepDoor == true)
    if not okName then return cb({ ok = false, err = errName }) end
    local entrance
    if d.keepDoor then
        local r = StudioC.rooms[d.name]
        if not r then return cb({ ok = false, err = 'That room is gone' }) end
        entrance = r.data.entrance
    else
        if cache.vehicle then return cb({ ok = false, err = 'Get out of the vehicle first' }) end
        entrance = mySpot()
    end
    pick = { name = d.name, label = d.label, entrance = entrance, redo = d.keepDoor == true }
    cb({ ok = true })
end)

RegisterNUICallback('pickCancel', function(_, cb) pick = nil; cb({ ok = true }) end)
RegisterNUICallback('roomDoor', function(d, cb) cb(call('dps-studio:roomDoor', d.name, mySpot())) end)
RegisterNUICallback('roomLabel', function(d, cb) cb(call('dps-studio:roomLabel', d.name, d.label)) end)
RegisterNUICallback('roomCopy', function(d, cb) cb(call('dps-studio:roomCopy', d.name, d.newName, d.label, mySpot())) end)
RegisterNUICallback('roomDelete', function(d, cb) cb(call('dps-studio:roomDelete', d.name)) end)
RegisterNUICallback('lookNew', function(d, cb) cb(call('dps-studio:lookNew', d.name, d.look, d.copy == true)) end)
RegisterNUICallback('lookSwitch', function(d, cb) cb(call('dps-studio:lookSwitch', d.name, tonumber(d.id))) end)
RegisterNUICallback('lookRename', function(d, cb) cb(call('dps-studio:lookRename', d.name, tonumber(d.id), d.look)) end)
RegisterNUICallback('lookDelete', function(d, cb) cb(call('dps-studio:lookDelete', d.name, tonumber(d.id))) end)
RegisterNUICallback('restore', function(d, cb) cb(call('dps-studio:restore', tonumber(d.id))) end)

-- ---------------------------------------------------------------- NUI: place
RegisterNUICallback('decorate', function(d, cb)
    -- go into the room first if we are not in it, then show the Place tab
    local r = StudioC.rooms[d.name]
    if not r then return cb({ ok = false, err = 'That room is gone' }) end
    if StudioC.RoomHere() ~= d.name then
        leave()
        CreateThread(function()
            StudioC.Move(r.out, r.data.exit.h, d.name)
            show('place')
        end)
    end
    cb({ ok = true })
end)

RegisterNUICallback('place', function(d, cb)
    local name = StudioC.RoomHere()
    if not name then return cb({ ok = false, err = 'Go into a room first' }) end
    leave()
    cb({ ok = true })
    CreateThread(function()
        StudioC.Place(name, d.model)
        show('place')
    end)
end)

RegisterNUICallback('edit', function(_, cb)
    local name = StudioC.RoomHere()
    if not name then return cb({ ok = false, err = 'Go into a room first' }) end
    leave()
    cb({ ok = true })
    CreateThread(function()
        StudioC.Edit(name)
        show('place')
    end)
end)

-- ---------------------------------------------------------------- NUI: shells
RegisterNUICallback('shell', function(d, cb)
    if tab ~= 'shells' or not open then return cb({ ok = false }) end   -- a late click after leaving the tab
    local ok, err = previewShell(d.model)
    cb({ ok = ok, err = err, model = pv.model })   -- err is nil when a newer pick replaced this one
end)

RegisterNUICallback('cam', function(d, cb)
    if pv.on and pv.cam then
        pv.heading = pv.heading - (tonumber(d.turn) or 0)
        pv.tilt = math.max(-0.4, math.min(1.6, pv.tilt + (tonumber(d.tilt) or 0)))
        local z = tonumber(d.zoom) or 0
        if z ~= 0 then pv.radius = math.max(3.0, math.min(400.0, pv.radius * (z > 0 and 1.1 or 0.9))) end
        placeCam()
    end
    cb({ ok = true })
end)

RegisterNUICallback('walk', function(_, cb) cb({ ok = true }); walk() end)
RegisterNUICallback('previewStop', function(_, cb) previewStop(); cb({ ok = true }) end)

-- ---------------------------------------------------------------- NUI: spots, doors, fleet
RegisterNUICallback('spotGo', function(d, cb)
    local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
    if not (x and y and z) then return cb({ ok = false }) end
    leave()
    tpTo(x, y, z, tonumber(d.h) or 0.0)
    cb({ ok = true })
end)

RegisterNUICallback('spotMark', function(d, cb)
    StudioC.MarkSpot('spot', type(d.label) == 'string' and d.label or '')
    cb({ ok = true })
end)

RegisterNUICallback('doors', function(_, cb)
    leave()
    cb({ ok = true })
    ExecuteCommand('doorlock')
end)

RegisterNUICallback('fleet', function(_, cb)
    leave()
    cb({ ok = true })
    ExecuteCommand('fleet')
end)

RegisterNetEvent('dps-studio:changed', function()
    if open then nui({ action = 'changed', here = StudioC.RoomHere() }) end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    StudioC.stopping = true
    if pv.on then previewStop() end
    FreezeEntityPosition(cache.ped, false)
    SetNuiFocus(false, false)
end)
