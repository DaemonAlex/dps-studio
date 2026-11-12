-- CLIENT (admin). Placing and editing furniture in a room's active look.
-- Follow mode: the piece sits where you look. Fine tune (Tab): the piece stays put and
-- keys nudge it 1 cm / 1 degree (Shift: 10 cm / 15 degrees). The loop runs only while
-- placing or editing. Key help is drawn by the Studio NUI page (no focus).

StudioC = StudioC or {}

local K = { click = 24, enter = 191, back = 194, back2 = 177, left = 174, right = 175, up = 172, down = 173,
            wheelUp = 241, wheelDown = 242, e = 38, q = 44, del = 178, x = 73, tab = 37, shift = 21, pgUp = 10, pgDn = 11 }
local BLOCK = { 24, 25, 140, 141, 142, 14, 15, 16, 17, 37, 21, 10, 11, 44, 38, 178, 73, 191, 194, 177, 172, 173, 174, 175, 241, 242, 200,
                199, 322 }   -- DPS 2026-10-18: 199/322 too, so Esc never opens the pause menu while placing

---Backspace, or Esc (DPS 2026-10-18): one step back.
local function back() return IsDisabledControlJustPressed(0, 194) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) end

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
    local startAt, startH = at, h   -- where a moved piece was, for "back to where it was"

    local function help()
        if fine then
            keys('Fine tune · ' .. model, {
                { 'Arrows', 'slide 1 cm' }, { 'Page Up / Down', 'up or down 1 cm' }, { 'Q  E  Wheel', 'turn 1°' },
                { 'Hold Shift', '10 cm and 15° steps' }, { 'Tab', 'follow my look again' },
                { 'Left click / Enter', 'save' }, { 'Backspace / Esc', movingEnt and 'back to where it was' or 'back to follow my look' } })
        else
            keys('Placing · ' .. model, {
                { 'Look', 'move it' }, { 'Wheel  ← →', 'turn' }, { '↑ ↓', 'raise or lower' },
                { 'Tab', 'fine tune' }, { 'Left click / Enter', 'put it here' }, { 'Backspace / Esc', 'cancel' } })
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
            -- DPS 2026-11-12: saved as an offset inside the shell, so the piece turns and moves with it
            local g = GetEntityCoords(ghost)
            local off = Studio.ToLocal(room.at, { x = g.x, y = g.y, z = g.z, h = h })
            local ok, err = lib.callback.await('dps-studio:piecePut', false, roomName,
                { model = model, x = off.x, y = off.y, z = off.z, h = off.h }, id, room.data.look)
            lib.notify({ type = ok and 'success' or 'error', description = ok and (id and 'Moved' or 'Placed') or err })
            if not ok then showEnt(movingEnt) end
            done = true
        elseif back() then
            -- DPS 2026-10-18: one step back per press. Fine tune of a new piece -> follow my look;
            -- a moved piece -> back where it was, then cancel; following -> cancel.
            if fine and not movingEnt then
                fine = false
                help()
            elseif fine and movingEnt and (#(at - startAt) > 0.001 or math.abs(h - startH) > 0.01) then
                at, h = startAt, startH
                SetEntityCoordsNoOffset(ghost, at.x, at.y, at.z, false, false, false)
                lib.notify({ type = 'inform', description = 'Back where it was. Backspace again cancels.' })
            else
                showEnt(movingEnt)
                done = true
            end
        end
        Wait(0)
    end
    DeleteEntity(ghost)
    hideKeys()
    StudioC.SetBusy(false)
end

---The placed piece closest to the middle of the view, within 20 m. Picks by where you look,
---not by a ray hit, so lamps, rugs and other pieces without a solid body can be picked too.
local function pickPiece(roomName)
    local cam, fwd = GetGameplayCamCoord(), camForward()
    local best, bestScore
    for ent, info in pairs(StudioC.pieceByEntity) do
        if info.name == roomName and DoesEntityExist(ent) then
            local mn, mx = GetModelDimensions(GetEntityModel(ent))
            local centre = GetOffsetFromEntityInWorldCoords(ent, (mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
            local to = centre - cam
            local dist = #to
            if dist > 0.3 and dist < 20.0 then
                local cos = (to.x * fwd.x + to.y * fwd.y + to.z * fwd.z) / dist
                -- how far off the centre of view, measured against the piece's own size
                local off = math.sqrt(math.max(0.0, 1.0 - cos * cos)) * dist
                local size = math.max(0.25, #(mx - mn) / 2)
                if cos > 0.8 and off < size + 0.3 then
                    local score = off / size + dist * 0.02
                    if not bestScore or score < bestScore then best, bestScore = ent, score end
                end
            end
        end
    end
    return best, best and StudioC.pieceByEntity[best]
end

---Look at a placed piece: E moves it, Delete or X removes it, Backspace ends.
function StudioC.Edit(roomName)
    StudioC.SetBusy(true)
    keys('Move or remove', { { 'Look', 'at a piece, it lights up' }, { 'E', 'move it' }, { 'Delete or X', 'remove it' }, { 'Backspace', 'done' } })
    local last
    local function outline(e, on) if e and DoesEntityExist(e) then SetEntityDrawOutline(e, on) end end
    SetEntityDrawOutlineColor(255, 122, 69, 255)
    while true do
        blockKeys()
        DrawRect(0.5, 0.5, 0.003, 0.005, 255, 122, 69, 220)   -- a dot marks the middle of the view
        local target, info = pickPiece(roomName)
        if last ~= target then outline(last, false); outline(target, true); last = target end
        if target and pressed(K.e) then
            outline(target, false)
            hideKeys()
            StudioC.SetBusy(false)
            return StudioC.Place(roomName, info.model, info.id, GetEntityHeading(target), target)
        elseif target and (pressed(K.del) or pressed(K.x)) then
            local r = StudioC.rooms[roomName]
            local ok, err = lib.callback.await('dps-studio:pieceRemove', false, roomName, info.id, r and r.data.look)
            lib.notify({ type = ok and 'success' or 'error', description = ok and 'Removed' or err })
            last = nil
        elseif back() then
            break
        end
        Wait(0)
    end
    outline(last, false)
    hideKeys()
    StudioC.SetBusy(false)
end

-- ---------------------------------------------------------------- place the shell
-- DPS 2026-11-12 (Damon): "we need a better understanding of where the shell is and how to
-- manoeuvre it in place during creation". A see-through copy of the room's shell stands in the
-- world with an outline and a box of lines round it. Keys slide, lift and turn it; the readout
-- says where it is against its door. Enter saves, and the room (its furniture, way out and extra
-- doors with it) moves there. Runs right after a new room is made, and from /roomshell.

local function say(x, y, str, scale)
    SetTextFont(4)
    SetTextScale(0.0, scale or 0.42)
    SetTextColour(255, 255, 255, 240)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(str)
    EndTextCommandDisplayText(x, y)
end

---The 12 edges of a model's box at a spot and heading, so the shell's size shows from any side.
local function drawBox(at, h, mn, mx, r, g, b)
    local sp = { x = at.x, y = at.y, z = at.z, h = h }
    local c = {}
    for i, o in ipairs({ { mn.x, mn.y, mn.z }, { mx.x, mn.y, mn.z }, { mx.x, mx.y, mn.z }, { mn.x, mx.y, mn.z },
                         { mn.x, mn.y, mx.z }, { mx.x, mn.y, mx.z }, { mx.x, mx.y, mx.z }, { mn.x, mx.y, mx.z } }) do
        c[i] = Studio.ToWorld(sp, { x = o[1], y = o[2], z = o[3] })
    end
    for _, e in ipairs({ { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 }, { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }) do
        local a, z = c[e[1]], c[e[2]]
        DrawLine(a.x, a.y, a.z, z.x, z.y, z.z, r, g, b, 255)
    end
end

function StudioC.PlaceShell(roomName)
    if StudioC.busy then return lib.notify({ type = 'error', description = 'Finish what you are doing first' }) end
    local room = StudioC.rooms[roomName]
    if not room then return lib.notify({ type = 'error', description = 'That room is gone' }) end
    if room.data.kind == 'ipl' then return lib.notify({ type = 'error', description = 'An interior room sits where the game put it' }) end
    -- the shell is about to move: nobody places it from inside
    if StudioC.RoomHere() == roomName then
        SetEntityCoords(cache.ped, room.door.x, room.door.y, room.door.z, false, false, false, false)
        Wait(300)
    end
    local hash = joaat(room.data.shell)
    if not IsModelInCdimage(hash) or not pcall(lib.requestModel, hash, 15000) then
        return lib.notify({ type = 'error', description = room.data.shell .. ' did not load' })
    end
    StudioC.SetBusy(true)
    local door = room.door
    local at, h = vec3(room.at.x, room.at.y, room.at.z), room.at.h + 0.0
    local startAt, startH = at, h
    local ghost = CreateObjectNoOffset(hash, at.x, at.y, at.z, false, false, false)
    SetEntityCollision(ghost, false, false)
    SetEntityAlpha(ghost, 170, false)
    FreezeEntityPosition(ghost, true)
    SetModelAsNoLongerNeeded(hash)
    SetEntityDrawOutlineColor(255, 122, 69, 255)
    SetEntityDrawOutline(ghost, true)
    local mn, mx = GetModelDimensions(hash)
    local live = StudioC.ShellEntity(roomName)        -- the real one hides while its ghost is moved
    if live then SetEntityVisible(live, false, false) end

    keys('Place the shell · ' .. room.data.label, {
        { 'Arrows', 'slide 1 m' }, { 'Page Up / Down', 'up or down 1 m' }, { 'Q  E', 'turn 5°' },
        { 'Hold Shift', '10 m and 45° steps' }, { 'Hold Alt', '10 cm and 1° steps' },
        { 'G', 'bring it to where I stand' }, { 'H', 'back under the door' },
        { 'Enter', 'save here' }, { 'Backspace / Esc', 'cancel' } })

    local held = {}
    local function tap(c)   -- one step per tap; holding repeats after 300 ms
        if not IsDisabledControlPressed(0, c) then held[c] = nil return false end
        local now = GetGameTimer()
        if not held[c] then held[c] = now + 300 return true end
        if now >= held[c] then held[c] = now + 60 return true end
        return false
    end

    local calm = GetGameTimer() + 400   -- ignore the key that started this
    local saved
    while true do
        blockKeys()
        DisableControlAction(0, 19, true); DisableControlAction(0, 47, true); DisableControlAction(0, 74, true)
        local big, small = IsDisabledControlPressed(0, K.shift), IsDisabledControlPressed(0, 19)
        local step, turn = big and 10.0 or (small and 0.1 or 1.0), big and 45.0 or (small and 1.0 or 5.0)
        local r = math.rad(GetGameplayCamRot(2).z)
        local fwd, right = vec3(-math.sin(r), math.cos(r), 0.0), vec3(math.cos(r), math.sin(r), 0.0)
        if tap(K.up) then at = at + fwd * step end
        if tap(K.down) then at = at - fwd * step end
        if tap(K.right) then at = at + right * step end
        if tap(K.left) then at = at - right * step end
        if tap(K.pgUp) then at = at + vec3(0.0, 0.0, step) end
        if tap(K.pgDn) then at = at - vec3(0.0, 0.0, step) end
        if tap(K.q) then h = (h + turn) % 360.0 end
        if tap(K.e) then h = (h - turn) % 360.0 end
        if GetGameTimer() >= calm and IsDisabledControlJustPressed(0, 47) then        -- G: the floor comes to my feet
            local me = GetEntityCoords(cache.ped)
            at = vec3(me.x, me.y, me.z - 1.0 - mn.z)
        end
        if GetGameTimer() >= calm and IsDisabledControlJustPressed(0, 74) then        -- H: where it would sit by itself
            at, h = vec3(door.x, door.y, door.z - Studio.RoomDepth(room.data)), 0.0
        end
        -- never further from the door than the server allows
        for _, k in ipairs({ 'x', 'y', 'z' }) do
            if math.abs(at[k] - door[k]) > 1400.0 then
                local v = door[k] + (at[k] > door[k] and 1400.0 or -1400.0)
                at = vec3(k == 'x' and v or at.x, k == 'y' and v or at.y, k == 'z' and v or at.z)
            end
        end
        SetEntityCoordsNoOffset(ghost, at.x, at.y, at.z, false, false, false)
        SetEntityHeading(ghost, h)

        -- what you see: its box, a line from the door to it, and where people will arrive inside
        drawBox(at, h, mn, mx, 255, 122, 69)
        local mid = Studio.ToWorld({ x = at.x, y = at.y, z = at.z, h = h }, { x = (mn.x + mx.x) / 2, y = (mn.y + mx.y) / 2, z = (mn.z + mx.z) / 2 })
        DrawLine(door.x, door.y, door.z, mid.x, mid.y, mid.z, 255, 255, 255, 200)
        local arrive = Studio.ToWorld({ x = at.x, y = at.y, z = at.z, h = h }, room.data.exit)
        DrawMarker(1, arrive.x, arrive.y, arrive.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.6, 90, 200, 120, 160, false, false, 2, false, nil, nil, false)

        local flat = math.sqrt((at.x - door.x) ^ 2 + (at.y - door.y) ^ 2)
        local dz = at.z - door.z
        say(0.5, 0.045, ('~o~%s~s~   %.1f m across from the door   ·   %.1f m %s it   ·   facing %.0f'):format(
            room.data.label, flat, math.abs(dz), dz <= 0 and 'under' or 'above', h))
        say(0.5, 0.075, ('Floor at height %.1f   ·   size %.0f x %.0f x %.0f m   ·   green ring = where people arrive'):format(
            at.z + mn.z, mx.x - mn.x, mx.y - mn.y, mx.z - mn.z), 0.34)

        if GetGameTimer() < calm then
            -- the key that opened this is still settling
        elseif pressed(K.enter) then
            local ok, words = lib.callback.await('dps-studio:roomShellAt', false, roomName, { x = at.x, y = at.y, z = at.z, h = h })
            lib.notify({ type = ok and 'success' or 'error', description = words or (ok and 'Saved' or 'Not saved') })
            if ok then saved = true; break end
        elseif back() then
            if #(at - startAt) > 0.01 or math.abs(h - startH) > 0.01 then
                at, h = startAt, startH
                lib.notify({ type = 'inform', description = 'Back where it was. Backspace again leaves without saving.' })
            else
                break
            end
        end
        Wait(0)
    end
    SetEntityDrawOutline(ghost, false)
    DeleteEntity(ghost)
    if not saved then
        local still = StudioC.ShellEntity(roomName)
        if still then SetEntityVisible(still, true, false) end
    end
    hideKeys()
    StudioC.SetBusy(false)
end
