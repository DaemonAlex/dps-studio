-- CLIENT (admin). The door maker, in /admin > Doors. ox_doorlock stays the lock engine: doors are
-- created and removed with ox_doorlock's own admin event (from this admin's game, as its own
-- window does), and edited on the server with its editDoor export. Picking a door works like
-- ox_doorlock's: look at it, left click; click the second half of a double door or press Enter.

StudioC = StudioC or {}

local function keys(title, list) SendNUIMessage({ action = 'keys', title = title, keys = list }) end
local TEMP_DOOR = joaat('dps_studio_temp')

---The closed position of a door, the way ox_doorlock records it (temporarily added to the door
---system and held shut, so a door that stands open is still stored closed).
local function doorOf(entity)
    local model = GetEntityModel(entity)
    local coords = GetEntityCoords(entity)
    AddDoorToSystem(TEMP_DOOR, model, coords.x, coords.y, coords.z, false, false, false)
    DoorSystemSetDoorState(TEMP_DOOR, 4, false, false)
    coords = GetEntityCoords(entity)
    local d = { entity = entity, model = model, coords = coords, heading = math.floor(GetEntityHeading(entity) + 0.5) }
    RemoveDoorFromSystem(TEMP_DOOR)
    return d
end

local function isOxDoor(entity)
    local ok, id = pcall(function() return exports.ox_doorlock:getDoorIdFromEntity(entity) end)
    return ok and id ~= nil
end

---Look at a door and pick it (and its other half). Returns the ox_doorlock door shape, or nil.
function StudioC.PickDoor(title)
    StudioC.SetBusy(true)
    local picked = {}
    local last = 0
    local result
    keys(title or 'Pick a door', { { 'Look', 'at a door, it lights up' }, { 'Left click', 'pick it' },
        { 'Left click again', 'the other half of a double door' }, { 'Enter', 'done, a single door' }, { 'Backspace', 'cancel' } })
    SetEntityDrawOutlineColor(255, 122, 69, 255)
    local calm = GetGameTimer() + 300
    while true do
        DisablePlayerFiring(cache.playerId, true)
        DisableControlAction(0, 24, true); DisableControlAction(0, 25, true)
        DisableControlAction(0, 191, true); DisableControlAction(0, 194, true); DisableControlAction(0, 177, true); DisableControlAction(0, 200, true)
        local hit, entity = lib.raycast.cam(1 | 16)
        local first = picked[1] and picked[1].entity
        if last ~= 0 and last ~= entity and last ~= first and DoesEntityExist(last) then SetEntityDrawOutline(last, false) end
        local good = hit and entity and entity > 0 and GetEntityType(entity) == 3 and entity ~= first and not isOxDoor(entity)
        if good then SetEntityDrawOutline(entity, true); last = entity else last = 0 end
        if GetGameTimer() > calm then
            if good and IsDisabledControlJustPressed(0, 24) then
                picked[#picked + 1] = doorOf(entity)
                if #picked == 1 then
                    keys(title or 'Pick a door', { { 'Left click', 'the other half of a double door' }, { 'Enter', 'done, a single door' }, { 'Backspace', 'cancel' } })
                end
            end
            if #picked == 2 or (#picked == 1 and IsDisabledControlJustPressed(0, 191)) then
                result = picked
                break
            end
            if IsDisabledControlJustPressed(0, 194) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then break end
        end
        Wait(0)
    end
    for _, p in ipairs(picked) do if DoesEntityExist(p.entity) then SetEntityDrawOutline(p.entity, false) end end
    if last ~= 0 and DoesEntityExist(last) then SetEntityDrawOutline(last, false) end
    SendNUIMessage({ action = 'keys' })
    StudioC.SetBusy(false)
    if not result then return nil end
    if #result == 2 then
        local a, b = result[1], result[2]
        return { doors = { { coords = a.coords, heading = a.heading, model = a.model }, { coords = b.coords, heading = b.heading, model = b.model } } }
    end
    return { model = result[1].model, coords = result[1].coords, heading = result[1].heading }
end

---Creates a door in ox_doorlock from a picked shape and Studio settings. Returns ok, id or err.
function StudioC.CreateDoor(shape, name, access, opts, room)
    opts = opts or {}
    local okMax, maxId = lib.callback.await('dps-studio:doorMaxId', false)
    if not okMax then return false, maxId end
    -- a name no other door has
    local taken = {}
    for _, x in ipairs(lib.callback.await('dps-studio:doors', false) or {}) do taken[x.name] = true end
    local base, i = name, 2
    while taken[name] do name = ('%s %d'):format(base, i); i = i + 1 end
    local ox = Studio.AccessToOx(access)
    local data = {
        name = name, state = opts.locked == false and 0 or 1, maxDistance = 2.0,
        groups = ox.groups ~= '' and ox.groups or nil, items = ox.items ~= '' and ox.items or nil,
        characters = ox.characters ~= '' and ox.characters or nil, passcode = ox.passcode ~= '' and ox.passcode or nil,
        doors = shape.doors, model = shape.model, coords = shape.coords, heading = shape.heading,
    }
    if data.doors then data.coords = nil end
    TriggerServerEvent('ox_doorlock:editDoorlock', false, data)
    local ok, id = lib.callback.await('dps-studio:doorCreated', false, name, access, room, maxId)
    return ok, ok and name or id
end

function StudioC.RemoveDoor(id)
    local ok, err = lib.callback.await('dps-studio:doorBeforeRemove', false, id)
    if not ok then return false, err end
    TriggerServerEvent('ox_doorlock:editDoorlock', id)
    return true
end

---Puts a door back from a History line (edits it, or recreates it when it was removed).
function StudioC.RestoreDoor(historyId)
    local ok, res = lib.callback.await('dps-studio:doorRestore', false, historyId)
    if not ok then return false, res end
    if type(res) == 'table' and res.recreate then
        local d = res.recreate
        if d.coords then d.coords = vec3(d.coords.x, d.coords.y, d.coords.z) end
        if type(d.doors) == 'table' then
            for i = 1, 2 do local c = d.doors[i].coords; d.doors[i].coords = vec3(c.x, c.y, c.z) end
        else
            d.doors = nil
        end
        local okMax, maxId = lib.callback.await('dps-studio:doorMaxId', false)
        if not okMax then return false, maxId end
        TriggerServerEvent('ox_doorlock:editDoorlock', false, d)
        -- give the new copy back its Studio marks (staff, everyone, which room)
        local m = res.marks or {}
        lib.callback.await('dps-studio:doorCreated', false, d.name, { open = m.open, staff = m.staff }, m.room, maxId)
    end
    return true
end

-- ---------------------------------------------------------------- who am I (for Studio room doors)
local function me()
    local pd = {}
    pcall(function() pd = exports.qbx_core:GetPlayerData() or {} end)
    local job, gang = pd.job or {}, pd.gang or {}
    return {
        job = job.name, grade = type(job.grade) == 'table' and job.grade.level or job.grade,
        gang = gang.name, gangGrade = type(gang.grade) == 'table' and gang.grade.level or gang.grade,
        citizenid = pd.citizenid, staff = StudioC.isAdmin == true,
        has = function(item)
            local ok, n = pcall(function() return exports.ox_inventory:Search('count', item) end)
            return ok and (tonumber(n) or 0) > 0
        end,
    }
end

---Whether this player may go through a Studio room's door.
function StudioC.MayEnter(roomData)
    local a = roomData and roomData.access
    if not a or a.open then return true end
    if StudioC.isAdmin then return true end   -- staff can always get in to set things up
    return Studio.AccessAllows(a, me())
end
