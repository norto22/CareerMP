<p align="center">
  <img src=".github/poster.jpg" width="420" alt="Mileage: Co-op career. Cruise together. Race your friends.">
</p>

# Mileage
**Co-op career. Cruise together. Race your friends.**

Mileage is a multiplayer career for [BeamNG.drive](https://beamng.com/game/) on a [BeamMP](https://beammp.com/) server. You and your friends share one world: the same roads and traffic, the same signals, and the same props from each other's missions. You can race each other on the drag strip or across the map for money, pay and ask each other for money, climb the server leaderboard and join race events the server owner runs. Mileage is built on the game's own career, with your progress kept in your own save, and it is growing into a career you play together: co-op jobs with shared pay, races against your friends and, later, crews.

Until v0.3.0 Mileage was called CareerMP. Servers running CareerMP move over to Mileage on their own (see [Coming from CareerMP](#coming-from-careermp)).

## What's in

### Working
Confirmed in live sessions:
- Joining a server reaches the career on BeamNG.drive 0.40.4.0
- Creating the career profile, buying a starter vehicle, customising parts and parcel deliveries (confirmed on 0.39.2.1)
- Head-to-head drag racing between two players on one synchronised tree, using the game's own multiplayer drag code (confirmed on 0.39.2.1)

### In, waiting for a live test
These are built and covered by tests, but have not been played through on a server yet:
- Tuning, painting, insurance and repairs with other players on the server ([#28](https://github.com/norto22/Mileage/issues/28), [#29](https://github.com/norto22/Mileage/issues/29))
- Damage sharing: dents on your car show on every other player's copy of it ([#98](https://github.com/norto22/Mileage/issues/98))
- Paint sync, part by part ([#31](https://github.com/norto22/Mileage/issues/31))
- Mission, challenge and scenario props synced, so you see what others are doing and have to drive around it ([#30](https://github.com/norto22/Mileage/issues/30))
- Road traffic with police, and parked cars, as in the single-player career. Each player spawns a share of the server's traffic total, and every player sees everyone's traffic. While you run a parking challenge, other players' traffic and parked cars are hidden on your game only, so the spaces are clear ([#99](https://github.com/norto22/Mileage/issues/99))
- Traffic signals synced for every player, and red-light camera and speed trap announcements for cars that players drive ([#34](https://github.com/norto22/Mileage/issues/34))
- Paying any amount you type and asking other players for money, from the player list. Every payment is taken from the payer's career before it is given to the other, each confirmed by a finished save, and kept on the server until both sides have it, so a dropped connection or a server restart never loses or copies money ([#33](https://github.com/norto22/Mileage/issues/33))
- Street races for money: right-click a player, pick Race and a stake, and the end of your big-map route is the finish. They are moved beside you, you both count down, and the first to the finish takes both stakes, plus a server prize if the owner switches it on ([#105](https://github.com/norto22/Mileage/issues/105))
- Race events the server owner schedules on a named West Coast route or to a random finish, announced ahead and paid to the winner ([#106](https://github.com/norto22/Mileage/issues/106))
- A server leaderboard of race wins and each player's best drag times, kept across restarts ([#107](https://github.com/norto22/Mileage/issues/107))
- Other players' vehicles shown and hidden correctly, and nametags hidden for traffic and many spawnables ([#35](https://github.com/norto22/Mileage/issues/35), [#69](https://github.com/norto22/Mileage/issues/69))
- Three or more players at once ([#32](https://github.com/norto22/Mileage/issues/32))
- Multiplayer chat and session apps in mission, challenge and scenario layouts ([#100](https://github.com/norto22/Mileage/issues/100))
- Local saves: continue on any Mileage server, or take an online save offline and back ([#100](https://github.com/norto22/Mileage/issues/100))
- Mod vehicles the base game supports in career, in traffic and at dealerships ([#100](https://github.com/norto22/Mileage/issues/100))
- Longer vehicle render distance, so players show on the big map ([#100](https://github.com/norto22/Mileage/issues/100))

Known problems are on the [issue tracker](https://github.com/norto22/Mileage/issues?q=is%3Aissue%20state%3Aopen%20label%3Abug). If something misbehaves, check the game console first: `mileage.compat` logs any game API that moved, and `mileage.patches` logs whether its runtime patches installed.

### Planned
Co-op:
- Co-op jobs: do a delivery together and split the pay ([#89](https://github.com/norto22/Mileage/issues/89))
- Pay another player to tow or repair your car ([#91](https://github.com/norto22/Mileage/issues/91))
- Loans between players, paid back over time ([#88](https://github.com/norto22/Mileage/issues/88))
- Trading and selling vehicles between players ([#39](https://github.com/norto22/Mileage/issues/39))

Racing your friends:
- Career race events you join together ([#36](https://github.com/norto22/Mileage/issues/36))
- AI opponents in races shared by players ([#38](https://github.com/norto22/Mileage/issues/38))
- Drag racing with more players per strip, and several strips at once ([#37](https://github.com/norto22/Mileage/issues/37))
- Watching a race other players are in ([#93](https://github.com/norto22/Mileage/issues/93))
- Bounties: put a price on a player, paid to whoever beats them ([#92](https://github.com/norto22/Mileage/issues/92))

Crews:
- Crews with a shared crew bank account ([#90](https://github.com/norto22/Mileage/issues/90))

The world:
- Maps other than West Coast, USA ([#40](https://github.com/norto22/Mileage/issues/40))

## Requirements
- BeamNG.drive 0.40.4.0
- The current BeamMP Server, Launcher and Client
- The West Coast, USA map

Multiplayer adds load: players with mid-range systems report 5-10% lower performance than an unmodded BeamMP server, and systems below 20-30 FPS struggle to keep physics and position sync in real time.

## Installation
1. Download `Mileage-<version>.zip` from the latest [release](https://github.com/norto22/Mileage/releases/latest).
2. Unpack it into your BeamMP server folder, so it adds `Resources/Client/Mileage.zip` and `Resources/Server/Mileage/`.
3. In `ServerConfig.toml`, set `MaxCars = 100` or higher and `Map = "/levels/west_coast_usa/info.json"`. `MaxCars` counts every vehicle a player spawns, traffic included, so it must cover the road and parked traffic amounts plus the player's own cars (see [Traffic](#traffic)).
4. Start the server. Mileage writes its config to `Resources/Server/Mileage/config/config.json` and checks for updates.

## Coming from CareerMP
A server on CareerMP 0.1.0 or 0.2.0 with `server.autoUpdate` on moves to Mileage by itself, over a few restarts:

1. CareerMP's update check installs the last CareerMP plugin and restarts.
2. The last CareerMP plugin downloads Mileage, then restarts again. It fetches the client mod first and keeps it in `Resources/Server/Mileage/` until the move is done, so players are never offered both mods. Then it fetches the plugin.
3. On its first start Mileage copies the settings from `Resources/Server/CareerMP/config/config.json` and checks the copy. Only once the settings and `Mileage.zip` are in place does it remove `Resources/Client/CareerMP.zip` and the CareerMP plugin. Then it restarts once more.

Nothing of CareerMP is removed until Mileage is ready, and until then CareerMP keeps serving players. If a download, the settings copy or a removal fails, the console says which step failed and why. The server keeps running CareerMP and tries again on its next start. Each step logs what it did in the server console. Each restart needs `server.autoExit` on and a restart script; with `autoExit` off, restart the server yourself when the console asks. The old settings stay in `Resources/Server/CareerMP/config/`; delete that folder once you no longer need it.

A server still on CareerMP 0.1.0 logs one failed download of `CareerMP.zip` on its way, because the old client mod it asks for is no longer in this repository. The move carries on and succeeds ([#101](https://github.com/norto22/Mileage/issues/101)).

To move by hand, for example with `autoUpdate` off, unpack the Mileage release into the server folder and start the server: Mileage copies the CareerMP settings and removes the old files in the same way. Player saves are not affected. The `CareerMP` console commands still work as another name for `Mileage`.

Coming from the 0.39 port or the original CareerMP? Those servers do not take updates from this repository: install Mileage by hand as above.

## Updates
With `server.autoUpdate` on (the default), the server checks this repository's latest version on every start and with `Mileage Update`. A new client mod or plugin is downloaded in place; restart the server to apply it. With `server.autoExit` on, the server shuts down after an update so a restart script can bring it back up. A failed download leaves the installed files as they were.

## Configuration
Edit `Resources/Server/Mileage/config/config.json`, or use the server console. Type `Mileage Help` to list the commands:

```
Mileage GetConfig <section> <key>            - Displays Config, or section, or key
Mileage SetConfig <section*> <key*> <value*> - Sets Config section key to value, * = REQUIRED
Mileage Update                               - Checks for Mileage update
Mileage Stats [reset]                        - Shows what each part of Mileage sends, reset starts it again
Mileage Transfers                            - Lists money still waiting on a player, and races holding stakes
Mileage Leaderboard [reset]                  - Shows the leaderboard, reset clears it
Mileage Event <minutes> <prize> <route|random> | cancel | list - Schedules, cancels or lists race events
Mileage Help                                 - Displays Commands Usage
```

`Mileage SetConfig <section> <key> <value>` changes one setting, saves the file and sends the `client` section to every connected player. A changed traffic amount, switch or total changes each player's share within a few seconds; a share that grows only brings back cars that player's game spawned at its career start, and the rest arrive at their next career start. On every start the server adds any setting missing from the file with its default and removes settings it does not know. It never changes a value you set, so an update does not switch traffic on or off on an existing server.

### Traffic
Every player spawns their own road and parked traffic, and every other player sees and can hit those same cars. Players therefore see the sum of everyone's traffic, and every traffic car is a multiplayer car the server passes on to everyone, so traffic is most of what a busy server carries.

The server therefore keeps the traffic of all players near one total, `server.roadTrafficTotal` driving and `server.parkedTrafficTotal` parked cars (18 and 24 on a new server, and added at those values to an existing server's config). Each player spawns `client.roadTrafficAmount` and `parkedTrafficAmount` until the players together would pass the total; from then on the total is split evenly between them, one spare car each to the lowest player ids. With the defaults one to three players see 6 driving and 8 parked cars each; four players get 5, 5, 4 and 4 driving and 6 parked each; eight get 2 or 3 driving and 3 parked each. When someone joins, the others' shares shrink at once and some of their traffic cars quietly disappear; when someone leaves, the shares grow again after 3 seconds, up to the cars each game spawned at its career start. A total of 0 means no limit. The game console logs `mileage: traffic share from the server` and `mileage.traffic: traffic share changed` when a share changes.

Each amount is a whole number from 0 to 50, and each total from 0 to 400. A value outside that range is held to the nearest end, and one that is not a number counts as 0. When road traffic has at least 3 cars, about a quarter of them are police, with the pursuits and fines of the single-player career. On joining, the game console logs `mileage.traffic: applying server traffic` with the amounts used and `mileage.traffic: traffic ready` with the cars the game spawned.

To save more, Mileage's game files send the position of a parked car standing still once a second instead of up to 50 times, and of driving traffic more than 500 m from every other player's car twice a second. Hidden cars send none. The car a player drives, the player's other cars, traffic near other players and a parked car that moves are sent as often as BeamMP sends them. The game console logs `mileage.positionRate: position check active` once the check is in place, or that `positionGE.sendVehiclePosRot` is missing, in which case BeamMP sends every position as before.

Every traffic car counts against BeamMP's `MaxCars`, so set it to at least `roadTrafficAmount + parkedTrafficAmount` plus the player's own cars; 100 leaves plenty of room with the defaults.

### What the server sends
`Mileage Stats` in the server console shows where the server's effort goes. For each part of Mileage (`damage`, `carStates`, `trafficMarks`, `trafficShare`, `paint`, `prefabs`, `drag`, `payments`, `transfers`, `offers`, `races`, `leaderboard`, `events`, `alive`, `trafficLights`, `notifications`, `config`) it lists the messages received, the messages sent, how many players they reached and the bytes sent, for the last 60 seconds and since the server started. Below that it lists the players, the cars on the server with how many are traffic or parked and how many of each are shown, the traffic totals and each player's share. A player who was on before the server filled keeps the traffic above their new share, hidden, so the shown traffic is what to compare with the totals. `Mileage Stats reset` starts the since-start counts again, for example before and after a change. The positions of cars are BeamMP's own and are not counted; the number of cars stands in for them.

### Money, races and events
Money stays in each player's own save. Every movement of money between players (a payment, a race stake, a payout, a prize) is a transfer the server keeps in `Resources/Server/Mileage/data/transfers.json` until both games have confirmed it: the payer's game takes the amount and saves, then the receiver's game gives it and saves. A player who is away gets what they are owed when they next join, however long that takes. `Mileage Transfers` lists every transfer still waiting, with its age and amount, and every race still holding stakes. The console logs a transfer that waits more than a minute and every payment a player could not cover.

A street race takes both stakes before the start and keeps them in `data/races.json` until they are paid out. Leaving or giving up before the countdown returns both stakes; after it, the racer who left loses their stake to the other. Nobody reaching the finish within `raceTimeLimitMinutes` returns both. If the server stops mid-race, both stakes go back on its next start. The server prize is new money, paid only to a winner who reached the finish, and at most once per pair of players within `racePrizeCooldownMinutes`.

`Mileage Event <minutes> <prize> <route|random>` schedules one race event, 1 to 120 minutes ahead with a prize of $0 to $1,000,000. `Mileage Event list` prints the eight shipped routes; name one by its number or its id, such as `Mileage Event 15 25000 service-dragway`. `random` starts at a random route's start and finishes at a road point 1.5 to 4 km away. Players are told 10, 5 and 1 minutes ahead and join from the Mileage prompts app. At the start everyone who joined is lined up behind the start, and the fastest to the finish gets the prize. `Mileage Event cancel` ends it. The schedule is kept in `data/events.json` until the event starts.

The leaderboard in `data/leaderboard.json` counts race wins, from street races and events, and keeps each player's best drag time per strip, reported by their own game. `Mileage Leaderboard` prints it and `Mileage Leaderboard reset` clears it. The `data/` folder holds everything Mileage keeps about players, by their BeamMP name; keep it when you update or move the server.

The `extraTrafficAmount` and `extraTrafficEnabled` settings of earlier versions were never used by the game. The server removes them from the file on its next start and logs that it did; `SetConfig` no longer accepts them.

### `client` settings
Sent to every player when they join.

| Setting | Default | What it does for players |
|---|---|---|
| `roadTrafficEnabled` | `true` | Road traffic, police included, on or off. Off spawns none. |
| `roadTrafficAmount` | `6` | Road cars each player spawns, 0 to 50, until the players together reach `server.roadTrafficTotal`. |
| `parkedTrafficEnabled` | `true` | Parked cars in car parks and at the roadside on or off. Off spawns none. |
| `parkedTrafficAmount` | `8` | Parked cars each player spawns, 0 to 50, until the players together reach `server.parkedTrafficTotal`. |
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
| `autoUpdate` | `true` | Check this repository for a new version on every start and with `Mileage Update` (see [Updates](#updates)). |
| `autoExit` | `true` | Shut the server down after an update, so a restart script brings it back with the new files. |
| `allowTransactions` | `true` | Players may pay each other from the player list. |
| `shortWindowMax` | `1000` | Most money a player may send within `shortWindowSeconds`. |
| `shortWindowSeconds` | `30` | Length of the short sending window, in seconds. |
| `longWindowMax` | `10000` | Most money a player may send within `longWindowSeconds`. |
| `longWindowSeconds` | `300` | Length of the long sending window, in seconds. |
| `sessionSendingMax` | `100000` | Most money a player may send in one server session. |
| `sessionReceiveMax` | `200000` | Most money a player may receive in one server session. |
| `roadTrafficTotal` | `18` | Road cars across the whole server, 0 to 400, split between players once they would pass it; 0 means no limit (see [Traffic](#traffic)). |
| `parkedTrafficTotal` | `24` | Parked cars across the whole server, 0 to 400, split the same way; 0 means no limit. |
| `allowRacing` | `true` | Players may challenge each other to street races from the player list. |
| `allowMoneyRequests` | `true` | Players may ask each other for money. A request counts against the payer's sending limits above. |
| `allowEvents` | `true` | The owner may schedule race events with `Mileage Event`. Switching it off cancels a scheduled event. |
| `raceStakeMax` | `10000` | Largest stake a race challenge may carry, 0 to 1000000; 0 means races carry no stake. |
| `racePrize` | `0` | Money the server adds for the winner of a street race, 0 to 1000000; 0 is off. |
| `racePrizeCooldownMinutes` | `10` | The same two players earn the server prize at most once in this many minutes, 0 to 1440. |
| `raceMinDistance` | `500` | Shortest street race allowed, in metres from start to finish, 0 to 20000. |
| `raceTimeLimitMinutes` | `15` | A race nobody finishes in this time ends with no winner and the stakes back, 1 to 120. |

A racing or event setting outside its range is read as the nearest value in range.

## Notes
Mileage uses the base game's career, so it runs on West Coast, USA only for now.

It provides no moderation and should work with the moderation plugin of your choice, as long as every player can spawn at least 100 vehicles.

Your save is named after your BeamMP username (or the server's configured save name), and you always start in that save when you join. You can continue it offline or on any other Mileage server. To use a single-player save online, give it a name that matches your BeamMP username before joining. You can also load any save from the ESC menu.

Since 0.39, BeamNG lowercases profile names and strips everything that is not a letter or digit, so `Player_One` becomes `playerone`. Usernames that differ only in case or punctuation therefore share a profile (`Player_1` and `player1` both become `player1`). Mileage turns the username into the profile name itself, so the same username maps to the same profile on every machine.

Using the same save on modded and unmodded servers will likely cause compatibility issues.

The vehicle marketplace is local to each save; trading vehicles between players is planned.

## Building
`Resources/Client/Mileage.zip` is what joining players download, and servers fetch it from this repository when they update. After changing anything under `Resources/Client/Mileage/`, rebuild it:

```
python3 tools/build.py
```

The script needs only Python 3 and gives the same archive every time. `lua tests/run.lua` runs the tests, which load the real sources against stand-ins for the game and the BeamMP server; `node tests/player_list_test.js` runs the player list app's tests the same way. `python3 tools/build.py --package` also writes the server release package to `dist/`.

`Resources/Server/CareerMP/` holds the last CareerMP plugin, which CareerMP servers update to so they can move to Mileage (see [Coming from CareerMP](#coming-from-careermp)). It is not part of the release package.

## Releasing
Every pull request into `main` is a release. Title it with the new version (`v0.3.0`) and set the same version in `Resources/Server/Mileage/versions/client.json` and `server.json`. A check confirms the title, the versions and the rebuilt archive, and attaches the package to the run so you can test it. Merging publishes the release, with the pull request's description as its notes.

## Gallery
Screenshots from the original CareerMP.

<img width="1763" height="1115" alt="image" src="https://github.com/user-attachments/assets/bb741ab2-7710-42e6-8835-0fc028933e8d" />

<img width="1349" height="1087" alt="image" src="https://github.com/user-attachments/assets/481bd55a-cc52-4b21-b290-ce934bb7a956" />

<img width="1503" height="1148" alt="image" src="https://github.com/user-attachments/assets/a610afff-fb08-4c9f-937c-ba7bfbbe72d1" />

<img width="1215" height="647" alt="image" src="https://github.com/user-attachments/assets/769505e7-bdb1-4eed-a6b7-a5640671353b" />

<img width="1338" height="1112" alt="image" src="https://github.com/user-attachments/assets/14cab7ec-0ebb-4a37-a08d-0e7780360036" />

<img width="1626" height="1035" alt="image" src="https://github.com/user-attachments/assets/bdc5aa9f-e731-43c0-bb14-31ea6bf0647c" />

## Credits
Mileage began as CareerMP, created by **Dudekahedron** ([StanleyDudek/CareerMP](https://github.com/StanleyDudek/CareerMP)); much of its design and behaviour are theirs, and the screenshots above are from the original. Find them on [Dudek's Sandbox](https://discord.gg/caU5adg).

The port to BeamNG.drive 0.39, including multiplayer drag racing, is by Vlad Maksimenko ([vladmaksimenko-0/CareerMP-0.39](https://github.com/vladmaksimenko-0/CareerMP-0.39)).

Thanks to Bouboule, and to Lion and Luuk from BeamPaint, for the HTTP request examples the server plugin is built on.
