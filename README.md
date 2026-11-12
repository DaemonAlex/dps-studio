# dps-studio

Admin toolkit for Qbox servers: build walk-in rooms, place furniture, edit doors, mark spots and inspect objects from one panel opened with `/studio`.

## What it is for

Rooms, doors and portals that the people who use them can run themselves. An admin builds a room
or joins two places with a portal once. After that the owner decides who gets in: people, jobs
and gangs from a rank up, a key item, or a passcode. Owners can hand that job to managers. Staff
do not have to be called every time someone joins a business.

## Features

Everything below is admin only (ACE `dps.entityselector`) unless it says "all players".

**Rooms**
- Make a room from a housing shell (read from qs-housing) or from a real interior (bob74_ipl).
- Each room has a door in the world and a way out inside. Players press **E** at either one. The screen fades and moves them.
- Rooms can be locked. Access can be: everyone, staff, jobs or gangs (with a minimum grade), key items, specific citizen ids, or a passcode. Staff always get in.
- Rename a room, move its door, change its shell or way out, copy it, delete it, or teleport to it.
- **Owners and managers (1.5.0).** Staff set a room's owner once with `/roomowner`: a person, or a job or gang. After that no staff are needed. The owner side (the person, or the owner group's boss rank) and the managers they name change who gets in from the door itself: press **G** at any of the room's doors, or type `/roommanage`. They can add or remove people, add or remove jobs and gangs with a lowest rank, add or remove key items, set a passcode, and open or lock the room. The owner side can also name managers (people, or other groups from a rank up) and, for a group owner, lower the rank that counts as a leader. A group owner follows the rank, not the name. Managers always get into their own room. Every change is in History.
- **Place the shell (1.5.0).** A shell no longer has to sit 60 m under its door. Right after a new room is made, and any time with `/roomshell` at the room, a see-through copy of the shell stands in the world with an outline, a box of lines and a line from the door. Arrows slide it, Page Up / Down lift it, Q and E turn it (Shift for big steps, Alt for small), G brings it to where you stand, H puts it back under the door, Enter saves. The readout shows how far it is from the door, how far under or above, the floor height, the size and the facing. Furniture, the way out and extra doors move and turn with it. `/roomdepth <metres>` is the quick way to only change how far under (or, with a minus, above) the door it sits.
- **Buttons, not just commands (1.6.0).** The panel has a **Portals** tab: New portal at my spot, Add the other side where I stand, move or go to a side, rename, words, cars, who may use it, owner, remove. A room's page has Set the owner, Owner's door menu, See and move the shell, Add another door and Remove an extra door. The typed commands below still work and do the same things.
- **Portals (1.6.0).** A portal joins two places: walk up to either side, press E, arrive at the other. Staff make one a side at a time. `/portal` where you stand starts one and asks for a name. Go to the other place by any means, then `/portal` again, or open `/studio` and press the door button (`/portals`), and choose "Add the other side here". A portal with one side is saved and listed for staff, and shows nothing to players until it has both. A portal is a door: it has the same owner, managers and lock as a room (people, jobs and gangs from a rank up, key items, a passcode), and its owner runs the list from the portal itself with **G**. From the list: move a side, go to a side, rename, change the prompt words, allow cars, lock it (jobs and gangs from a rank up, named people, a passcode) or remove it. Changes show at once, with no restart.
- **Passcodes at the door (1.6.0).** A room or portal with a passcode shows "Enter the code" to people not on its list. The server checks the code; it is never sent to players' games. Five tries a minute.
- **Extra doors (1.5.0).** A shell room can have up to 4 more door pairs, all on the room's own lock. Staff: type `/roomexit` inside at the new door (facing into the room), then `/roomexit` again at the outside spot (facing away). `/roomexit remove` takes one away.
- Interior rooms serve one room per interior and cannot be copied.
- All players: rooms load when you are within 250 m and are removed when you leave. Inside a shell room the clock and rain are paused for you only.

**Looks and furniture**
- Every room holds saved looks (named sets of furniture). Make a new look (blank or a copy), rename, switch or delete it.
- Interior rooms also keep a style per look (bob74_ipl presets: default, full, empty, custom).
- Place any library object. Follow mode puts the piece where you look. Fine tune moves it 1 cm and 1 degree (Shift: 10 cm and 15 degrees).
- Move or remove placed pieces. A look holds up to 400 pieces.
- Hide library pieces from the Place list for every admin.

**Shells**
- Preview any shell in the sky, orbit the camera, and walk inside before you use it.

**Inspect**
- Hold middle mouse to see the model name, type, hash, coordinates, heading and whether you are in an interior. The card stays 8 seconds after release. The last 30 scans are kept in the Inspect tab.

**Spots**
- `/spot` and `/pos` save your position to the database. The Spots tab lists the last 400 and can teleport you to them.

**Doors (ox_doorlock)**
- List ox_doorlock doors, change name, locked state, access, auto lock, lockpick and range (1 to 10).
- Make new doors (look at the door and click; click a second door for a double door) and remove doors.
- Door access can be "Everyone" or "Staff only" on top of ox_doorlock's own groups, items, characters and passcode.
- A room can own doors. Changing the room's access updates all of them.

**History**
- Every room change and door change is logged with who and when. Put a room back to before a change, restore a removed room, or restore a door. The server keeps 200 snapshots per room. Older lines keep their text but cannot be restored.

**Photo booth**
- The Place tab can take a picture of every library piece. Each piece is placed alone in the sky and photographed twice (with and without it), then cut out and uploaded to Fivemanage. Pieces over 12 m, or pieces that never load or show nothing, are left out of Place. Backspace stops. The next run continues with the pieces still missing.

**Map flyover**
- `/mapflyover` flies a top-down camera over every map pack listed in `flyover/targets.json` that has no picture yet. Pictures (1600 x 900 webp) are saved as text files in `flyover/shots/<pack>.txt`. Backspace stops. The next run continues.

## Prerequisites

Required (set in `fxmanifest.lua`):
- `ox_lib`
- `oxmysql`

Used by the code, needed for the matching feature:
- `qbx_core` (job and gang lists and player data for door pickers and room access)
- `qs-housing` (the server reads `config/main.lua` for shells and `config/furniture.lua` for furniture, and the shell and furniture lists are empty without it)
- `ox_doorlock` (Doors tab, door access hook, room doors)
- `ox_inventory` (key item list and the key item check on room doors)
- `screencapture` (photo booth and `/mapflyover`)
- `bob74_ipl` (interior rooms and interior styles)
- A weather sync resource that answers `qb-weathersync:client:DisableSync` and `qb-weathersync:client:EnableSync` (used to hold the clock inside rooms, the booth and the flyover)
- A Fivemanage image key for the photo booth (see Configuration)

The Doors tab button runs `/doorlock`. The panel's fleet button runs `/fleet`. Those commands come from other resources.

The code does not state a minimum game build. It needs Lua 5.4 (`lua54 'yes'`).

## On its own, and with other scripts

**On its own.** With only `ox_lib`, `oxmysql` and Qbox, Studio builds portals, marks spots,
inspects objects and saves looks. A portal is the simplest useful thing it does: stand at an
office door, save one side, walk to the roof, save the other. Players now walk between them, and
the owner decides who may.

**With a paid housing script.** With qs-housing installed, Studio reads its shells and furniture
and turns them into rooms anywhere on the map: an office above a shop, a back room behind a bar, a
gang safehouse. Studio does not sell or rent homes and does not replace qs-housing. It uses the
same shells for places that are not homes, so one purchase does two jobs.

**With shell packs.** Every shell pack you add to qs-housing shows up in Studio with notes on
what it is good for. A ghost of the shell is shown while you place it, so a shell can be set
inside a real building without trapping players in a wall.

**With ox_doorlock.** Real doors on the map get the same owner, manager and lock rules as Studio
rooms, edited from the same panel.

**With an ox_inventory based inventory.** A room or portal can ask for a key item. Hand out the
item and you have handed out the key.

**With bob74_ipl.** The game's own closed interiors (offices, clubhouses, bunkers) become rooms
with a door wherever you want it. Each interior can be used once.

## Works with

| Resource | How |
|---|---|
| qbx_core | Job and gang lists, ranks and player data, for access rules and the owner pickers. |
| qs-housing | Shells and furniture are read from its config files. Studio does not change them. |
| ox_doorlock | The Doors tab edits its doors, and room doors use its access hook. |
| ox_inventory, or [dps-inventory](https://github.com/DaemonAlex/dps-inventory) | Key items: the item list for the picker and the check at a door. |
| bob74_ipl | Game interiors used as rooms, with their styles. Each interior can be used once. |
| screencapture | The photo booth and `/mapflyover`. |
| A qb-weathersync style weather resource | Holds the clock inside rooms, the booth and the flyover. |
| [dps-fleet](https://github.com/DaemonAlex/dps-fleet) | The panel's fleet button opens it. |

Each of these is optional except `ox_lib` and `oxmysql`. A missing one switches off its own
feature and nothing else.

## Recent changes

All 12 November 2026, version 1.6.0.

- **Owners and managers.** A room or portal has an owner, who can be a person or a group. The owner sets who gets in and can name managers to do it for them. Group leaders manage by rank until the owner says otherwise.
- **Portals.** Two places joined like a door. Make one side, go wherever the other side is, and finish it later from the Portals tab. A portal takes the same lock rules as a room.
- **Locks.** People, jobs and gangs from a rank up, key items, and a passcode.
- **Place the shell.** A ghost of the shell is shown while you move and turn it into place, so a shell can sit inside a real building. Each room keeps its own depth.
- **Buttons for everything.** Room tools (owner, manage, move the shell, add or remove an exit) are buttons in the panel. Nothing needs a typed command.
- **`/studio`.** The panel opens with `/studio`. It was `/admin`.
- **Esc.** Pressing Esc while Studio is in use closes the Studio screen and never opens the game's pause menu.
- **Shell notes.** All 216 shells now carry a note on their pack, use and type.
- **Game interiors.** The interior list reads from `bob74_ipl`. Only closed interiors are listed, and each can be used once.

## Other DPS scripts

All of these are made for DelPerroSands and run together on one Qbox server. Each one works on
its own. The ones marked "pairs with" do more when both are running.

| Script | What it does |
|---|---|
| [dps-inventory](https://github.com/DaemonAlex/dps-inventory) | The inventory: ox_inventory with equipment slots, backpacks, armour plates and a self status panel, in the DelPerroSands colours. |
| [dps-medical](https://github.com/DaemonAlex/dps-medical) | Patient records, illness and diagnostic tests. A companion to wasabi_ambulance. Pairs with dps-inventory: symptoms and diagnoses show on the status panel. |
| [dps-insurance](https://github.com/DaemonAlex/dps-insurance) | Ties m-Insurance into the MDT, impound, hospital and medical chart. Pairs with dps-medical. |
| [dps-shops](https://github.com/DaemonAlex/dps-shops) | Shop clerks who greet and react to a robbery, then player-owned shops. |
| [dps-fleet](https://github.com/DaemonAlex/dps-fleet) | Vehicle browser and workshop on one panel: extras, liveries and mods for emergency vehicles. |
| [dps-parking](https://github.com/DaemonAlex/dps-parking) | Parking with valet, impound, violations and reserved spots. |
| [dps-vehiclepersistence](https://github.com/DaemonAlex/dps-vehiclepersistence) | Vehicles stay where they were parked. Pairs with dps-parking. |
| [dps-towjob](https://github.com/DaemonAlex/dps-towjob) | Queue-based tow job with jg-mechanic integration. |
| [dps-services](https://github.com/DaemonAlex/dps-services) | Request a tow and follow it live on the lb-phone and lb-tablet. Pairs with dps-towjob. |
| [dps-autoshops](https://github.com/DaemonAlex/dps-autoshops) | Self-service repair shops when no mechanic is on duty. |
| [dps-cityworker](https://github.com/DaemonAlex/dps-cityworker) | City infrastructure job and career. |
| [dps-ainpcs](https://github.com/DaemonAlex/dps-ainpcs) | NPCs you can talk to, with trust, quests and intel. |
| [dps-badpeds](https://github.com/DaemonAlex/dps-badpeds) | Police interaction with NPCs: stops, arrests, intel and jail records. |
| [dps-gangwars](https://github.com/DaemonAlex/dps-gangwars) | Ambient gang NPCs, territory population and war reinforcements. |
| [dps-rotations](https://github.com/DaemonAlex/dps-rotations) | Moves dealers, harvests and other spots on a fixed schedule. |
| [dps-trains](https://github.com/DaemonAlex/dps-trains) | The train system. Pairs with dps-trains-stock, dps-traintools and dps-transitapp. |
| [dps-transitapp](https://github.com/DaemonAlex/dps-transitapp) | Live train arrival boards on the lb-phone. |
| [dps-faceplant](https://github.com/DaemonAlex/dps-faceplant) | City help, reports and staff tools on the lb-phone and lb-tablet. |
| [dps-chat](https://github.com/DaemonAlex/dps-chat) | A command box for voice-only servers. No chat feed. |
| [dps-filmmode](https://github.com/DaemonAlex/dps-filmmode) | One key hides every HUD layer and gives a smooth free camera for recording. |

## Installation

1. Put the folder in your resources directory as `dps-studio`.
2. `html/library.json` (the prop library) ships with the resource. Rebuild it with `tools/build_library.py` after adding prop packs.
3. Keep the resource folder writable by the server if you use `/mapflyover` (it writes `flyover/shots/`).
4. Add to `server.cfg`, after its dependencies:
   ```
   ensure ox_lib
   ensure oxmysql
   ensure qbx_core
   ensure ox_inventory
   ensure qs-housing
   ensure ox_doorlock
   ensure screencapture
   ensure bob74_ipl
   ensure dps-studio
   ```
5. Give admins the permission. `group.admin` is the usual group:
   ```
   add_ace group.admin dps.entityselector allow
   add_ace group.admin command.doorlock allow
   ```
   `dps.entityselector` opens Studio and every admin action. `command.doorlock` is also needed to make or remove doors from the Doors tab.
6. Optional, for the photo booth, set the key in `server.cfg` (keep it private):
   ```
   set dps:fivemanage_image "your_key"
   ```
7. Start the server. The tables are created on first start.

**SQL tables** (created automatically with `CREATE TABLE IF NOT EXISTS`):
`dps_studio_rooms`, `dps_studio_history`, `dps_studio_spots`, `dps_studio_thumbs`, `dps_studio_hidden`, `dps_studio_doors`, `dps_studio_meta`.

It also reads `ox_doorlock` (the ox_doorlock table must exist).

On first start the server imports `import/portals.json`, `import/spots.txt` and `import/pos_captures.txt` once (marked in `dps_studio_meta`). Delete those files' contents if you do not want that data. The import waits until the qs-housing shell and furniture lists can be read.

## Configuration

There is no config file. These values are at the top of the files. Change them in the file.

| File | Constant | Default | What it does |
|---|---|---|---|
| `shared/logic.lua` | `Studio.MAX_PIECES` | `400` | Most pieces in one look. |
| `shared/logic.lua` | `Studio.DEPTH` | `60.0` | How far under its door a shell room sits (metres). |
| `server/main.lua` | `ACE` | `dps.entityselector` | Permission for Studio. |
| `server/flyover.lua` | `ACE` | `dps.entityselector` | Permission for `/mapflyover`. |
| `server/main.lua` | `KEEP_SNAPSHOTS` | `200` | Restorable history snapshots kept per room. |
| `server/main.lua` | `FM_URL` | Fivemanage base64 upload URL | Where booth pictures are uploaded. |
| `client/booth.lua` | `SPOT` | `vec3(-2650, -4650, 1250)` | Sky spot used for photos. |
| `client/booth.lua` | `FOV` | `40.0` | Booth camera field of view. |
| `client/booth.lua` | `BIG` | `12.0` | Pieces larger than this (metres) are not photographed and are left out of Place. |
| `client/flyover.lua` | `FOV` | `60.0` | Flyover camera field of view. |
| `client/panel.lua` | `BASE` | `vec3(-2200, -4200, 1100)` | Sky spot used for shell previews. |

Other settings:
- Convar `dps:fivemanage_image`: Fivemanage key for photo uploads. Default empty.
- `flyover/targets.json`: list of map packs for `/mapflyover`. Each entry has `name`, `x`, `y`, `z`, `h` (camera height) and `n`.
- Door limits in the code: door name 1 to 40 characters, auto lock up to 3600 seconds, range 1.0 to 10.0.
- Room names: letters, numbers, `-` or `_`, up to 32. Door words 1 to 40 characters. Look names 1 to 30.

## Commands and keys

| Command or key | Who | What it does |
|---|---|---|
| `/studio` | Admins (`dps.entityselector`) | Opens or closes the Studio panel. Tabs: Rooms, Place, Shells, Inspect, Spots, Doors, Portals, History. |
| `/mapflyover` | Admins (`dps.entityselector`) | Starts the map flyover. Needs `screencapture`. |
| `/spot [words]` | Admins | Saves your position with the nearest prop, street and area. Default key **Page Up**. |
| `/pos` | Admins | Saves your position and shows a `vector4(...)` card for 12 seconds. Default key **F3**. |
| `/roommanage` | A room's owner and managers | At a room door or inside: who gets in (people, jobs and gangs from a rank up, passcode, open or locked) and, for the owner side, who else manages. Also **G** at any of the room's doors. |
| `/roomowner` | Admins | At a room: set its owner (a person, a job or gang, or nobody). |
| `/roomexit` | Admins | Add one more door to a shell room: run inside at the spot, then outside at the spot. `/roomexit remove`, `/roomexit cancel`. |
| `/roomshell` | Admins | See the room's shell in the world and move or turn it. `/roomshell reset` puts it back under the door. |
| `/roomdepth <metres>` | Admins | How far under its door the shell sits (minus = above). `/roomdepth default`. |
| `/portal` | Admins | One side of a new portal where you stand; again elsewhere to finish one that is waiting. |
| `/portals` | Admins | The portals list: add the other side, move, rename, words, cars, lock, go to, remove. Also the door button on the panel. |
| Middle mouse (hold) | Admins | Inspects the object you aim at. Rebindable in key settings (`+studio_scan`). |
| **E** at a room door | All players | Enter or leave a room (if allowed). |
| **Backspace** | Admins | Leaves previews, placing, door picking, the photo booth and the flyover. |
| **Tab** (placing) | Admins | Switches between follow mode and fine tune. |
| **Left click / Enter** (placing) | Admins | Saves the piece. |
| **Delete or X** (move or remove) | Admins | Removes the piece you look at. |
| **G** (walking a shell while making a room) | Admins | Marks the way out here. |

Page Up and F3 do nothing while you are placing or walking a shell.

## Troubleshooting

- **"Studio needs the admin permission (dps.entityselector)."** Your player does not have the ACE. Add the `add_ace` line and reconnect.
- **"Studio is still starting, try again in a moment."** The server is still loading tables and rooms. Wait for the `ready:` line in the console.
- **`furniture: could not read qs-housing config/furniture.lua`** or **`import waits: the qs-housing shell or furniture list could not be read`**. qs-housing is not started, or its config files are missing. Studio tries again later.
- **`library: html/library.json could not be read, only housing furniture can be placed`.** The file is missing or broken.
- **"That shell is not in the housing list."** The shell is not in qs-housing `Config.Shells`.
- **"The photo booth needs screencapture running" / "The map flyover needs screencapture running".** Start `screencapture` before `dps-studio`.
- **"No Fivemanage key on the server".** Set the `dps:fivemanage_image` convar.
- **"Upload failed (HTTP ...)"** or console line `photo upload for <model> failed`. Fivemanage refused the upload. Check the key.
- **"Making doors needs the door permission (command.doorlock)" / "Removing doors needs the door permission (command.doorlock)".** Add `command.doorlock` to the admin group.
- **"ox_doorlock did not save the door".** ox_doorlock is not running or did not save the new door within 3 seconds.
- **"ox_doorlock refused the change: ...".** ox_doorlock's `editDoor` raised an error.
- **Staff only or Everyone doors do not work.** The authorization hook is registered only when `ox_doorlock` is started. Restart `ox_doorlock` or Studio after starting it.
- **"That interior is not in the list" / "That interior now belongs to ...".** Interior rooms must use an interior from the list, and each interior serves one room. Check that `bob74_ipl` is started.
- **"This look is full (400 pieces)".** Remove pieces or make a new look.
- **"That change is too old to put back".** The snapshot was pruned (past 200 per room).
- **`room <name> has unreadable data and was skipped`.** The row in `dps_studio_rooms` is not valid JSON.
- **"This room did not load. Try again in a moment."** The shell model did not load in 15 seconds. You stay where you are.
- **"Get out of the vehicle first".** Room doors and teleports do not work from a vehicle.
