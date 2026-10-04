# dps-studio

Admin toolkit for Qbox servers: build walk-in rooms, place furniture, edit doors, mark spots and inspect objects from one panel opened with `/admin`.

## Features

Everything below is admin only (ACE `dps.entityselector`) unless it says "all players".

**Rooms**
- Make a room from a housing shell (read from qs-housing) or from a real interior (bob74_ipl).
- Each room has a door in the world and a way out inside. Players press **E** at either one. The screen fades and moves them.
- Rooms can be locked. Access can be: everyone, staff, jobs or gangs (with a minimum grade), key items, specific citizen ids, or a passcode. Staff always get in.
- Rename a room, move its door, change its shell or way out, copy it, delete it, or teleport to it.
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
| `/admin` | Admins (`dps.entityselector`) | Opens or closes the Studio panel. Tabs: Rooms, Place, Shells, Inspect, Spots, Doors, History. |
| `/mapflyover` | Admins (`dps.entityselector`) | Starts the map flyover. Needs `screencapture`. |
| `/spot [words]` | Admins | Saves your position with the nearest prop, street and area. Default key **Page Up**. |
| `/pos` | Admins | Saves your position and shows a `vector4(...)` card for 12 seconds. Default key **F3**. |
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
