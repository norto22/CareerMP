-- A stand-in for the game's own garage computer module (career/modules/computer.lua), which
-- CareerMP no longer ships a copy of. It keeps the parts CareerMP's patches depend on: the
-- menu range is 1 m from the computer's door, or 4 m around it when there is no door; the
-- garage's cars are listed and each gets its buttons from onComputerAddFunctions; and a
-- button runs its callback through computerButtonCallback, called from the UI by name.

local M = {}

local computerTetherRangeSphere = 4
local computerTetherRangeBox = 1
local tether

local computerFunctions
local computerId

local function openMenu(computerFacility, resetActiveVehicleIndex)
	computerFunctions = {general = {}, vehicleSpecific = {}}
	computerId = computerFacility.id
	local menuData = {vehiclesInGarage = {}, resetActiveVehicleIndex = resetActiveVehicleIndex}
	for _, inventoryId in ipairs(career_modules_inventory.getInventoryIdsInClosestGarage()) do
		table.insert(menuData.vehiclesInGarage, {inventoryId = inventoryId})
		computerFunctions.vehicleSpecific[inventoryId] = {}
	end
	menuData.computerFacility = computerFacility
	extensions.hook("onComputerAddFunctions", menuData, computerFunctions)

	local door = computerFacility.doors and computerFacility.doors[1]
	tether = nil
	if door then
		tether = career_modules_tether.startDoorTether(door, computerTetherRangeBox, M.closeMenu)
	end
	if not tether then
		tether = career_modules_tether.startSphereTether(computerFacility.pos, computerTetherRangeSphere, M.closeMenu)
	end

	extensions.ui_router.navigate("career.computer")
	extensions.hook("onComputerMenuOpened")
end

local function computerButtonCallback(buttonId, inventoryId)
	local functionData
	if inventoryId then
		functionData = computerFunctions.vehicleSpecific[inventoryId][buttonId]
	else
		functionData = computerFunctions.general[buttonId]
	end
	functionData.callback(computerId)
end

M.openMenu = openMenu
M.computerButtonCallback = computerButtonCallback
M.closeMenu = function() end

return M
