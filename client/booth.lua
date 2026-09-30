-- CLIENT (admin). The photo booth: one picture of every library piece.
-- Each piece is set up alone high over the sea at midday, framed to fill the shot, and
-- taken by screencapture (the server's screenshot tool, game view only) at the server's
-- request. The Studio page crops it to a
-- small square webp, and the server puts it on Fivemanage. Backspace stops; the next run
-- carries on from the pieces that still have no picture.

StudioC = StudioC or {}

local SPOT = vec3(-2650.0, -4650.0, 1250.0)   -- clear sky over the sea, away from the shell preview
local FOV = 40.0
local running, stopAsked = false, false
local backSpot   -- where the player stood, for a resource stop mid-run
local cropWait

RegisterNUICallback('cropDone', function(d, cb)
    if cropWait and d and d.model == cropWait.model then cropWait.settle(type(d.b64) == 'string' and d.b64 or false) end
    cb({ ok = true })
end)

local function shoot()
    SendNUIMessage({ action = 'keys' })   -- nothing of ours on screen while the picture is taken
    Wait(0)
    return lib.callback.await('dps-studio:shoot', false)
end

local function crop(model, dataUri)
    local p, settled = promise.new(), false
    local function settle(v) if not settled then settled = true; p:resolve(v) end end
    cropWait = { model = model, settle = settle }
    SendNUIMessage({ action = 'crop', model = model, data = dataUri })
    SetTimeout(6000, function() settle(false) end)
    local b64 = Citizen.Await(p)
    cropWait = nil
    return b64
end

local function frame(cam, obj, hash)
    local mn, mx = GetModelDimensions(hash)
    local centre = GetOffsetFromEntityInWorldCoords(obj, (mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
    local size = math.max(0.25, #(mx - mn))
    local dist = (size / 2) / math.tan(math.rad(FOV / 2)) / 0.82
    -- from the front and a little to the right and above: the usual shop-photo angle
    local dir = vec3(math.sin(math.rad(35.0)), math.cos(math.rad(35.0)), 0.38)
    dir = dir / #dir
    local pos = centre + dir * dist
    SetCamCoord(cam, pos.x, pos.y, pos.z)
    PointCamAtCoord(cam, centre.x, centre.y, centre.z)
    SetCamFov(cam, FOV)
end

---models: list of model names still without a picture.
function StudioC.Booth(models)
    if running or type(models) ~= 'table' or #models == 0 then return end
    if GetResourceState('screencapture') ~= 'started' then
        return lib.notify({ type = 'error', description = 'The photo booth needs screencapture running' })
    end
    running, stopAsked = true, false
    StudioC.SetBusy(true)
    local ped = cache.ped
    local back = GetEntityCoords(ped)
    local backH = GetEntityHeading(ped)
    backSpot = back
    local wasGod = GetPlayerInvincible(cache.playerId) or not GetEntityCanBeDamaged(ped)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    SetEntityCoords(ped, SPOT.x, SPOT.y, SPOT.z - 30.0, false, false, false, false)
    TriggerEvent('qb-weathersync:client:DisableSync')   -- hold the clock for this player only
    NetworkOverrideClockTime(12, 0, 0)                    -- then set midday light for the pictures
    SetRainLevel(0.0)
    DisplayRadar(false)
    local cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', SPOT.x, SPOT.y + 5.0, SPOT.z, 0.0, 0.0, 0.0, FOV, false, 0)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)

    CreateThread(function()   -- every frame while running: no HUD, Backspace stops
        while running do
            HideHudAndRadarThisFrame()
            DisableControlAction(0, 194, true); DisableControlAction(0, 177, true); DisableControlAction(0, 200, true)
            if IsDisabledControlJustPressed(0, 194) or IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then stopAsked = true end
            Wait(0)
        end
    end)

    local done, failed, total = 0, 0, #models
    local started = GetGameTimer()
    for i, model in ipairs(models) do
        if stopAsked then break end
        local left = ''
        if done > 3 then
            local per = (GetGameTimer() - started) / (done + failed)
            left = (' · about %d min left'):format(math.ceil(per * (total - i) / 60000))
        end
        SendNUIMessage({ action = 'keys', title = ('Photo booth · %d of %d%s'):format(i, total, left),
            keys = { { 'Backspace', 'stop (it carries on next time)' } } })
        local hash = joaat(model)
        local ok = IsModelInCdimage(hash) and pcall(lib.requestModel, hash, 8000)
        local obj
        if ok then
            obj = CreateObjectNoOffset(hash, SPOT.x, SPOT.y, SPOT.z, false, false, false)
            FreezeEntityPosition(obj, true)
            frame(cam, obj, hash)
            local t = GetGameTimer() + 1500
            repeat Wait(0) until HasModelLoaded(hash) or GetGameTimer() > t
            Wait(350)   -- let the textures arrive at full quality
            local data = shoot()
            local b64 = type(data) == 'string' and data:find('^data:image') and crop(model, data)
            if b64 then
                local saved, err = lib.callback.await('dps-studio:thumbSave', false, model, b64)
                if saved then done = done + 1 else failed = failed + 1; print(('[dps-studio] photo %s: %s'):format(model, tostring(err))) end
            else
                failed = failed + 1
            end
            DeleteEntity(obj)
            SetModelAsNoLongerNeeded(hash)
        else
            failed = failed + 1
        end
    end

    running = false
    SendNUIMessage({ action = 'keys' })
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(cam, false)
    DisplayRadar(true)
    TriggerEvent('qb-weathersync:client:EnableSync')
    SetEntityCollision(ped, true, true)
    RequestCollisionAtCoord(back.x, back.y, back.z)
    SetEntityCoords(ped, back.x, back.y, back.z, false, false, false, false)
    SetEntityHeading(ped, backH)
    SetEntityVisible(ped, true, false)
    local t = GetGameTimer() + 4000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < t do Wait(50) end
    FreezeEntityPosition(ped, false)
    if not wasGod then SetEntityInvincible(ped, false) end
    StudioC.SetBusy(false)
    lib.notify({ type = 'success', description = ('Photo booth: %d pictures saved%s%s'):format(done,
        failed > 0 and (', ' .. failed .. ' skipped') or '', stopAsked and '. Stopped, it carries on next time.' or '.') })
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not running then return end
    running = false
    RenderScriptCams(false, false, 0, true, true)
    DisplayRadar(true)
    if backSpot then SetEntityCoords(cache.ped, backSpot.x, backSpot.y, backSpot.z, false, false, false, false) end
    FreezeEntityPosition(cache.ped, false)
    SetEntityVisible(cache.ped, true, false)
    SetEntityCollision(cache.ped, true, true)
end)
