-- CLIENT (admin). Hold MIDDLE MOUSE to inspect whatever you aim at: an orange box and
-- name in the world, and a card in the DPS look. The card stays 8 s after release.
-- The last 30 scans are kept for the Inspect tab. Ported from dps-whatobject v2; every
-- entity native runs only after DoesEntityExist and inside pcall (map handles can crash).

StudioC = StudioC or {}
StudioC.scans = {}

local scanning, running = false, false

local function forward()
    local rot = GetGameplayCamRot(2)
    local x, z = math.rad(rot.x), math.rad(rot.z)
    return vector3(-math.sin(z) * math.abs(math.cos(x)), math.cos(z) * math.abs(math.cos(x)), math.sin(x))
end

local function raycast()
    local cam = GetGameplayCamCoord()
    local dest = cam + forward() * 100.0
    local ray = StartShapeTestRay(cam.x, cam.y, cam.z, dest.x, dest.y, dest.z, -1, cache.ped, 4)
    local _, hit, _, _, entity = GetShapeTestResult(ray)
    if hit == 1 and entity and entity ~= 0 and entity ~= cache.ped and DoesEntityExist(entity) then return entity end
end

local function nameOf(e)
    local name
    pcall(function()
        local n = GetEntityArchetypeName(e)
        if type(n) == 'string' and n ~= '' then name = n end
    end)
    if not name then
        local ok, h = pcall(GetEntityModel, e)
        name = (ok and h) and ('hash ' .. h) or 'unknown'
    end
    return name
end

local function drawBox(e)
    pcall(function()
        local model = GetEntityModel(e)
        if not model or model == 0 then return end
        local mn, mx = GetModelDimensions(model)
        local f, r, u, p = GetEntityMatrix(e)
        local function c(a, b, d) return p + r * a + f * b + u * d end
        local b = { c(mn.x, mn.y, mn.z), c(mx.x, mn.y, mn.z), c(mx.x, mx.y, mn.z), c(mn.x, mx.y, mn.z),
                    c(mn.x, mn.y, mx.z), c(mx.x, mn.y, mx.z), c(mx.x, mx.y, mx.z), c(mn.x, mx.y, mx.z) }
        local function L(i, j) DrawLine(b[i].x, b[i].y, b[i].z, b[j].x, b[j].y, b[j].z, 255, 122, 69, 255) end
        L(1, 2); L(2, 3); L(3, 4); L(4, 1); L(5, 6); L(6, 7); L(7, 8); L(8, 5); L(1, 5); L(2, 6); L(3, 7); L(4, 8)
    end)
end

local function collect(e)
    local d = { name = nameOf(e) }
    pcall(function()
        local t = GetEntityType(e)
        d.kind = t == 1 and 'Person' or t == 2 and 'Vehicle' or t == 3 and 'Object' or 'Unknown'
        d.hash = GetEntityModel(e)
        local p = GetEntityCoords(e, true)
        d.x, d.y, d.z, d.h = p.x, p.y, p.z, GetEntityHeading(e)
        local piece = StudioC.pieceByEntity[e]
        if piece then d.note = 'Studio piece in ' .. piece.name end
    end)
    return d
end

local function run()
    if running then return end
    running = true
    CreateThread(function()
        local last
        while scanning do
            DrawRect(0.5, 0.5, 0.003, 0.005, 255, 122, 69, 220)
            local e = raycast()
            if e then
                drawBox(e)
                local d = collect(e)
                if not last or last.name ~= d.name or last.x ~= d.x then
                    last = d
                    SendNUIMessage({ action = 'inspect', card = d })
                end
            elseif last then
                last = nil
                SendNUIMessage({ action = 'inspect', card = { name = 'Nothing here', note = 'Map ground and buildings baked into the map cannot be read. Aim at a prop, car or person.' } })
            end
            Wait(0)
        end
        if last then
            table.insert(StudioC.scans, 1, last)
            if #StudioC.scans > 30 then StudioC.scans[31] = nil end
        end
        SendNUIMessage({ action = 'inspect', linger = 8000 })
        running = false
    end)
end

RegisterCommand('+studio_scan', function() if StudioC.isAdmin and not StudioC.busy then scanning = true; run() end end, false)
RegisterCommand('-studio_scan', function() scanning = false end, false)
RegisterKeyMapping('+studio_scan', 'Studio: hold to inspect what you aim at', 'MOUSE_BUTTON', 'MOUSE_MIDDLE')
