-- CLIENT. DPS 2026-10-22: club crowds (see shared/crowds.lua). Each venue is a circle; walking into it
-- spawns that venue's crowd on this player's game only (local peds, never networked), walking out
-- removes it. Admins edit venues with /crowd.

local venues = {}
local points = {}     -- key -> lib.points object
local peds = {}       -- key -> { ped, ... }
local gen = {}        -- key -> number; a spawn still loading for an old generation drops its peds
local inside = {}     -- key -> true while this player is in the venue

local function load(hash)
    if not IsModelInCdimage(hash) then return false end
    return pcall(lib.requestModel, hash, 10000)
end

local function despawn(key)
    gen[key] = (gen[key] or 0) + 1
    for _, p in ipairs(peds[key] or {}) do if DoesEntityExist(p) then DeleteEntity(p) end end
    peds[key] = nil
end

local function place(hash, s)
    local p = CreatePed(4, hash, s.x, s.y, s.z, s.h or 0.0, false, true)
    SetEntityHeading(p, (s.h or 0.0) + 0.0)
    FreezeEntityPosition(p, true)
    SetEntityInvincible(p, true)
    SetBlockingOfNonTemporaryEvents(p, true)
    SetPedCanRagdoll(p, false)
    SetPedRandomComponentVariation(p, 0)
    SetPedRandomProps(p)
    return p
end

local function spawn(key)
    local v = venues[key]
    if not v then return end
    despawn(key)
    local my = gen[key]
    local list = {}
    peds[key] = list
    local function stale() return gen[key] ~= my end

    -- dancers: a shuffled share of the dance spots, by the venue's level
    local share = StudioCrowd.LEVELS[v.level] or 0.0
    local spots = {}
    for i, s in ipairs(v.dance or {}) do spots[i] = s end
    for i = #spots, 2, -1 do local j = math.random(i); spots[i], spots[j] = spots[j], spots[i] end
    local count = math.min(StudioCrowd.MAX, math.floor(#spots * share + 0.5))
    if count > 0 then
        if not pcall(lib.requestAnimDict, StudioCrowd.DANCE_DICT, 10000) then return end
        local models = {}
        for _, m in ipairs(StudioCrowd.MODELS) do
            local h = joaat(m)
            if load(h) then models[#models + 1] = h end
            if stale() then return end
        end
        if #models == 0 then return end
        for i = 1, count do
            if stale() then return end
            local p = place(models[math.random(#models)], spots[i])
            TaskPlayAnim(p, StudioCrowd.DANCE_DICT, StudioCrowd.DANCES[math.random(#StudioCrowd.DANCES)], 8.0, -8.0, -1, 1, 0, false, false, false)
            list[#list + 1] = p
            if i % 6 == 0 then Wait(0) end   -- spread the work over a few frames
        end
        for _, h in ipairs(models) do SetModelAsNoLongerNeeded(h) end
    end

    -- staff: DJ, bartenders, bouncers (whenever the venue is not off)
    if share > 0 then
        for _, s in ipairs(v.staff or {}) do
            local def = StudioCrowd.STAFF[s.kind]
            if def then
                local h = joaat(def.model)
                if not load(h) and def.fallback then h = joaat(def.fallback); load(h) end
                if stale() then return end
                if HasModelLoaded(h) then
                    local p = place(h, s)
                    if def.dict and pcall(lib.requestAnimDict, def.dict, 5000) then
                        TaskPlayAnim(p, def.dict, def.clip, 8.0, -8.0, -1, 1, 0, false, false, false)
                    elseif def.scenario then
                        TaskStartScenarioInPlace(p, def.scenario, 0, true)
                    end
                    list[#list + 1] = p
                    SetModelAsNoLongerNeeded(h)
                end
            end
        end
    end
end

local function setVenues(list)
    for key, pt in pairs(points) do pt:remove(); despawn(key) end
    points, venues = {}, type(list) == 'table' and list or {}
    local was = inside
    inside = {}
    for key, v in pairs(venues) do
        points[key] = lib.points.new({
            coords = vec3(v.x, v.y, v.z),
            distance = v.radius,
            onEnter = function() inside[key] = true; CreateThread(function() spawn(key) end) end,
            onExit = function() inside[key] = nil; despawn(key) end,
        })
        if was[key] then inside[key] = true; CreateThread(function() spawn(key) end) end   -- an edit shows at once
    end
end

RegisterNetEvent('dps-studio:crowds', setVenues)
CreateThread(function() setVenues(lib.callback.await('dps-studio:crowds', false)) end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for key in pairs(peds) do despawn(key) end
end)

-- ---------------------------------------------------------------- admin: /crowd
local HELP = '/crowd new <name> [words] · dance · staff dj|bartender|bouncer · level off|light|packed · undo [staff] · size <m> · info · show · delete'

---Draws every spot of the venue you stand in for 30 seconds: dance spots blue, staff orange.
local function show()
    local me = GetEntityCoords(cache.ped)
    local key
    for k, v in pairs(venues) do if #(me - vec3(v.x, v.y, v.z)) <= v.radius + 5.0 then key = k end end
    if not key then return lib.notify({ type = 'error', description = 'You are not inside any venue' }) end
    local v, untilT = venues[key], GetGameTimer() + 30000
    CreateThread(function()
        while GetGameTimer() < untilT do
            for _, s in ipairs(v.dance or {}) do DrawMarker(1, s.x, s.y, s.z, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.6, 80, 160, 255, 160, false, false, 2, false, nil, nil, false) end
            for _, s in ipairs(v.staff or {}) do DrawMarker(1, s.x, s.y, s.z, 0, 0, 0, 0, 0, 0, 0.6, 0.6, 0.8, 255, 122, 69, 180, false, false, 2, false, nil, nil, false) end
            Wait(0)
        end
    end)
    lib.notify({ type = 'inform', description = ('%s: %d dance spots (blue), %d staff (orange) for 30 s'):format(v.label, #(v.dance or {}), #(v.staff or {})) })
end

RegisterCommand('crowd', function(_, args)
    local action = (args[1] or ''):lower()
    if action == '' or action == 'help' then return lib.notify({ type = 'inform', description = HELP, duration = 12000 }) end
    if action == 'show' then return show() end
    local c = GetEntityCoords(cache.ped)
    local p = { x = c.x, y = c.y, z = c.z - 1.0, h = GetEntityHeading(cache.ped) }   -- the floor under your feet
    local arg = args[2]
    if action == 'new' then arg = { key = args[2], label = table.concat(args, ' ', 3) }
    elseif action == 'size' then action = 'radius'
    elseif arg then arg = arg:lower() end
    local ok, msg = lib.callback.await('dps-studio:crowdEdit', false, action, arg, p)
    lib.notify({ type = ok and 'success' or 'error', description = msg or (ok and 'Done' or 'Failed') })
end, false)
