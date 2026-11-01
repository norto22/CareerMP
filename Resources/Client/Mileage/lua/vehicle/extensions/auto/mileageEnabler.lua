
local M = {}

local function onVehicleReady()
	obj:queueGameEngineLua("mileageEnabler.onVehicleReady(" .. obj:getID() .. ") ")
	obj:queueGameEngineLua("mileagePerPartPaint.onVehicleReady(" .. obj:getID() .. ") ")
end

local function setGhost(enabled)
	obj:setGhostEnabled(enabled)
end

local function onConditionCheck()
	if partCondition and partCondition.getConditions() then
		obj:queueGameEngineLua("mileagePerPartPaint.onConditionCheckCallback(" .. obj:getID() .. ") ")
	end
end

M.onConditionCheck = onConditionCheck

M.setGhost = setGhost

M.onVehicleReady = onVehicleReady

return M
