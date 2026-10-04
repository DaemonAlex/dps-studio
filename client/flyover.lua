-- CLIENT (admin). Map flyover: one picture straight down over every map pack, for review.
-- The server sends the packs still without a picture (/mapflyover). For each one the camera
-- hangs above the pack's centre looking down, the world streams in around it, and screencapture
-- takes the game view. Backspace stops; the next run carries on from the packs still missing.

StudioC = StudioC or {}

local FOV = 60.0
local running, stopAsked = false, false
local backSpot

local function shoot()
    SendNUIMessage({ action = 'keys' })   -- nothing of ours on screen while the picture is taken
    Wait(0)
    return lib.callback.await('dps-studio:flyShoot', false)
end

RegisterNetEvent('dps-studio:flyover', function(targets)
    if running or type(targets) ~= 'table' or #targets == 0 then return end
    if GetResourceState('screencapture') ~= 'started' then
        return lib.notify({ type = 'error', description = 'The map flyover needs screencapture running' })
    end
    running, stopAsked = true, false
    if StudioC.SetBusy then StudioC.SetBusy(true) end
    local ped = cache.ped
    local back, backH = GetEntityCoords(ped), GetEntityHeading(ped)
    backSpot = back
    local wasGod = GetPlayerInvincible(cache.playerId) or not GetEntityCanBeDamaged(ped)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    TriggerEvent('qb-weathersync:client:DisableSync')   -- hold the clock and weather for this player only
    NetworkOverrideClockTime(12, 0, 0)
    SetWeatherTypeNowPersist('EXTRASUNNY')
    SetRainLevel(0.0)
    DisplayRadar(false)
    local cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', back.x, back.y, back.z + 200.0, -90.0, 0.0, 0.0, FOV, false, 2)
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

    local done, failed, total = 0, 0, #targets
    for i, t in ipairs(targets) do
        if stopAsked then break end
        SendNUIMessage({ action = 'keys', title = ('Map flyover · %d of %d · %s'):format(i, total, t.name),
            keys = { { 'Backspace', 'stop (it carries on next time)' } } })
        local camZ = t.z + t.h
        SetEntityCoords(ped, t.x, t.y, camZ - 10.0, false, false, false, false)   -- the world streams around the player
        SetFocusPosAndVel(t.x, t.y, t.z, 0.0, 0.0, 0.0)
        RequestCollisionAtCoord(t.x, t.y, t.z)
        SetCamCoord(cam, t.x, t.y, camZ)
        SetCamRot(cam, -90.0, 0.0, 0.0, 2)
        SetCamFov(cam, FOV)
        Wait(t.h > 300 and 20000 or 15000)   -- let the area and its textures arrive (was 6 s / 4.5 s; close-up Sandy shots came out grey, Damon 10-04)
        local data = shoot()
        if type(data) == 'string' and data:find('^data:image') then
            local saved = lib.callback.await('dps-studio:flySave', false, t.name, data)
            if saved then done = done + 1 else failed = failed + 1 end
        else
            failed = failed + 1
            print(('[dps-studio] flyover %s: no picture came back'):format(t.name))
        end
    end

    running = false
    ClearFocus()
    SendNUIMessage({ action = 'keys' })
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(cam, false)
    DisplayRadar(true)
    ClearWeatherTypePersist()
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
    if StudioC.SetBusy then StudioC.SetBusy(false) end
    lib.notify({ type = 'success', description = ('Map flyover: %d pictures saved%s%s'):format(done,
        failed > 0 and (', ' .. failed .. ' skipped') or '', stopAsked and '. Stopped, it carries on next time.' or '.') })
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not running then return end
    running = false
    ClearFocus()
    RenderScriptCams(false, false, 0, true, true)
    DisplayRadar(true)
    if backSpot then SetEntityCoords(cache.ped, backSpot.x, backSpot.y, backSpot.z, false, false, false, false) end
    FreezeEntityPosition(cache.ped, false)
    SetEntityVisible(cache.ped, true, false)
    SetEntityCollision(cache.ped, true, true)
end)
