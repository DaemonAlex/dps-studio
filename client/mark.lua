-- CLIENT (admin). Marking spots, saved to the database for the Spots tab.
--   PAGE UP or /spot [words]  saves where you stand with the nearest prop, street and area.
--   F3 or /pos               saves it too and shows the vector4 in a DPS card for 12 s.
-- Same keys as the old dps-markspot and dps-whatobject, so nothing changes for your hands.

StudioC = StudioC or {}

local function nearestObject(pos)
    local best, bestDist = nil, 6.0
    for _, obj in ipairs(GetGamePool('CObject')) do
        local d = #(GetEntityCoords(obj) - pos)
        if d < bestDist then best, bestDist = obj, d end
    end
    if not best then return nil, nil end
    return GetEntityModel(best), bestDist
end

function StudioC.MarkSpot(kind, label)
    if not StudioC.isAdmin or StudioC.busy then return end   -- Page Up also nudges pieces in fine tune
    local ped = cache.ped
    local c = GetEntityCoords(ped)
    local h = GetEntityHeading(ped)
    local hash, dist = nearestObject(c)
    local street = GetStreetNameFromHashKey(GetStreetNameAtCoord(c.x, c.y, c.z)) or ''
    local zone = GetLabelText(GetNameOfZone(c.x, c.y, c.z)) or ''
    local ok, id = lib.callback.await('dps-studio:spotSave', false, {
        kind = kind, label = label or '', x = c.x, y = c.y, z = c.z, h = h,
        propHash = hash, propDist = dist, street = street, zone = zone })
    if not ok then return lib.notify({ type = 'error', description = id or 'Spot not saved' }) end
    if kind == 'pos' then
        local text = ('vector4(%.2f, %.2f, %.2f, %.1f)'):format(c.x, c.y, c.z, h)
        print('^3[pos]^7 ' .. text)
        SendNUIMessage({ action = 'pos', text = text, id = id })
    else
        lib.notify({ type = 'success', title = ('Spot #%s saved'):format(tostring(id)),
            description = ('%s  %s'):format(label ~= '' and label or '', street) })
    end
    SendNUIMessage({ action = 'changed', what = 'spots' })
end

RegisterCommand('spot', function(_, args) StudioC.MarkSpot('spot', table.concat(args or {}, ' ')) end, false)
RegisterKeyMapping('spot', 'Studio: mark this spot', 'keyboard', 'PAGEUP')
RegisterCommand('pos', function() StudioC.MarkSpot('pos', '') end, false)
RegisterKeyMapping('pos', 'Studio: capture my coords (vector4)', 'keyboard', 'F3')
