-- CLIENT. Interior (IPL) rooms through bob74_ipl, the interior loader the server already runs.
-- The style groups of every interior are read from bob74's own objects at run time:
--   theme groups  - tables of { interiorId, ipl } (an apartment's whole look, for example)
--   pick-one      - groups with a Set function: walls, furniture, decor ...
--   switch-on     - groups with an Enable function: details that can each be on or off
-- A style is applied with the plain natives (IPL on/off, entity sets on/off, refresh), and
-- bob74's own LoadDefault puts the interior back when the player leaves.

StudioC = StudioC or {}

local BOB = 'bob74_ipl'
local SKIP = { Set = true, Clear = true, Enable = true, Disable = true, Load = true, Remove = true, Refresh = true,
               Color = true, Colors = true, Colour = true, LoadDefault = true, Ipl = true, interiorId = true,
               currentInteriorId = true, Tint = true }

local catalogue          -- list sent to the page
local byExport = {}      -- export -> { entry, obj, groups, interiorId, at }

local function callable(v) return type(v) == 'function' or (type(v) == 'table' and getmetatable(v) ~= nil) end

---Every entity set name inside a value (a string, or a list/table of strings).
local function setsOf(v, out, depth)
    out = out or {}
    depth = depth or 0
    if type(v) == 'string' then
        if v ~= '' then out[#out + 1] = v end
    elseif type(v) == 'table' and depth < 3 and not callable(v) then
        for k, w in pairs(v) do
            if type(k) ~= 'string' or not SKIP[k] then setsOf(w, out, depth + 1) end
        end
    end
    return out
end

local function isVariant(v) return type(v) == 'table' and type(v.ipl) == 'string' and type(v.interiorId) == 'number' end

local function isArray(t) return type(t) == 'table' and #t > 0 and next(t, #t) == nil end

---Options of a pick-one or switch-on group. A string or a list is one option (a bundle of
---sets); a map of alternatives (Numbering.Level1 = { style1 = ..., style2 = ... }) becomes one
---option per alternative, so picking never turns on a whole family at once.
local function optionsOf(g)
    local opts = {}
    for k, v in pairs(g) do
        if type(k) == 'string' and not SKIP[k] and k ~= 'garageId' then
            if type(v) == 'string' or isArray(v) then
                local sets = setsOf(v)
                if #sets > 0 then opts[#opts + 1] = { key = k, sets = sets } end
            elseif type(v) == 'table' and not callable(v) then
                for kk, vv in pairs(v) do
                    if type(kk) == 'string' and not SKIP[kk] then
                        local sets = setsOf(vv)
                        if #sets > 0 then opts[#opts + 1] = { key = k .. '.' .. kk, sets = sets } end
                    end
                end
            end
        end
    end
    table.sort(opts, function(a, b) return a.key < b.key end)
    return opts
end

local function readGroups(obj, prefix, depth)
    local groups = {}
    depth = depth or 0
    for gk, g in pairs(obj) do
        if type(gk) == 'string' and not SKIP[gk] and type(g) == 'table' and not callable(g) then
            local key = prefix and (prefix .. '.' .. gk) or gk
            local target = tonumber(g.interiorId) or tonumber(g.garageId)   -- a group can live on another interior
            -- theme: a table of variants, directly or one level down (Style.Theme)
            local variants
            for _, sub in pairs(g) do
                if type(sub) == 'table' and not callable(sub) then
                    local all, n = true, 0
                    for _, v in pairs(sub) do n = n + 1; if not isVariant(v) then all = false end end
                    if all and n > 0 then variants = sub end
                end
            end
            if not variants then
                local all, n = true, 0
                for k, v in pairs(g) do
                    if not SKIP[k] then n = n + 1; if not isVariant(v) then all = false end end
                end
                if all and n > 0 then variants = g end
            end
            -- only a group bob74 switches with Set is a real theme; parts loaded side by side
            -- (an office garage's floors) are left exactly as bob74 loads them
            if variants and g.Set == nil then variants = nil end
            if variants then
                local opts = {}
                for k, v in pairs(variants) do opts[#opts + 1] = { key = tostring(k), ipl = v.ipl, interiorId = v.interiorId } end
                table.sort(opts, function(a, b) return a.key < b.key end)
                groups[#groups + 1] = { key = key, kind = 'theme', options = opts }
            elseif g.Set ~= nil or g.Enable ~= nil then
                local opts = optionsOf(g)
                if #opts > 0 then groups[#groups + 1] = { key = key, kind = g.Set ~= nil and 'one' or 'many', options = opts, target = target } end
            elseif depth < 1 then
                -- a folder of groups (Penthouse.Interior.Pattern): read one level down
                for _, sub in ipairs(readGroups(g, key, depth + 1)) do groups[#groups + 1] = sub end
            end
        end
    end
    table.sort(groups, function(a, b) return a.key < b.key end)
    return groups
end

local function interiorOf(info, variant)
    if variant and variant.interiorId then return variant.interiorId end
    local id = info.obj and (tonumber(info.obj.interiorId) or tonumber(info.obj.currentInteriorId))
    if id and id > 0 then return id end
    if info.at then return GetInteriorAtCoords(info.at.x, info.at.y, info.at.z) end
end

---Reads every interior once. Returns the list for the page.
function StudioC.IplCatalogue()
    if catalogue then return catalogue end
    if GetResourceState(BOB) ~= 'started' then return {} end   -- not cached: try again next time
    catalogue = {}
    for _, e in ipairs(StudioIpls or {}) do
        local ok, obj = pcall(function() return exports[BOB][e.export]() end)
        if ok and type(obj) == 'table' then
            local info = { entry = e, obj = obj, groups = readGroups(obj) }
            local theme
            for _, g in ipairs(info.groups) do if g.kind == 'theme' then theme = g.options[1] end end
            info.at = e.at
            info.interiorId = interiorOf(info, theme)
            if not info.at and info.interiorId and info.interiorId > 0 then
                local x, y, z = GetInteriorPosition(info.interiorId)
                if type(x) == 'vector3' then info.at = x elseif x then info.at = vec3(x, y, z) end
            end
            if info.at then
                byExport[e.export] = info
                local groups = {}
                for i, g in ipairs(info.groups) do
                    local opts = {}
                    for j, o in ipairs(g.options) do opts[j] = o.key end
                    groups[i] = { key = g.key, kind = g.kind, options = opts }
                end
                catalogue[#catalogue + 1] = { export = e.export, group = e.group, label = e.label, groups = groups }
            end
        end
    end
    table.sort(catalogue, function(a, b) return a.group == b.group and a.label < b.label or a.group < b.group end)
    return catalogue
end

function StudioC.IplAt(export)
    StudioC.IplCatalogue()
    local info = byExport[export]
    return info and info.at
end

local BLOCKERS = { 'block', 'lock', 'closed', 'wall', 'shut', 'sealed', 'none', 'empty', 'off' }
local function blocker(key)
    key = key:lower()
    for _, w in ipairs(BLOCKERS) do if key:find(w, 1, true) then return true end end
    return false
end

---Applies a style to an interior for this player.
---default: bob74's own look. full: bob74's look plus every extra that adds something (never a
---lock or a wall). empty: bob74's look with every extra off (walls, tiers and floors stay).
---custom: the chosen option in each group.
function StudioC.IplApply(export, style)
    StudioC.IplCatalogue()
    local info = byExport[export]
    if not info then return false end
    style = type(style) == 'table' and style or { preset = 'default' }
    local preset = style.preset or 'default'
    if info.obj.LoadDefault then pcall(info.obj.LoadDefault) end
    if preset == 'default' then
        local id = interiorOf(info)
        if id and id > 0 then RefreshInterior(id) end
        return true
    end
    local choice, on = type(style.choice) == 'table' and style.choice or {}, type(style.on) == 'table' and style.on or {}
    local variant
    for _, g in ipairs(info.groups) do
        if g.kind == 'theme' and preset == 'custom' and choice[g.key] then
            local chosen
            for _, o in ipairs(g.options) do if o.key == choice[g.key] then chosen = o end end
            if chosen then
                for _, o in ipairs(g.options) do if o ~= chosen then RemoveIpl(o.ipl) end end
                RequestIpl(chosen.ipl)
                variant = chosen
            end
        end
    end
    local base = interiorOf(info, variant)
    if not base or base == 0 then return false end
    -- which groups this preset changes, and to what
    local wantOn, touched = {}, {}
    for _, g in ipairs(info.groups) do
        if g.kind ~= 'theme' then
            local id = g.target or base
            local change = false
            if preset == 'custom' then change = true
            elseif g.kind == 'many' then change = true
            elseif preset == 'empty' then
                for _, o in ipairs(g.options) do if o.key:lower():find('none', 1, true) or o.key:lower():find('empty', 1, true) then change = true end end
            end
            if change then
                touched[#touched + 1] = { g = g, id = id }
                for _, o in ipairs(g.options) do
                    local want
                    if preset == 'custom' then
                        want = (g.kind == 'one' and choice[g.key] == o.key) or (g.kind == 'many' and on[g.key] and on[g.key][o.key])
                    elseif preset == 'full' then
                        want = g.kind == 'many' and not blocker(o.key)
                    elseif preset == 'empty' then
                        want = g.kind == 'one' and (o.key:lower():find('none', 1, true) or o.key:lower():find('empty', 1, true))
                    end
                    if want then for _, s in ipairs(o.sets) do wantOn[id .. ':' .. s] = { id, s } end end
                end
            end
        end
    end
    -- two passes, so groups that share sets never undo each other: all off, then the wanted on
    local refresh = { [base] = true }
    for _, t in ipairs(touched) do
        refresh[t.id] = true
        for _, o in ipairs(t.g.options) do for _, s in ipairs(o.sets) do DeactivateInteriorEntitySet(t.id, s) end end
    end
    for _, v in pairs(wantOn) do ActivateInteriorEntitySet(v[1], v[2]) end
    for id in pairs(refresh) do RefreshInterior(id) end
    return true
end

---Puts an interior back the way bob74 loads it.
function StudioC.IplReset(export)
    local info = byExport[export]
    if info and info.obj.LoadDefault then pcall(info.obj.LoadDefault) end
    local id = info and interiorOf(info)
    if id and id > 0 then RefreshInterior(id) end
end

-- ---------------------------------------------------------------- visiting an interior (admin)
-- Go inside to look around, try styles live, and (when making a room) press G where people
-- should arrive. The style is only on this player's screen.
local visit   -- { export, back = vec4, style }

function StudioC.IplVisiting() return visit and visit.export end
function StudioC.IplVisitStyle() return visit and visit.style end

function StudioC.IplVisit(export, style)
    local at = StudioC.IplAt(export)
    if not at then return false, 'That interior did not load' end
    local ped = cache.ped
    if not visit then
        local p = GetEntityCoords(ped)
        visit = { back = vec4(p.x, p.y, p.z, GetEntityHeading(ped)) }
    elseif visit.export and visit.export ~= export then
        StudioC.IplReset(visit.export)
    end
    visit.export, visit.style = export, style
    DoScreenFadeOut(250)
    Wait(300)
    StudioC.IplApply(export, style)
    FreezeEntityPosition(ped, true)
    RequestCollisionAtCoord(at.x, at.y, at.z)
    SetEntityCoords(ped, at.x, at.y, at.z, false, false, false, false)
    local t = GetGameTimer() + 3000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < t do Wait(50) end
    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(300)
    return true
end

function StudioC.IplRestyle(export, style)
    if visit and visit.export == export then
        visit.style = style
        StudioC.IplApply(export, style)
    end
end

---Ends a visit. `to` = where to put the player (default: where they stood), or stay = true
---to leave the player where they are (when another move follows at once).
function StudioC.IplLeave(to, stay)
    if not visit then return end
    local v = visit
    visit = nil
    if v.export then StudioC.IplReset(v.export) end
    if stay then return end
    local b = to or v.back
    local ped = cache.ped
    DoScreenFadeOut(250)
    Wait(300)
    FreezeEntityPosition(ped, true)
    RequestCollisionAtCoord(b.x, b.y, b.z)
    SetEntityCoords(ped, b.x, b.y, b.z, false, false, false, false)
    SetEntityHeading(ped, (b.w or b.h or 0.0) + 0.0)
    local t = GetGameTimer() + 3000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < t do Wait(50) end
    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(300)
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not visit then return end
    if visit.export then StudioC.IplReset(visit.export) end
    SetEntityCoords(cache.ped, visit.back.x, visit.back.y, visit.back.z, false, false, false, false)
    FreezeEntityPosition(cache.ped, false)
    DoScreenFadeIn(0)
end)
