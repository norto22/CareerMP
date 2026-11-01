--CareerMP :: mod entry point
--
-- Load order matters:
--   1. compat        - everything else reads renamed 0.39 game APIs through it
--   2. patches       - installs the runtime wrappers that publish the enriched
--                      *MP hooks the feature extensions listen for
--   3. careerPatches - neutralises career activation's vehicle cleanup before
--                      any career can start
--   4. traffic       - hands the server's traffic amounts to the game's career
--                      traffic setup
--   5. insuranceRestore - loads the game's insurance records when a join's career
--                      start leaves them empty
--   6. features
--
-- 'manual' unload mode keeps these alive across level switches, which career
-- does constantly.

local function loadPersistent(path)
	load(path)
	setExtensionUnloadMode(path, 'manual')
end

-- Foundation
loadPersistent('careerMP/compat')
loadPersistent('careerMP/patches')
loadPersistent('careerMP/careerPatches')
loadPersistent('careerMP/traffic')
loadPersistent('careerMP/insuranceRestore')

-- Core
loadPersistent('careerMPEnabler')

-- Features
loadPersistent('careerMPUIApps')
loadPersistent('careerMPPlayerPayments')
loadPersistent('careerMPPrefabSync')
loadPersistent('careerMPPerPartPaint')

-- Drag racing: drives BeamNG 0.39's own multiplayer drag implementation.
--
-- Order matters here. sessionManager and the gamemode both reach into the transport,
-- and the transport is what loads gameplay_drag_mpDragHandlers -- which the base game
-- never loads by itself.
loadPersistent('careerMP/dragTransport')
loadPersistent('multiplayer/sessionManager')
loadPersistent('multiplayer/synclib')
loadPersistent('careerMP/dragLobby')
loadPersistent('multiplayer/gamemodes/drag/drag')
loadPersistent('careerMP/dragSync')
