# CareerMP
Play [BeamNG.drive](https://beamng.com/game/)'s Career Mode with friends on a [BeamMP](https://beammp.com/) server.

<img width="2468" height="861" alt="image" src="https://github.com/user-attachments/assets/bd9bcb2f-530f-4fcd-a76b-732ec6ce7159" />

## Overview
CareerMP does not change the base game's career or replace it with a multiplayer career of its own. It adds what the BeamMP client and server need for the base game career to run in multiplayer, so you play your own career in the same world as other players doing theirs.

## Features
- Base-game career in multiplayer, at parity with single player
- Local saves: continue on any CareerMP server, or take an online save offline and back
- Mod vehicles the base game supports in career can appear in traffic and at dealerships
- Longer vehicle render distance, so players show on the big map
- Road traffic with police, and parked cars, as in the single-player career: each player spawns the server's amount, every player sees everyone's traffic, and missions, challenges and scenarios add their own
- Traffic signals synced for every player
- Red-light camera and speed trap announcements for cars that players drive
- Head-to-head drag racing between players on one synchronised tree, using the game's own multiplayer drag code (`client.nativeDragSyncEnabled`, on by default)
- Mission, challenge and scenario props synced, so you see what others are doing and have to drive around it
- Multiplayer chat and session apps added to mission, challenge and scenario layouts
- Vehicles shown and hidden correctly for other players
- Nametags hidden for traffic and many spawnables
- Pay other players from the player list

## Status
Built for BeamNG.drive 0.40.4.0 with the current BeamMP, where joining reaches the career. Earlier releases were tested on 0.39.2.1, where a live session confirmed joining and creating the career profile, buying a starter vehicle, part customisation, parcel deliveries, and drag racing between two players at one strip. Tuning and painting, insurance and repairs, prop and paint sync, and more than two players have not been tried yet. Known gaps and planned work are on the [issue tracker](https://github.com/norto22/CareerMP/issues).

If something misbehaves, check the game console first: `careerMP.compat` logs any game API that moved, and `careerMP.patches` logs whether its runtime patches installed.

## Requirements
- BeamNG.drive 0.40.4.0
- The current BeamMP Server, Launcher and Client
- The West Coast, USA map

Multiplayer adds load: players with mid-range systems report 5-10% lower performance than an unmodded BeamMP server, and systems below 20-30 FPS struggle to keep physics and position sync in real time.

## Installation
1. Download `CareerMP-<version>.zip` from the latest [release](https://github.com/norto22/CareerMP/releases/latest).
2. Unpack it into your BeamMP server folder, so it adds `Resources/Client/CareerMP.zip` and `Resources/Server/CareerMP/`.
3. In `ServerConfig.toml`, set `MaxCars = 100` or higher and `Map = "/levels/west_coast_usa/info.json"`. `MaxCars` counts every vehicle a player spawns, traffic included, so it must cover the road and parked traffic amounts plus the player's own cars (see [Traffic](#traffic)).
4. Start the server. CareerMP writes its config to `Resources/Server/CareerMP/config/config.json` and checks for updates.

Coming from an earlier CareerMP or from the 0.39 port? Those servers do not take updates from this repository on their own: install once by unpacking the release over the old files, which replaces the plugin and its version files.

## Updates
With `server.autoUpdate` on (the default), the server checks this repository's latest version on every start and with `CareerMP Update`. A new client mod or plugin is downloaded in place; restart the server to apply it. With `server.autoExit` on, the server shuts down after an update so a restart script can bring it back up. A failed download leaves the installed files as they were.

## Configuration
Edit `Resources/Server/CareerMP/config/config.json`, or use the server console. Type `CareerMP Help` to list the commands:

<img width="1098" height="155" alt="image" src="https://github.com/user-attachments/assets/ffe64e84-09db-4894-8338-3835dbad39ac" />

`CareerMP SetConfig <section> <key> <value>` changes one setting, saves the file and sends the `client` section to every connected player; traffic amounts take effect at a player's next career start. On every start the server adds any setting missing from the file with its default and removes settings it does not know. It never changes a value you set, so an update does not switch traffic on or off on an existing server.

### Traffic
Every player spawns their own road and parked traffic, and every other player sees and can hit those same cars. Players therefore see the sum of everyone's traffic: with the defaults, two players share 12 road cars and 16 parked cars. Raise the amounts carefully on busy servers; three or more players have not been tried yet.

Each amount is a whole number from 0 to 50. A value outside that range, or not a number, is held to 0 or 50 and the game console logs a warning. When road traffic has at least 3 cars, about a quarter of them are police, with the pursuits and fines of the single-player career. A new server starts with road traffic on at 6 and parked traffic on at 8. On joining, the game console logs `careerMP.traffic: applying server traffic` with the amounts used and `careerMP.traffic: traffic ready` with the cars the game spawned.

Every traffic car counts against BeamMP's `MaxCars`, so set it to at least `roadTrafficAmount + parkedTrafficAmount` plus the player's own cars; 100 leaves plenty of room with the defaults.

The `extraTrafficAmount` and `extraTrafficEnabled` settings of earlier versions were never used by the game. The server removes them from the file on its next start and logs that it did; `SetConfig` no longer accepts them.

### `client` settings
Sent to every player when they join.

| Setting | Default | What it does for players |
|---|---|---|
| `roadTrafficEnabled` | `true` | Road traffic, police included, on or off. Off spawns none. |
| `roadTrafficAmount` | `6` | Road cars each player spawns, 0 to 50. |
| `parkedTrafficEnabled` | `true` | Parked cars in car parks and at the roadside on or off. Off spawns none. |
| `parkedTrafficAmount` | `8` | Parked cars each player spawns, 0 to 50. |
| `trafficSimpleVehicles` | `true` | Traffic uses the game's simple, lighter car models. |
| `trafficAllowMods` | `false` | Mod vehicles may appear in traffic. |
| `trafficSmartSelections` | `true` | The game picks traffic models that suit the map, as in single player. |
| `simplifyRemoteVehicles` | `false` | Other players' cars are shown with simplified models (BeamMP setting). |
| `skipOtherPlayersVehicles` | `false` | Switching vehicles skips other players' cars (BeamMP setting). |
| `spawnVehicleIgnitionLevel` | `0` | Ignition state a newly spawned vehicle starts in; 0 is off (BeamMP setting). |
| `remoteVehicleGhost` | `false` | Other players' cars are ghosted, so you drive through them. |
| `remoteUnicycleGhost` | `true` | Other players on foot are ghosted. |
| `localUnicycleGhost` | `false` | You are ghosted while on foot. |
| `serverSaveNameEnabled` | `false` | Use `serverSaveName` as every player's save name instead of their BeamMP username. |
| `serverSaveName` | `""` | The save name used when `serverSaveNameEnabled` is on. |
| `serverSaveSuffix` | `""` | Text added to every player's save name, to keep this server's saves apart. |
| `consoleEnabled` | `false` | Players may open the game console. |
| `worldEditorEnabled` | `false` | Players may open the world editor. |
| `nativeDragSyncEnabled` | `true` | Head-to-head drag racing on one synchronised tree. Set `false` to make drag racing behave as in single player, for example if a BeamNG update breaks it; the client also falls back on its own and logs why. |

The player's own game settings changed by the `traffic*`, `simplifyRemoteVehicles`, `skipOtherPlayersVehicles` and `spawnVehicleIgnitionLevel` rows are put back when they leave the server.

### `server` settings
Used by the server only.

| Setting | Default | What it does |
|---|---|---|
| `autoUpdate` | `true` | Check this repository for a new version on every start and with `CareerMP Update` (see [Updates](#updates)). |
| `autoExit` | `true` | Shut the server down after an update, so a restart script brings it back with the new files. |
| `allowTransactions` | `true` | Players may pay each other from the player list. |
| `shortWindowMax` | `1000` | Most money a player may send within `shortWindowSeconds`. |
| `shortWindowSeconds` | `30` | Length of the short sending window, in seconds. |
| `longWindowMax` | `10000` | Most money a player may send within `longWindowSeconds`. |
| `longWindowSeconds` | `300` | Length of the long sending window, in seconds. |
| `sessionSendingMax` | `100000` | Most money a player may send in one server session. |
| `sessionReceiveMax` | `200000` | Most money a player may receive in one server session. |

## Notes
CareerMP uses the base game's career, so it runs on West Coast, USA only.

It provides no moderation and should work with the moderation plugin of your choice, as long as every player can spawn at least 100 vehicles.

Your save is named after your BeamMP username (or the server's configured save name), and you always start in that save when you join. You can continue it offline or on any other CareerMP server. To use a single-player save online, give it a name that matches your BeamMP username before joining. You can also load any save from the ESC menu.

Since 0.39, BeamNG lowercases profile names and strips everything that is not a letter or digit, so `Player_One` becomes `playerone`. Usernames that differ only in case or punctuation therefore share a profile (`Player_1` and `player1` both become `player1`). CareerMP turns the username into the profile name itself, so the same username maps to the same profile on every machine.

Using the same save on modded and unmodded servers will likely cause compatibility issues.

The vehicle marketplace is local to each save; trading vehicles between players is planned.

## Building
`Resources/Client/CareerMP.zip` is what joining players download, and servers fetch it from this repository when they update. After changing anything under `Resources/Client/CareerMP/`, rebuild it:

```
python3 tools/build.py
```

The script needs only Python 3 and gives the same archive every time. `lua tests/run.lua` runs the tests, which load the real sources against stand-ins for the game and the BeamMP server. `python3 tools/build.py --package` also writes the server release package to `dist/`.

## Releasing
Every pull request into `main` is a release. Title it with the new version (`v0.2.0`) and set the same version in `Resources/Server/CareerMP/versions/client.json` and `server.json`. A check confirms the title, the versions and the rebuilt archive, and attaches the package to the run so you can test it. Merging publishes the release, with the pull request's description as its notes.

## Gallery

<img width="1763" height="1115" alt="image" src="https://github.com/user-attachments/assets/bb741ab2-7710-42e6-8835-0fc028933e8d" />

<img width="1349" height="1087" alt="image" src="https://github.com/user-attachments/assets/481bd55a-cc52-4b21-b290-ce934bb7a956" />

<img width="1503" height="1148" alt="image" src="https://github.com/user-attachments/assets/a610afff-fb08-4c9f-937c-ba7bfbbe72d1" />

<img width="1215" height="647" alt="image" src="https://github.com/user-attachments/assets/769505e7-bdb1-4eed-a6b7-a5640671353b" />

<img width="1338" height="1112" alt="image" src="https://github.com/user-attachments/assets/14cab7ec-0ebb-4a37-a08d-0e7780360036" />

<img width="1626" height="1035" alt="image" src="https://github.com/user-attachments/assets/bdc5aa9f-e731-43c0-bb14-31ea6bf0647c" />

## Credits
CareerMP was created by **Dudekahedron** ([StanleyDudek/CareerMP](https://github.com/StanleyDudek/CareerMP)); its design and most of its behaviour are theirs, and the screenshots above are from the original. Find them on [Dudek's Sandbox](https://discord.gg/caU5adg).

The port to BeamNG.drive 0.39, including multiplayer drag racing, is by Vlad Maksimenko ([vladmaksimenko-0/CareerMP-0.39](https://github.com/vladmaksimenko-0/CareerMP-0.39)).

Thanks to Bouboule, and to Lion and Luuk from BeamPaint, for the HTTP request examples the server plugin is built on.
