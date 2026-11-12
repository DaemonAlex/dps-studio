-- CLIENT. Portals (DPS 2026-11-12, Damon): two places joined. A player walks up to either
-- side, presses E, the screen fades and they stand at the other side.
-- Staff make a portal one side at a time:
--   /portal     here is one side of a new portal (asks for a name). Go anywhere, by any means.
--   /portal     again at the other place: offers to finish a portal that still needs its other side.
--   /portals    the list (also the door button on the /studio panel): add the other side here,
--               move a side, rename, change the words, allow cars, lock it, go to it, remove it.
-- A portal with one side is saved for staff and shows nothing to players until it has both.
-- The lock is the room lock: everyone, or jobs and gangs from a rank up, named people, a passcode.

StudioC = StudioC or {}

local live = {}      -- id -> public portal
local points = {}    -- lib.points of both sides
local showing        -- key of the prompt on screen
local codeOk = {}    -- 'room:name' / 'portal:id' -> true once this player typed the right code

local function note(kind, text) lib.notify({ type = kind, description = text }) end
local function nui(msg) SendNUIMessage(msg) end

---Asks for a room's or portal's passcode and lets the server check it. Remembered until you leave the server.
function StudioC.AskCode(kind, key, label)
    local k = kind .. ':' .. tostring(key)
    if codeOk[k] then return true end
    local got = lib.inputDialog(label or 'Passcode', { { type = 'input', label = 'Passcode', password = true, required = true, max = 12 } })
    if not got or not got[1] or got[1] == '' then return false end
    local ok, err = lib.callback.await('dps-studio:code', false, kind, key, got[1])
    if ok then codeOk[k] = true return true end
    if err then note('error', err) end
    return false
end

local function mayUse(p)
    local a = p.access
    if not a or a.open or StudioC.isAdmin then return true end
    return Studio.MayEnterRoom(p, StudioC.Me())
end

---Takes the player (and their car, when the portal allows cars and they drive) to a spot.
local function go(p, to)
    local car = cache.vehicle
    if car then
        if not p.car then return note('error', 'Get out of the vehicle first') end
        if GetPedInVehicleSeat(car, -1) ~= cache.ped then return note('inform', 'The driver takes the car through') end
        DoScreenFadeOut(300)
        Wait(350)
        FreezeEntityPosition(car, true)
        RequestCollisionAtCoord(to.x, to.y, to.z)
        SetEntityCoords(car, to.x, to.y, to.z, false, false, false, false)
        SetEntityHeading(car, to.h + 0.0)
        local t = GetGameTimer() + 3000
        while not HasCollisionLoadedAroundEntity(car) and GetGameTimer() < t do Wait(50) end
        SetVehicleOnGroundProperly(car)
        FreezeEntityPosition(car, false)
        DoScreenFadeIn(300)
        return
    end
    StudioC.Move(vec3(to.x, to.y, to.z), to.h)
end

local function side(p, key, at, to, words)
    return lib.points.new({
        coords = vec3(at.x, at.y, at.z),
        distance = p.car and 4.0 or 2.0,
        onEnter = function()
            showing = key
            local open = mayUse(p)
            local text = open and words or ((p.access and p.access.code) and ('Enter the code · ' .. p.label) or ('Locked · ' .. p.label))
            nui({ action = 'prompt', key = text:find('^Locked') and '' or 'E', text = text })
        end,
        onExit = function() if showing == key then showing = nil; nui({ action = 'prompt' }) end end,
        nearby = function()
            if not IsControlJustPressed(0, 38) or StudioC.busy or StudioC.moving then return end
            StudioC.moving = true
            CreateThread(function()
                local ok = mayUse(p) or ((p.access and p.access.code) and StudioC.AskCode('portal', p.id, p.label))
                if ok then
                    showing = nil
                    nui({ action = 'prompt' })
                    pcall(go, p, to)
                else
                    note('error', p.label .. ' is locked')
                end
                StudioC.moving = false
            end)
        end,
    })
end

local function setAll(list)
    for _, pt in ipairs(points) do pt:remove() end
    points, live = {}, {}
    if showing then showing = nil; nui({ action = 'prompt' }) end
    for _, p in ipairs(list or {}) do
        if type(p) == 'table' and p.id and p.a and p.b then
            live[p.id] = p
            points[#points + 1] = side(p, 'portal:' .. p.id .. ':a', p.a, p.b, p.wordsA)
            points[#points + 1] = side(p, 'portal:' .. p.id .. ':b', p.b, p.a, p.wordsB)
        end
    end
end

RegisterNetEvent('dps-studio:portals', setAll)
CreateThread(function()
    Wait(1500)
    setAll(lib.callback.await('dps-studio:portals', false))
end)
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then for _, pt in ipairs(points) do pt:remove() end end
end)

-- ---------------------------------------------------------------- staff
local function isStaff()
    if not StudioC.isAdmin then StudioC.isAdmin = lib.callback.await('dps-studio:isAdmin', false) and true or false end
    return StudioC.isAdmin
end

local function here()
    local c = GetEntityCoords(cache.ped)
    return { x = c.x, y = c.y, z = c.z, h = GetEntityHeading(cache.ped) }
end

local function set(id, what, value)
    local ok, words = lib.callback.await('dps-studio:portalSet', false, id, what, value)
    note(ok and 'success' or 'error', words or (ok and 'Saved' or 'Not saved'))
    return ok
end

local function tp(spot)
    DoScreenFadeOut(250)
    Wait(300)
    RequestCollisionAtCoord(spot.x, spot.y, spot.z)
    SetEntityCoords(cache.ped, spot.x, spot.y, spot.z, false, false, false, false)
    SetEntityHeading(cache.ped, spot.h + 0.0)
    Wait(400)
    DoScreenFadeIn(250)
end

local openList   -- forward

local function groupOf(info, name) for _, g in ipairs(info.groups or {}) do if g.name == name then return g end end end

local function pickGroup(info, title, preset)
    local group = preset
    if not group then
        local opts = {}
        for _, g in ipairs(info.groups or {}) do opts[#opts + 1] = { value = g.name, label = ('%s (%s)'):format(g.label, g.kind) } end
        local got = lib.inputDialog(title, { { type = 'select', label = 'Job or gang', options = opts, required = true, searchable = true } })
        if not got or not got[1] then return nil end
        group = got[1]
    end
    local g, ranks = groupOf(info, group), {}
    for _, gr in ipairs(g and g.grades or {}) do ranks[#ranks + 1] = { value = tostring(gr.level), label = ('%d · %s'):format(gr.level, gr.name) } end
    if #ranks == 0 then ranks[1] = { value = '0', label = '0' } end
    local got = lib.inputDialog(('%s · %s'):format(title, g and g.label or group), {
        { type = 'select', label = 'Lowest rank', description = 'This rank and every rank above it', options = ranks, required = true, default = ranks[1].value } })
    if not got or not got[1] then return nil end
    return group, tonumber(got[1]) or 0
end

local function pickPerson(info, title)
    local opts = {}
    for _, p in ipairs(info.nearby or {}) do opts[#opts + 1] = { value = p.cid, label = p.name } end
    opts[#opts + 1] = { value = '_type', label = 'Type a citizen ID' }
    local got = lib.inputDialog(title, { { type = 'select', label = 'Who', description = #opts > 1 and 'People standing near you' or 'Nobody is standing near you', options = opts, required = true, searchable = true } })
    if not got or not got[1] then return nil end
    if got[1] ~= '_type' then return got[1] end
    local typed = lib.inputDialog(title, { { type = 'input', label = 'Citizen ID', required = true, min = 3, max = 20 } })
    local cid = typed and typed[1] and typed[1]:gsub('%s', '')
    return (cid and cid ~= '') and cid or nil
end

local function lockMenu(info, p)
    local a = p.access or { open = true, groups = {}, characters = {} }
    local opts = {
        { title = a.open and 'Open to everyone' or 'Locked to the list', description = a.open and 'Select to lock it to the list below' or 'Select to open it to everyone',
          icon = a.open and 'lock-open' or 'lock', onSelect = function() set(p.id, 'open', { on = not a.open }); openList(p.id, 'lock') end },
        { title = 'Add a job or gang', icon = 'users', onSelect = function()
            local g, grade = pickGroup(info, 'Add a job or gang')
            if g then set(p.id, 'group_set', { group = g, grade = grade }) end
            openList(p.id, 'lock')
        end },
        { title = 'Add a person', icon = 'user-plus', onSelect = function()
            local cid = pickPerson(info, 'Add a person')
            if cid then set(p.id, 'person_add', { cid = cid }) end
            openList(p.id, 'lock')
        end },
        { title = a.passcode and 'Passcode: set' or 'Passcode: none', description = 'Anyone with the code gets through. Select to set, change or clear it.', icon = 'key', onSelect = function()
            local got = lib.inputDialog('Passcode', { { type = 'input', label = 'New passcode', description = 'Letters and numbers, up to 12. Leave empty to clear it.', max = 12, password = true } })
            if got then set(p.id, 'passcode', { code = got[1] and got[1] ~= '' and got[1] or nil }) end
            openList(p.id, 'lock')
        end },
    }
    local names = {}
    for g in pairs(a.groups or {}) do names[#names + 1] = g end
    table.sort(names)
    for _, g in ipairs(names) do
        local gg = groupOf(info, g)
        opts[#opts + 1] = { title = (gg and gg.label or g) .. (' · rank %d and up'):format(a.groups[g]), description = 'Select to remove', icon = 'users', onSelect = function()
            set(p.id, 'group_remove', { group = g }); openList(p.id, 'lock')
        end }
    end
    for _, cid in ipairs(a.characters or {}) do
        local n = info.names and info.names[cid]
        opts[#opts + 1] = { title = (n and n ~= '') and n or cid, description = 'Select to remove', icon = 'user', onSelect = function()
            set(p.id, 'person_remove', { cid = cid }); openList(p.id, 'lock')
        end }
    end
    lib.registerContext({ id = 'dps_portal_lock', title = 'Who may use · ' .. p.label, menu = 'dps_portal_one', options = opts })
end

local function oneMenu(info, p)
    lockMenu(info, p)
    local ready = p.b ~= nil
    local a = p.access or { open = true }
    local opts = {}
    if not ready then
        opts[#opts + 1] = { title = 'Add the other side here', description = 'Where you stand now, facing the way people should face when they arrive', icon = 'location-dot', onSelect = function()
            if set(p.id, 'b', here()) then note('success', p.label .. ' is live. Walk up to it and press E.') end
            openList(p.id)
        end }
    end
    opts[#opts + 1] = { title = 'Move the first side here', description = ('Now at %.0f, %.0f, %.0f'):format(p.a.x, p.a.y, p.a.z), icon = 'arrows-up-down-left-right', onSelect = function() set(p.id, 'a', here()); openList(p.id) end }
    if ready then
        opts[#opts + 1] = { title = 'Move the second side here', description = ('Now at %.0f, %.0f, %.0f'):format(p.b.x, p.b.y, p.b.z), icon = 'arrows-up-down-left-right', onSelect = function() set(p.id, 'b', here()); openList(p.id) end }
    end
    opts[#opts + 1] = { title = 'Go to the first side', icon = 'person-walking-arrow-right', onSelect = function() tp(p.a) end }
    if ready then opts[#opts + 1] = { title = 'Go to the second side', icon = 'person-walking-arrow-right', onSelect = function() tp(p.b) end } end
    opts[#opts + 1] = { title = 'Rename', description = p.label, icon = 'pen', onSelect = function()
        local got = lib.inputDialog('Rename', { { type = 'input', label = 'Name', default = p.label, required = true, max = 40 } })
        if got and got[1] then set(p.id, 'label', got[1]) end
        openList(p.id)
    end }
    opts[#opts + 1] = { title = 'Words on the prompts', description = ('First side: %s · Second side: %s'):format(p.wordsA or ('Enter ' .. p.label), p.wordsB or ('Leave ' .. p.label)), icon = 'comment', onSelect = function()
        local got = lib.inputDialog('Words on the prompts', {
            { type = 'input', label = 'At the first side', description = 'Leave empty for "Enter ' .. p.label .. '"', default = p.wordsA or '', max = 40 },
            { type = 'input', label = 'At the second side', description = 'Leave empty for "Leave ' .. p.label .. '"', default = p.wordsB or '', max = 40 } })
        if got then set(p.id, 'wordsA', got[1] or ''); Wait(350); set(p.id, 'wordsB', got[2] or '') end
        openList(p.id)
    end }
    opts[#opts + 1] = { title = p.car and 'Cars: allowed' or 'Cars: on foot only', description = 'Select to change. With cars allowed the driver takes the car through.', icon = 'car', onSelect = function() set(p.id, 'car', not p.car); openList(p.id) end }
    opts[#opts + 1] = { title = a.open and 'Lock: open to everyone' or 'Lock: locked to its list', description = 'Jobs and gangs from a rank up, named people, a passcode', icon = a.open and 'lock-open' or 'lock', menu = 'dps_portal_lock', arrow = true }
    opts[#opts + 1] = { title = 'Remove this portal', icon = 'trash', onSelect = function()
        if lib.alertDialog({ header = 'Remove ' .. p.label .. '?', content = 'Both sides go. It stays in the Studio history.', centered = true, cancel = true }) == 'confirm' then
            set(p.id, 'delete')
            return openList()
        end
        openList(p.id)
    end }
    lib.registerContext({ id = 'dps_portal_one', title = (ready and '' or 'Needs its other side · ') .. p.label, menu = 'dps_portal_list', options = opts })
end

---The list of every portal, or one portal's menu when id is given.
openList = function(id, sub)
    local info = lib.callback.await('dps-studio:portalList', false)
    if not info then return note('error', 'Staff only') end
    local opts = { { title = 'New portal: one side here', description = 'Starts a portal where you stand. Add the other side later from this list.', icon = 'plus', onSelect = function() ExecuteCommand('portal new') end } }
    local chosen
    for _, p in ipairs(info.list) do
        if p.id == id then chosen = p end
        local ready = p.b ~= nil
        opts[#opts + 1] = { title = p.label, description = ready and 'Live' or 'Needs its other side', icon = ready and 'door-open' or 'door-closed',
            iconColor = ready and nil or '#ff7a45', onSelect = function() openList(p.id) end, arrow = true }
    end
    lib.registerContext({ id = 'dps_portal_list', title = ('Portals (%d)'):format(#info.list), options = opts })
    if chosen then
        oneMenu(info, chosen)
        return lib.showContext(sub == 'lock' and 'dps_portal_lock' or 'dps_portal_one')
    end
    lib.showContext('dps_portal_list')
end

RegisterCommand('portals', function()
    if not isStaff() then return note('error', 'Staff only') end
    CreateThread(function() openList() end)
end, false)

---/portal: one side of a new portal here, or finish one that is waiting for its other side.
RegisterCommand('portal', function(_, args)
    if not isStaff() then return note('error', 'Staff only') end
    CreateThread(function()
        local forceNew = args[1] and args[1]:lower() == 'new'
        if not forceNew then
            local info = lib.callback.await('dps-studio:portalList', false)
            local waiting = {}
            for _, p in ipairs(info and info.list or {}) do if not p.b then waiting[#waiting + 1] = p end end
            if #waiting > 0 then
                local opts = {}
                for _, p in ipairs(waiting) do opts[#opts + 1] = { value = tostring(p.id), label = 'Finish "' .. p.label .. '": the other side is here' } end
                opts[#opts + 1] = { value = 'new', label = 'Start a new portal here' }
                local got = lib.inputDialog('Portal', { { type = 'select', label = 'What is this spot', options = opts, required = true, default = opts[1].value } })
                if not got or not got[1] then return end
                if got[1] ~= 'new' then
                    local id = tonumber(got[1])
                    if set(id, 'b', here()) then note('success', 'It is live. Walk up to it and press E.') end
                    return
                end
            end
        end
        local spot = here()   -- the spot is where you stood when you typed it, not where you wander while naming it
        local got = lib.inputDialog('New portal', { { type = 'input', label = 'Name', description = 'Players see "Enter <name>" and "Leave <name>"', required = true, max = 40 } })
        if not got or not got[1] then return end
        local ok, res = lib.callback.await('dps-studio:portalCreate', false, got[1], spot)
        if not ok then return note('error', res or 'Not saved') end
        note('success', 'One side saved. Go to the other place by any means, then type /portal, or open /studio and press the door button.')
    end)
end, false)
