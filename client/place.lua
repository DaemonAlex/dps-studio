-- CLIENT (admin). Placing and editing furniture in a room's active look.
-- Follow mode: the piece sits where you look. Fine tune (Tab): the piece stays put and
-- keys nudge it 1 cm / 1 degree (Shift: 10 cm / 15 degrees). The loop runs only while
-- placing or editing. Key help is drawn by the Studio NUI page (no focus).

StudioC = StudioC or {}

local K = { click = 24, enter = 191, back = 194, back2 = 177, left = 174, right = 175, up = 172, down = 173,
            wheelUp = 241, wheelDown = 242, e = 38, q = 44, del = 178, tab = 37, shift = 21, pgUp = 10, pgDn = 11 }
local BLOCK = { 24, 25, 140, 141, 142, 14, 15, 16, 17, 37, 21, 10, 11, 44, 38, 178, 191, 194, 177, 172, 173, 174, 175, 241, 242, 200 }

local function keys(title, list) SendNUIMessage({ action = 'keys', title = title, keys = list }) end
local function hideKeys() SendNUIMessage({ action = 'keys' }) end

local function camForward()
    local r = GetGameplayCamRot(2)
    local x, z = math.rad(r.x), math.rad(r.z)
    return vec3(-math.sin(z) * math.abs(math.cos(x)), math.cos(z) * math.abs(math.cos(x)), math.sin(x))
end

local function aim(ignore)
    local from = GetGameplayCamCoord()
    local to = from + camForward() * 12.0
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1 | 16, ignore or cache.ped, 7)
    local _, hit, pos, _, ent = GetShapeTestResult(ray)
    return hit == 1, pos, ent
end

local function blockKeys()
    for i = 1, #BLOCK do DisableControlAction(0, BLOCK[i], true) end
end

local function pressed(c) return IsDisabledControlJustPressed(0, c) end

local function showEnt(e)
    if e and DoesEntityExist(e) then SetEntityVisible(e, true, false); SetEntityCollision(e, true, true) end
end

---Places a new piece (id nil) or moves one (id, heading, the entity being moved).
---Returns when done; the caller reopens the panel.
function StudioC.Place(roomName, model, id, heading, movingEnt)
    local room = StudioC.rooms[roomName]
    if not room then return lib.notify({ type = 'error', description = 'That room is gone' }) end
    local hash = joaat(model)
    if not IsModelInCdimage(hash) or not pcall(lib.requestModel, hash, 15000) then
        return lib.notify({ type = 'error', description = model .. ' did not load' })
    end
    StudioC.SetBusy(true)
    if movingEnt then SetEntityVisible(movingEnt, false, false); SetEntityCollision(movingEnt, false, false) end
    local ghost = CreateObjectNoOffset(hash, room.shellPos.x, room.shellPos.y, room.shellPos.z, false, false, false)
    SetEntityCollision(ghost, false, false)
    SetEntityAlpha(ghost, 200, false)
    FreezeEntityPosition(ghost, true)
    SetModelAsNoLongerNeeded(hash)
    local mn = GetModelDimensions(hash)
    local h, lift = heading or GetEntityHeading(cache.ped), 0.0
    local fine, at = false, nil
    if movingEnt and DoesEntityExist(movingEnt) then fine, at = true, GetEntityCoords(movingEnt) end

    local function help()
        if fine then
            keys('Fine tune · ' .. model, {
                { 'Arrows', 'slide 1 cm' }, { 'Page Up / Down', 'up or down 1 cm' }, { 'Q  E  Wheel', 'turn 1°' },
                { 'Hold Shift', '10 cm and 15° steps' }, { 'Tab', 'follow my look again' },
                { 'Left click / Enter', 'save' }, { 'Backspace', 'cancel' } })
        else
            keys('Placing · ' .. model, {
                { 'Look', 'move it' }, { 'Wheel  ← →', 'turn' }, { '↑ ↓', 'raise or lower' },
                { 'Tab', 'fine tune' }, { 'Left click / Enter', 'put it here' }, { 'Backspace', 'cancel' } })
        end
    end
    help()

    local held = {}
    local function tap(c)   -- one step per tap; holding repeats after 300 ms
        if not IsDisabledControlPressed(0, c) then held[c] = nil return false end
        local now = GetGameTimer()
        if not held[c] then held[c] = now + 300 return true end
        if now >= held[c] then held[c] = now + 40 return true end
        return false
    end

    if movingEnt then held[K.e] = math.huge end   -- E grabbed it; wait for release before E turns it
    local calm = GetGameTimer() + 300             -- ignore the Enter or click that started this
    local done = false
    while not done do
        blockKeys()
        local hit
        if pressed(K.tab) then
            fine = not fine
            if fine then at = GetEntityCoords(ghost) end
            help()
        end
        if fine then
            hit = true
            local big = IsDisabledControlPressed(0, K.shift)
            local step, turn = big and 0.10 or 0.01, big and 15.0 or 1.0
            local r = math.rad(GetGameplayCamRot(2).z)
            local fwd, right = vec3(-math.sin(r), math.cos(r), 0.0), vec3(math.cos(r), math.sin(r), 0.0)
            if tap(K.up) then at = at + fwd * step end
            if tap(K.down) then at = at - fwd * step end
            if tap(K.right) then at = at + right * step end
            if tap(K.left) then at = at - right * step end
            if tap(K.pgUp) then at = at + vec3(0.0, 0.0, step) end
            if tap(K.pgDn) then at = at - vec3(0.0, 0.0, step) end
            if tap(K.q) or pressed(K.wheelUp) then h = h + turn end
            if tap(K.e) or pressed(K.wheelDown) then h = h - turn end
            -- keep it near the room: never more than 150 m from the shell
            if #(at - room.shellPos) > 150.0 then at = room.shellPos + (at - room.shellPos) * (150.0 / #(at - room.shellPos)) end
            SetEntityCoordsNoOffset(ghost, at.x, at.y, at.z, false, false, false)
        else
            local pos
            hit, pos = aim(ghost)
            if hit then SetEntityCoordsNoOffset(ghost, pos.x, pos.y, pos.z - mn.z + lift, false, false, false) end
            if IsDisabledControlPressed(0, K.left) then h = h + 2.0 end
            if IsDisabledControlPressed(0, K.right) then h = h - 2.0 end
            if pressed(K.wheelUp) then h = h + 15.0 end
            if pressed(K.wheelDown) then h = h - 15.0 end
            if IsDisabledControlPressed(0, K.up) then lift = math.min(5.0, lift + 0.01) end
            if IsDisabledControlPressed(0, K.down) then lift = math.max(-5.0, lift - 0.01) end
        end
        h = h % 360.0
        SetEntityHeading(ghost, h)

        if GetGameTimer() < calm then
            -- the key that opened placing is still settling
        elseif (pressed(K.click) or pressed(K.enter)) and hit then
            local off = GetEntityCoords(ghost) - room.shellPos
            local ok, err = lib.callback.await('dps-studio:piecePut', false, roomName,
                { model = model, x = off.x, y = off.y, z = off.z, h = h }, id, room.data.look)
            lib.notify({ type = ok and 'success' or 'error', description = ok and (id and 'Moved' or 'Placed') or err })
            if not ok then showEnt(movingEnt) end
            done = true
        elseif pressed(K.back) or pressed(K.back2) then
            showEnt(movingEnt)
            done = true
        end
        Wait(0)
    end
    DeleteEntity(ghost)
    hideKeys()
    StudioC.SetBusy(false)
end

---Look at a placed piece: E moves it, Delete removes it, Backspace ends.
function StudioC.Edit(roomName)
    StudioC.SetBusy(true)
    keys('Move or remove', { { 'Look', 'at a piece' }, { 'E', 'move it' }, { 'Delete', 'remove it' }, { 'Backspace', 'done' } })
    local last
    local function outline(e, on) if e and DoesEntityExist(e) then SetEntityDrawOutline(e, on) end end
    SetEntityDrawOutlineColor(255, 122, 69, 255)
    while true do
        blockKeys()
        local _, _, ent = aim()
        local info = ent and ent ~= 0 and StudioC.pieceByEntity[ent] or nil
        if info and info.name ~= roomName then info = nil end
        local target = info and ent or nil
        if last ~= target then outline(last, false); outline(target, true); last = target end
        if target and pressed(K.e) then
            outline(target, false)
            hideKeys()
            StudioC.SetBusy(false)
            return StudioC.Place(roomName, info.model, info.id, GetEntityHeading(target), target)
        elseif target and pressed(K.del) then
            local r = StudioC.rooms[roomName]
            local ok, err = lib.callback.await('dps-studio:pieceRemove', false, roomName, info.id, r and r.data.look)
            lib.notify({ type = ok and 'success' or 'error', description = ok and 'Removed' or err })
            last = nil
        elseif pressed(K.back) or pressed(K.back2) then
            break
        end
        Wait(0)
    end
    outline(last, false)
    hideKeys()
    StudioC.SetBusy(false)
end
