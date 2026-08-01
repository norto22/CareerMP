# CareerMP 0.39 - community port, partially tested
Enabling [BeamNG.drive](https://beamng.com/game/)'s Career Mode in [BeamMP](https://beammp.com/) servers.

<img width="2468" height="861" alt="image" src="https://github.com/user-attachments/assets/bd9bcb2f-530f-4fcd-a76b-732ec6ce7159" />

> ### About this fork
>
> This is a fork of [StanleyDudek/CareerMP](https://github.com/StanleyDudek/CareerMP) 0.0.37,
> ported to **BeamNG.drive 0.39.2.1**. All of the design and nearly all of the behaviour is
> Dudekahedron's; this fork updates it for the 0.39 career rewrite.
>
> **Partially tested, on BeamNG 0.39.2.1 with official BeamMP 0.39 support.** Developed
> against the 0.38.6 and 0.39 game trees, first run on 0.39 with an unofficial
> 0.39-capable BeamMP build while no official one existed, then re-verified on BeamMP's own
> 0.39 release, and most recently on 0.39.2.1.
> "Partially" refers to coverage — the features below work, the ones after them have not
> been tried at all.
>
> Confirmed working in a live session on official BeamMP:
> - joining a server and having the career profile create and load
> - buying a starter vehicle from a dealership
> - part customization, including being seated in the vehicle so edits sync
> - parcel deliveries
> - **head-to-head drag racing between two players** — staging, a synchronised tree, the
>   run, a shared result screen, and the strip clearing itself afterwards. Also exercised:
>   solo runs, false starts, and racing an AI bot in a BMRA mission with the multiplayer
>   layer standing clear of it
>
> Not yet exercised: tuning and painting menus, insurance and repairs, prefab sync,
> per-part paint sync between players, and more than two players at once. Everything
> other than drag racing was tested solo, so most of what depends on two clients agreeing
> is still unproven.
>
> Expect to debug it. If something misbehaves, check the console first:
> `careerMP.compat` logs any game API that moved, and `careerMP.patches` logs whether
> its runtime patches installed. Between them they name most failures directly.
>
> If you are porting something else to 0.39, or want to pick this up,
> [docs/0.39-PORTING-RESEARCH.md](docs/0.39-PORTING-RESEARCH.md) has the full analysis:
> what 0.39 renamed, the 3-way diff method used to recover the original mod's intent,
> the dormant multiplayer code 0.39 ships, and the bugs found along the way.
>
> Issues and PRs welcome. If Dudekahedron ports the original, this fork should defer to it.

## Overview
The goal of CareerMP is not to change the base game career mode or create my own unique multiplayer career mode like others have done before to good effect, but to provide whatever handling is necessary on the BeamMP client and server to allow the base game career mode to function as multiplayer, so you can play career mode with friends in the same space.

This is basically the same as single player career mode, but there will be real players doing their own careers as well.

## Highlights / Features
- Support for all base-game career features at parity with single player career mode
- Saves are local, you can continue on another server running CareerMP, you can take an online save offline and vice versa
- Mod vehicles that the base game already support in career mode can spawn in traffic and can be found at dealerships
- Render distance of vehicles have been increased so that you can see players on the bigMap
- By default, simple_traffic models are used, in freeroaming career, players can spawn a server configured number of road and parked traffic vehicles each; missions, challenges, scenarios add additional unmetered traffic
- Traffic Signals are synced, for a congruent experience for all players
- Red light camera / speed trap data broadcasts
- Dragrace tree, scoreboard display, and winner light syncing — **now driven by BeamNG's
  own multiplayer drag code** rather than re-implemented. Two players drive to a strip,
  stage, and race head to head on one synchronised tree with a shared timeslip at the end.
  On by default; set `client.nativeDragSyncEnabled = false` to go back to stock
  single-player drag racing (see Known gaps)
- Missions, challenges, scenarios prefabs (track layouts, barriers, hay bales, barrels, arrow signs, gates, unique structures, et cetera) are synced on the fly so you can observe others engage in these activities and have to find creative ways around should they block your path
- MP UI app injection into missions, challenges, scenarios, making sure you can see chat or quit the session from most points of play
- Syncing the active states (shown or hidden) of vehicles is a critical part of behind the scenes functionality
- Nametag visibility supression for many spawnables including traffic to limit visual clutter
- Playerlist based payment system to pay other players
- ~~Handful of fixed basegame bugs related to insurance~~ — dropped on 0.39, which fixes
  them upstream and changed the data shape they relied on (see Known gaps)

## Requirements
Due to multiplayer overhead, client performance requirements are accordingly more demanding than single player career. Players with moderate systems have reported 5-10% impact compared to an unmodded BeamMP server lobby, high end systems are not really affected, and low end systems will suffer and struggle to maintain realtime physics and position sync if they are running fewer than 20-30 FPS.

This fork targets:
- BeamNG.drive **v0.39.2.1** (tested on build 20887; also run on 0.39.1 build 20878 and
  developed against 0.39.0 build 20859 — nothing this port depends on changed between
  them)
- BeamMP Server / Launcher / Client with official 0.39 support — tested against the
  release published 30 July 2026

The upstream 0.0.37 was last verified to work on:
- BeamNG.drive v0.38.5
- BeamMP Server v3.9.2
- BeamMP Launcher v2.8.0
- BeamMP Client v4.21.1

Updates to any of these could possibly render CareerMP non-functional without notice —
BeamMP's 0.39 release already renamed every one of its UI apps, which is the kind of
change that breaks a mod quietly rather than loudly. If something does break after a
BeamMP update, these are the surfaces this fork depends on:

- `MPVehicleGE.getVehicles` / `isOwn` / `getServerVehicleID` / `getGameVehicleID` / `getPlayers`
- `MPConfig.getNickname` / `getPlayerServerID`
- `MPCoreNetwork.isMPSession`
- `TriggerServerEvent` / `AddEventHandler`
- the `multiplayer_multiplayer.onUpdate` patch and `serverConnection.onCameraHandlerSetInitial`
  in `careerMPEnabler`
- `veh.mpVehicleType == 'R'`, used to flip the driver side for remote vehicles
- the UI app names `beammpChat` and `beammpSession`, injected into career layouts.
  0.39 renamed these from `multiplayerchat` / `multiplayersession`; a layout naming an app
  that no longer exists renders as a red dashed "Unknown app" box rather than an error.
  `careerMPUIApps.lua` keeps a `retiredApps` list that strips old names on join, so
  adding the next rename there is the whole fix
- `vehicles/unicycle/beammp_default.pc`, the visible walking avatar — the patch falls back
  to the stock invisible config if it is absent, so a missing file shows up as an invisible
  player rather than an error

## Installation
1. Download this repository (or the latest [release](https://github.com/vladmaksimenko-0/CareerMP-0.39/releases/) once one exists) and unpack the contents to the root directory of your BeamMP server directory
2. Set `MaxCars = 100` or greater in your `ServerConfig.toml`
3. Set `Map = "/levels/west_coast_usa/info.json"` in your `ServerConfig.toml`
4. Once the server is run with CareerMP installed, a config file will be generated, and a client mod .zip will be fetched if it is not present in `.../Resources/Client/`.
5. Configure CareerMP how you like from the server console, or by editing the settings in `.../Resources/Server/CareerMP/config/config.json`
6. Since version 0.0.28, CareerMP can autoUpdate itself. Once installed on your server, there are various ways to apply the update, from Restarting the server to manually running console commands, and if you have restart scripts for your server, then it also supports autoExit


## Server Console Usage
To see CareerMP server console commands, type `CareerMP Help` in the server console

<img width="1098" height="155" alt="image" src="https://github.com/user-attachments/assets/ffe64e84-09db-4894-8338-3835dbad39ac" />


## Notes
As CareerMP relies on the base game's career mode, it currently will only function on the West Coast, USA map.

CareerMP provides no player moderation itself, and should not conflict with the server moderation plugin of your choice, provided all players can be allowed to spawn at least 100 vehicles.

CareerMP uses your BeamMP username (or the server configured save name) to create a save file, and will currently always start you in the save file matching your BeamMP username (or the server configured save name) when you join the server. You can continue this file offline, you can continue this save in any other server running CareerMP, if you would like to use a specific file from single player to autoload online in a server running CareerMP, you can make sure the save file's save name matches your BeamMP username (or the server configured save name) before joining. You may also load any save from the ESC menu in game.

**0.39 changes how that name is handled.** Career saves are now "profiles", and 0.39
lowercases the name and strips everything that is not a letter or digit, keeping your
original text separately as a display name. So the profile folder for `Player_One`
is `playerone`. Two consequences:

- Usernames differing only in punctuation or case share a profile (`Player_1` and
  `player1` both become `player1`).
- 0.39 also de-duplicates new profile names against the ones already on that machine
  (`name`, `name1`, `name2`...). This fork sanitises the username itself before handing
  it over, specifically so the same username maps to the same folder on every machine —
  otherwise "continue this save on any other CareerMP server" would stop being true.

Be aware that using the same save across modded servers and unmodded servers will likely face compatibility issues.

Currently everyone’s vehicle marketplace will be local to their save, that is, you cannot currently exchange vehicles with other players, but I hope to make this available, I believe it’s quite possible.

## What changed in this port

The full analysis is in [docs/0.39-PORTING-RESEARCH.md](docs/0.39-PORTING-RESEARCH.md).
The short version:

0.0.37 shipped copies of 10 game files (~6,600 lines) at the game's own paths so its
copies would win. Diffing those against a pristine 0.38.6 tree shows their actual intent
is only **~136 changed lines**, mostly adding one argument to an `extensions.hook(...)`
call so CareerMP could tell *which* vehicle an event was about. That intent is invisible
without the diff, because the forked files carry no markers.

So this port re-expressed that intent as runtime patches instead of file copies. The
game's files are left alone; a thin wrapper on each module's entry point records the
vehicle, and the stock hook still supplies the timing. **Forks went from 10 to 2** — only
`computer.lua` (garage computer tether widened from 4m/1m to 25m, because multiplayer
position jitter alone closes the stock tether) and `playerDriving.lua` (traffic metered by
server config) still need copies, because those values are file-locals that cannot be
reached at runtime.

Drag racing is the interesting one. **0.39 ships a complete multiplayer drag racing
implementation and then switches it off** — `gameplay/drag/core.lua` stubs
`getDragGamemode()` to return nil, with a comment to restore it "once multiplayer drag is
ready to ship". Supplying the extension it asks for
(`multiplayer/gamemodes/drag/drag.lua`) and un-stubbing the getter hands tree, staging
lights, timers and remote-racer UI suppression back to the game, replacing 0.0.37's
1,022-line `display.lua` fork and its 473-line drag display extension.

Un-stubbing it is harder than it sounds, and worth knowing if you attempt anything
similar. `getDragGamemode` is a **local** function, called as an upvalue from about twenty
places inside `core.lua`; `M.getDragGamemode` merely exports a copy of the reference. So
assigning the module field redirects callers *outside* the module and nothing inside it —
`poi.lua` sees your gamemode and lets players join, while every decision in `core.lua`
still reads nil and quietly runs the single-player path. Each client then registers only
its own car and races alone, which looks like a sync bug and is not one. BeamNG's Lua
sandbox also refuses `debug.setupvalue`, so the upvalue cannot be reached at runtime.

What does work: read BeamNG's own `core.lua` with `readFile`, restore the four lines they
commented out, compile it, and copy the result over the live module table. Nothing is
forked on disk, and a game update to `core.lua` is picked up automatically —
`careerMP/dragSync.lua` does this, and the same technique removes a duplicated on-screen
message in `display.lua`.

What BeamNG does *not* ship is the layer above: presence, pairing players into heats, and
deciding when everyone is staged. `careerMP/dragLobby.lua` is that layer. One player at
each strip is elected by the server as its authority for as long as they are standing
there — per strip rather than per session, so somebody off doing deliveries can never hold
up a race.

A handful of latent bugs in the carried-forward code were fixed along the way (an
unbounded queue in the paint sync, a nil field read, two vehicle-side calls to functions
that never existed, an always-true console command check on the server). These are listed
in the research doc.

## Known gaps

- **Top bar.** 0.39 deleted `ui_topBar` entirely in the UI overhaul; the replacement
  (`menuManager` / router / pause-V2) has no `removeEntry` equivalent. 0.0.37 used it to
  hide the freeroam menu entries that make no sense in MP career. The call is gated so it
  fails safe instead of erroring, but the entries are no longer hidden. **This is the main
  thing that still needs writing.**
- **Insurance fixes dropped.** 0.39 fixes the deductible handling upstream *and* changed
  its shape (`.money`/`.vouchers` are plain numbers now, not `.amount` tables), so
  carrying 0.0.37's patch forward would have broken. Its `onVehicleRepairDelayed` hook had
  no consumer anywhere in the mod. Lost with them: the convenience of being placed into
  the vehicle before an insurance repair.
- **One base-game bug is still unpatched.** `career/modules/insurance/insurance.lua:460`
  in 0.39 reads `local insuranceId = invVehs[invVehId].id` where it means `.insuranceId`.
  0.0.37 patched it; reaching it now means forking a 1,978-line file for one line, and it
  affects single player too, so it is left for BeamNG to fix.
- **Drag race syncing is on by default, and is the least-proven thing here.** It un-stubs a
  chunk of game code BeamNG themselves have not finished, and it has only been verified
  with **two** players at one strip. Set `client.nativeDragSyncEnabled = false` to turn it
  off; drag racing then behaves exactly as in single player. Worth doing if a BeamNG update
  breaks it — the client logs why on join and falls back on its own rather than failing
  hard.

  Rough edges:
  - **The result screen is BeamNG's freeroam one, not the mission one.** The full-screen
    timeslip you get from a career BMRA event is `MissionTimeSlipPanel`, part of the
    mission end flow, and a freeroam race cannot open it. You get the same `Timeslip`
    component in the `dragRace` app instead — this port moves that app to the centre of
    the screen and widens it, because the shipped 260px is sized for a corner strip and
    cuts the right lane clean off.
  - **A player who drives up but never stages is dropped after 60s**, and cannot rejoin
    until they physically move. Deliberate — an idle car otherwise blocks the strip for
    everyone — but tight if you are lining up slowly.
  - **Cross-machine timing** uses each client's own arrival anchor rather than a shared
    clock. `os.clockhp()` is process-relative, and measured offsets between two machines
    here were +33s, +135s and −60s, so a naive comparison is not slightly wrong but
    nonsense — and a negative offset red-lights the non-host on every run.
    `multiplayer/synclib.lua` exists for the proper fix and is not on the race-clock path
    yet.
  - Only tested with **two** players, at one strip, on one map.

## Building the client mod

`Resources/Client/CareerMP.zip` is what the server hands to joining players, so after
editing anything under `Resources/Client/CareerMP/` you have to rezip it, and the zip is
committed to this repo (the server plugin also fetches it from here to self-update).

Zip the **contents** of `Resources/Client/CareerMP/` — `lua/`, `ui/`, `scripts/`,
`settings/`, `levels/` must be at the root of the archive, not nested inside a
`CareerMP/` folder.

One gotcha: BeamNG's virtual filesystem wants `/` separators in zip entry names. Most
GUI zip tools (7-Zip, Explorer's "Send to > Compressed folder") get this right;
PowerShell's `Compress-Archive` does **not** — it writes `\` on Windows, and the game
then mounts the archive as one flat directory and finds no extensions at all.

## Gallery

<img width="1763" height="1115" alt="image" src="https://github.com/user-attachments/assets/bb741ab2-7710-42e6-8835-0fc028933e8d" />

<img width="1349" height="1087" alt="image" src="https://github.com/user-attachments/assets/481bd55a-cc52-4b21-b290-ce934bb7a956" />

<img width="1503" height="1148" alt="image" src="https://github.com/user-attachments/assets/a610afff-fb08-4c9f-937c-ba7bfbbe72d1" />

<img width="1215" height="647" alt="image" src="https://github.com/user-attachments/assets/769505e7-bdb1-4eed-a6b7-a5640671353b" />

<img width="1338" height="1112" alt="image" src="https://github.com/user-attachments/assets/14cab7ec-0ebb-4a37-a08d-0e7780360036" />

<img width="1626" height="1035" alt="image" src="https://github.com/user-attachments/assets/bdc5aa9f-e731-43c0-bb14-31ea6bf0647c" />

## Credits

CareerMP is by **Dudekahedron** — the design, the architecture and nearly all of the
behaviour in this fork are theirs. Screenshots above are from the original.
If you would like to know more or are interested in contributing to upstream CareerMP,
find them on their discord server: [Dudek's Sandbox](https://discord.gg/caU5adg)

This fork only updates that work for BeamNG.drive 0.39. Thanks also to Bouboule, and to
Lion and Luuk from BeamPaint, for the HTTP request examples the server plugin is built on.
