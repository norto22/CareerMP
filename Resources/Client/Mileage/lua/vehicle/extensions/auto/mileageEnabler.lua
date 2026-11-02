
local M = {}

local function onVehicleReady()
	obj:queueGameEngineLua("mileageEnabler.onVehicleReady(" .. obj:getID() .. ") ")
	obj:queueGameEngineLua("mileagePerPartPaint.onVehicleReady(" .. obj:getID() .. ") ")
end

local function setGhost(enabled)
	obj:setGhostEnabled(enabled)
end

M.setGhost = setGhost

M.onVehicleReady = onVehicleReady

return M
