function widget:GetInfo()
	return {
		name	= "Blob Guard",
		desc	= "guards multiple units",
		author  = "zoggop",
		date 	= "March 2014",
		license	= "whatever",
		layer 	= 0,
		enabled	= true,
		handler = true,
	}
end



-- LOCAL DEFINITIONS

local sqrt = math.sqrt
local random = math.random
local pi = math.pi
local halfPi = pi / 2
local twicePi = pi * 2
local cos = math.cos
local sin = math.sin
local atan2 = math.atan2
local abs = math.abs
local max = math.max
local min = math.min
local ceil = math.ceil

local drawIndicators = true
local mapBuffer = 32
local CMD_AREA_GUARD = 10125

local myTeam
local myAllies
local defInfos = {}
local blobs = {}
local targets = {}
local guards = {}
local widgetCommands = {}
local guardTargetQueue = {}
local lastCalcFrame = 0

local sizeX = Game.mapSizeX
local sizeZ = Game.mapSizeZ
local bufferedSizeX = sizeX - mapBuffer
local bufferedSizeZ = sizeZ - mapBuffer

-- commands that cause guarding to stop
local interruptCmd = {
	[0] = true,
	[10] = true,
	[15] = true,
	[16] = true,
	[20] = true,
	[21] = true,
	[25] = true,
	[40] = true,
	[90] = true,
	[125] = true,
	[130] = true,
	[140] = true,
	[CMD_AREA_GUARD] = true,
}



--- LOCAL FUNCTIONS

local function ConstrainToMap(x, z)
	x = max(min(x, bufferedSizeX), mapBuffer)
	z = max(min(z, bufferedSizeZ), mapBuffer)
	return x, z
end

local function RandomAway(x, z, dist, angle)
	if angle == nil then angle = random() * twicePi end
	local nx = x + dist * cos(angle)
	local nz = z - dist * sin(angle)
	return ConstrainToMap(nx, nz)
end

local function Distance(x1, z1, x2, z2)
	local xd = x1 - x2
	local zd = z1 - z2
	return sqrt(xd*xd + zd*zd)
end

local function ApplyVector(x, z, vx, vz, frames)
	if frames == nil then frames = 30 end
	return ConstrainToMap(x + (vx *frames), z + (vz * frames))
end

local function ManhattanDistance(x1, z1, x2, z2)
	local xd = abs(x1 - x2)
	local yd = abs(z1 - z2)
	return xd + yd
end

local function Pythagorean(a, b)
	return sqrt((a^2) + (b^2))
end

local function AngleAtoB(x1, z1, x2, z2)
	local dx = x2 - x1
	local dz = z2 - z1
	return atan2(-dz, dx)
end

local function AngleDist(angle1, angle2)
	return abs((angle1 + pi -  angle2) % twicePi - pi)
end

local function CopyTable(original)
	local copy = {}
	for k, v in pairs(original) do
		copy[k] = v
	end
	return copy
end

local function GetPrimaryWeaponRange(uDef)
	local weapon
	local highestDPS = 0
	local weapons = uDef["weapons"]
	local death = uDef.deathExplosion
	for i=1, #weapons do
		local weaponDefID = weapons[i]["weaponDef"]
		local weaponDef = WeaponDefs[weaponDefID]
		local damages = weaponDef["damages"]
		local damage = 0
		local reload = weaponDef["reload"]
		for i, d in pairs(damages) do
			if d > damage then damage = d end
		end
		local dps = damage / reload
		if weaponDef["name"] ~= death and dps > highestDPS then
			weapon = weaponDef
			highestDPS = dps
		end
	end
	if weapon then
		--[[
		local range = weapon["range"]
		local reload = weapon["reload"]
		local velocity = weapon["projectilespeed"] or 0
		local hightrajectory = weapon["highTrajectory"]
		local air = not weapon["canAttackGround"]
		return range, reload, highestDPS, velocity, hightrajectory, air
		]]--
		return weapon["range"]
	else
		return 0, 0, 0, 0
	end
end

local function GetDefInfo(uDefID)
	local info = defInfos[uDefID]
	if info ~= nil then return info end
	local uDef = UnitDefs[uDefID]
	local xs = uDef.xsize * 8
	local zs = uDef.zsize * 8
	local size = ceil(Pythagorean(xs, zs))
	local range = GetPrimaryWeaponRange(uDef)
	info = { speed = uDef.speed, size = size, range = range, canMove = uDef.canMove, canAttack = uDef.canAttack, canAssist = uDef.canAssist, canRepair = uDef.canRepair, canFly = uDef.canFly, isCombatant = uDef.canMove and uDef.canAttack and not uDef.canFly and not uDef.canAssist and not uDef.canRepair }
	defInfos[uDefID] = info
	return info
end

local function CommandString(cmdID, cmdParams, unitID)
	local commandString = cmdID .. " "
	local number = #cmdParams
	for i = 1, number do 
		commandString = commandString .. cmdParams[i]
		if i ~= number then commandString = commandString .. " " end
	end
	if unitID ~= nil then
		commandString = commandString .. " " .. unitID
	end
	return commandString
end

local function GiveCommand(unitID, cmdID, cmdParams)
	local commands = Spring.GetUnitCommands(unitID)
	if #commands > 0 then
		local first = commands[1]
		if widgetCommands[CommandString(first.id, first.params, unitID)] then
			Spring.GiveOrderToUnit(unitID, CMD.REMOVE, {first.tag}, {})
		end
	end
	local insertParams = {0, cmdID, CMD.OPT_RIGHT }
	for i = 1, #cmdParams do table.insert(insertParams, cmdParams[i]) end
	local command = Spring.GiveOrderToUnit(unitID, CMD.INSERT, insertParams, {"alt"})
	if command == true then
		widgetCommands[CommandString(cmdID, cmdParams, unitID)] = true
		local guard = guards[unitID]
		if guard then
			if (cmdID == CMD.GUARD or cmdID == CMD.REPAIR) and #cmdParams == 1 then
				-- what guard is guarding or repairing
				guard.targetID = cmdParams[1]
			else
				-- guard has no target
				guard.targetID = nil
			end
		end
	end
end

local function SetGuardMoveState(guard, moveState)
	if guard.moveState ~= moveState then
		Spring.GiveOrderToUnit(guard.unitID, CMD.MOVE_STATE, {moveState}, {})
		guard.moveState = moveState
	end
end

local function CreateGuard(unitID)
	local defID = Spring.GetUnitDefID(unitID)
	local states = Spring.GetUnitStates(unitID)
	local guard = CopyTable(GetDefInfo(defID))
	guard.unitID = unitID
	guard.initialMoveState = states["movestate"]
	guard.moveState = states["movestate"]
	guards[unitID] = guard
	return guard
end

local function CreateTarget(unitID)
	local defID = Spring.GetUnitDefID(unitID)
	local info = GetDefInfo(defID)
	local target = { unitID = unitID, size = info.size }
	targets[unitID] = target
	return target
end

local function ClearBlob(blob)
	for ti, target in pairs(blob.targets) do
		targets[target.unitID] = nil
	end
	for gi, guard in pairs(blob.guards) do
		guards[guard.unitID] = nil
	end
	for bi, checkBlob in pairs(blobs) do
		if checkBlob == blob then
			table.remove(blobs, bi)
			break
		end
	end
end

local function ClearTarget(unitID)
	local target = targets[unitID]
	if target == nil then return end
	local blob = target.blob
	for ti, blobTarget in pairs(blob.targets) do
		if blobTarget == target then
			table.remove(blob.targets, ti)
			break
		end
	end
	if #blob.targets == 0 then
		ClearBlob(blob)
	end
	targets[unitID] = nil
end

local function ClearGuard(unitID)
	local guard = guards[unitID]
	if guard == nil then return false end
	local blob = guard.blob
	for gi, blobGuard in pairs(blob.guards) do
		if blobGuard == guard then
			if guard.canAssist then blob.canAssist = blob.canAssist - 1 end
			if guard.canRepair then blob.canRepair = blob.canRepair - 1 end
			if guard.angle then blob.needSlotting = true end
			Spring.GiveOrderToUnit(guard.unitID, CMD.MOVE_STATE, {guard.initialMoveState}, {})
			table.remove(blob.guards, gi)
			break
		end
	end
	if #blob.guards == 0 then
		ClearBlob(blob)
	end
	guards[unitID] = nil
end

local function ClearGuards(guardList)
	for i, unitID in pairs(guardList) do
		ClearGuard(unitID)
	end
end

local function CreateBlob(guardList, targetList)
	-- check for targets that are guards here
	local theseGuards = {}
	local theseNewTargets = {}
	local overlapBlob
	local totalNewTargets = 0
	for i, unitID in pairs(guardList) do theseGuards[unitID] = true end
	for i, unitID in pairs(targetList) do
		-- make sure this target isn't guarding our guards and clear it if it is
		local guard = guards[unitID]
		local targetIsGuardingUs
		if guard then
			for ti, t in pairs(guard.blob.targets) do
				if theseGuards[t.unitID] then
					targetIsGuardingUs = true
				end
			end
		end
		if targetIsGuardingUs then ClearGuard(unitID) end
		-- is this target already in a blob?
		local target = targets[unitID]
		if target then
			overlapBlob = target.blob
		else
			theseNewTargets[unitID] = true
			totalNewTargets = totalNewTargets + 1
		end
	end
	local dupeGuards = {}
	if overlapBlob then
		-- make sure our guards aren't targets in the blob we're merging with
		for i, unitID in pairs(guardList) do
			local target = targets[unitID]
			if target then
				if target.blob == overlapBlob then
					ClearTarget(unitID)
					if #overlapBlob.targets == 0 then
						ClearBlob(overlapBlob)
						break
					end
				end
			end
		end
	end
	if overlapBlob then
		-- check for duplicate guards on the overlap blob
		-- and check for guards in the overlap blob that are set as targets here
		for gi, guard in pairs(overlapBlob.guards) do
			if theseGuards[guard.unitID] then
				dupeGuards[guard.unitID] = true
				totalDupeGuards = totalDupeGuards + 1
			elseif theseNewTargets[guard.unitID] then
				ClearGuard(guard.unitID)
				if #overlapBlob.guards == 0 then
					ClearBlob(overlapBlob)
				end
			end
		end
	end
	local blob = overlapBlob or { guards = {}, targets = {}, guardDistance = 100, canAssist = 0, canRepair = 0 }
	if totalDupeGuards ~= #guardList then
		-- if all the guards aren't already on the blob, add them
		for i, unitID in pairs(guardList) do
			if not dupeGuards[unitID] then
				local guard = guards[unitID] or CreateGuard(unitID)
				guard.blob = blob
				table.insert(blob.guards, guard)
				if guard.canAssist then blob.canAssist = blob.canAssist + 1 end
				if guard.canRepair then blob.canRepair = blob.canRepair + 1 end
			end
		end
	end
	for unitID, nothing in pairs(theseNewTargets) do
		local target = targets[unitID] or CreateTarget(unitID)
		target.blob = blob
		table.insert(blob.targets, target)
	end
	if not overlapBlob then table.insert(blobs, blob) end
	return blob
end

local function CreateMonoBlob(guardID, targetID)
	local target = targets[targetID]
	local blob
	if target then
		blob = target.blob
		ClearGuard(guardID)
		local guard = CreateGuard(guardID)
		guard.blob = blob
		table.insert(blob.guards, guard)
		if guard.canAssist then blob.canAssist = blob.canAssist + 1 end
		if guard.canRepair then blob.canRepair = blob.canRepair + 1 end
	else
		blob = CreateBlob({guardID}, {targetID})
	end
	return blob
end

local function GetAllies(myTeam)
	local info = { Spring.GetTeamInfo(myTeam) }
	local allyID = info[6]
	local allyTeams = Spring.GetTeamList(allyID)
	return allyTeams
end

local function EvaluateTargets(blob)
	blob.needsAssist = {}
	blob.needsRepair = {}
	local maxTargetSize = 0
	local minX = 100000
	local maxX = -100000
	local minZ = 100000
	local maxZ = -100000
	local totalVX = 0
	local totalVZ = 0
	local maxVectorSize = 0
	local moreThanOne = #blob.targets > 1
	for ti, target in pairs(blob.targets) do
		local unitID = target.unitID
		if blob.canAssist > 0 then
			target.constructing = Spring.GetUnitIsBuilding(unitID)
			if target.constructing then table.insert(blob.needsAssist, unitID) end
		end
		if blob.canRepair > 0 then
			local health, maxHealth = Spring.GetUnitHealth(unitID)
			target.damaged = health < maxHealth
			if target.damaged then table.insert(blob.needsRepair, unitID) end
		end
		if moreThanOne then
			if target.size > maxTargetSize then maxTargetSize = target.size end
			local ux, uy, uz = Spring.GetUnitPosition(unitID)
			if ux > maxX then maxX = ux end
			if ux < minX then minX = ux end
			if uz > maxZ then maxZ = uz end
			if uz < minZ then minZ = uz end
			local vx, vy, vz = Spring.GetUnitVelocity(unitID)
			totalVX = totalVX + vx
			totalVZ = totalVZ + vz
			local vectorSize = Pythagorean(vx, vz)
			if vectorSize > maxVectorSize then maxVectorSize = vectorSize end
		end
	end
	if moreThanOne then
		blob.vx = totalVX / #blob.targets
		blob.vz = totalVZ / #blob.targets
		blob.speed = maxVectorSize * 30
		local dx = maxX - minX
		local dz = maxZ - minZ
		blob.radius = (Pythagorean(dx, dz) / 2) + (maxTargetSize / 2)
		blob.x = (maxX + minX) / 2
		blob.z = (maxZ + minZ) / 2
	else
		blob.x, blob.y, blob.z = Spring.GetUnitPosition(blob.targets[1].unitID)
		blob.vx, blob.vy, blob.vz = Spring.GetUnitVelocity(blob.targets[1].unitID)
		blob.radius = blob.targets[1].size / 2
		blob.speed = Pythagorean(blob.vx, blob.vz) * 30
	end
	blob.preVectorX, blob.preVectorZ = blob.x, blob.z
	blob.x, blob.z = ApplyVector(blob.x, blob.z, blob.vx, blob.vz)
	blob.y = Spring.GetGroundHeight(blob.x, blob.z)
end

local function EvaluateGuards(blob)
	blob.willSlot = {}
	blob.slotted = {}
	blob.willAssist = {}
	blob.willRepair = {}
	blob.willGuard = {}
	for gi, guard in pairs(blob.guards) do
		local unitID = guard.unitID
		if guard.isCombatant and guard.speed > blob.speed then
			local gx, gy, gz = Spring.GetUnitPosition(unitID)
			guard.x, guard.y, guard.z = gx, gy, gz
			local dist = Distance(blob.x, blob.z, gx, gz)
			if dist > blob.radius + (blob.guardDistance * 3) then
				if #blob.targets == 1 then
					if not guard.guarding then
						GiveCommand(guard.unitID, CMD.GUARD, {blob.targets[1].unitID})
						guard.guarding = true
					end
				else
					guard.guarding = nil
					GiveCommand(guard.unitID, CMD.MOVE, {blob.x, blob.y, blob.z})
				end
				SetGuardMoveState(guard, 0)
				if guard.angle then blob.needSlotting = true end
				guard.angle = nil
			else
				guard.guarding = nil
				if guard.angle == nil then
					blob.needSlotting = true
					table.insert(blob.willSlot, guard)
				else
					table.insert(blob.slotted, guard)
				end
				if blob.underFire then
					SetGuardMoveState(guard, 2)
				else
					SetGuardMoveState(guard, 1)
				end
			end
		else
			if guard.angle then blob.needSlotting = true end
			if guard.canRepair and #blob.needsRepair > 0 then
				local repair = true
				local target = targets[guard.targetID]
				if target then
					if target.damaged then repair = false end
				end
				if repair then table.insert(blob.willRepair, guard) end
			elseif guard.canAssist and #blob.needsAssist > 0 then
				local assist = true
				local target = targets[guard.targetID]
				if target then
					if target.constructing then assist = false end
				end
				if assist then table.insert(blob.willAssist, guard) end
			else
				local target = targets[guard.targetID]
				if not target then table.insert(blob.willGuard, guard) end
			end
		end
	end
end

local function SlotGuard(guard, blob, ax, az, guardDist)
	blob.guardCircumfrence = blob.guardCircumfrence + guard.size
	local attacking
	local cmdQueue = Spring.GetUnitCommands(guard.unitID, 1)
	if cmdQueue[1] then
		if cmdQueue[1].id == CMD.ATTACK then attacking = true end
	end
	local maxDist = guard.size * 0.5
	if attacking then
		if blob.underFire then
			maxDist = ((guard.range * 0.5) + guard.speed) * 0.5
		else
			maxDist = ((guard.range * 0.5) + guard.speed)
		end
	end
	-- move into position if needed
	if guardDist == nil then guardDist = blob.radius + blob.guardDistance end
	if ax == nil then ax, az = RandomAway(blob.x, blob.z, guardDist, guard.angle) end
	local slotDist = Distance(guard.x, guard.z, ax, az)
	if slotDist > maxDist then
		local ay = Spring.GetGroundHeight(ax, az)
		GiveCommand(guard.unitID, CMD.MOVE, {ax, ay, az})
	end
end

local function AssignCombat(blob)
	-- find angle slots if needed and move units to them
	local divisor = #blob.slotted + #blob.willSlot
	if divisor > 0 then
		if divisor < 3 and (blob.lastVX ~= blob.vx or blob.lastVZ ~= blob.vz) then blob.needSlotting = true end -- one or two guards should guard in front of unit first
		local angleAdd, angle
		if blob.needSlotting then
			-- if we need to result, get a starting angle and division
			angleAdd = twicePi / divisor
			if divisor < 3 and (blob.speed > 0) then 
				 -- one or two guards should guard in front of unit first
				angle = atan2(-blob.vz, blob.vx)
				blob.lastAngle = angle
			elseif blob.lastAngle then
				angle = blob.lastAngle
			elseif #blob.slotted > 0 then
				-- grab an angle from an already slotted guard
				angle = blob.slotted[1].angle
				blob.lastAngle = angle
			elseif blob.willSlot[1] then
				-- angle from a unit's position
				local guard = blob.willSlot[1]
				if guard.x == nil then
					guard.x, guard.y, guard.z = Spring.GetUnitPosition(guard.unitID)
				end
				angle = AngleAtoB(blob.x, blob.z, guard.x, guard.z)
			else
				angle = random() * twicePi
				blob.lastAngle = angle
			end
		end
		local guardDist = blob.radius + blob.guardDistance
		if blob.underFire then guardDist = blob.radius + (blob.guardDistance * 0.5) end
		blob.guardCircumfrence = 0
		local emptyAngles = {}
		-- calculate all angles and assign to unslotted first
		for i = 1, divisor do
			local guard
			local ax, az
			if blob.needSlotting then
				-- if we need to reslot, find the nearest unslotted guard to this angle
				local a = angle + (angleAdd * (i - 1))
				if a > twicePi then a = a - twicePi end
				if #blob.willSlot > 0 then
					ax, az = RandomAway(blob.x, blob.z, guardDist, a)
					local leastDist = 10000
					local bestGuard = 1
					for gi, g in pairs(blob.willSlot) do
						local dist = Distance(g.x, g.z, ax, az)
						if dist < leastDist then
							leastDist = dist
							bestGuard = gi
						end
					end
					guard = table.remove(blob.willSlot, bestGuard)
					guard.angle = a
				else
					table.insert(emptyAngles, a)
				end
			else
				guard = table.remove(blob.slotted)
			end
			if guard ~= nil then SlotGuard(guard, blob, ax, az, guardDist) end
		end
		-- assign the rest to already slotted
		for i, a in pairs(emptyAngles) do
			local ax, az = RandomAway(blob.x, blob.z, guardDist, a)
			local leastDist = 10000
			local bestGuard = 1
			for gi, g in pairs(blob.slotted) do
				local angleDist = AngleDist(g.angle, a)
				local dist = 2 * abs(sin(angleDist / 2)) * guardDist
				if dist < leastDist then
					leastDist = dist
					bestGuard = gi
				end
			end
			local guard = table.remove(blob.slotted, bestGuard)
			guard.angle = a
			if guard ~= nil then SlotGuard(guard, blob, ax, az, guardDist) end
		end
		blob.guardDistance = max(100, ceil(blob.guardCircumfrence / 7.5))
	end
	blob.needSlotting = false
end

local function AssignAssist(blob)
	if #blob.needsAssist == 0 or #blob.willAssist == 0 then return end
	local quota = 1
	if #blob.needsAssist == 1 then
		quota = #blob.willAssist
	else
		quota = math.floor(#blob.needsAssist / #blob.willAssist)
	end
	for ti, unitID in pairs(blob.needsAssist) do
		if ti == #blob.needsAssist then quota = #blob.willAssist end
		for i = 1, quota do
			local guard = table.remove(blob.willAssist)
			GiveCommand(guard.unitID, CMD.GUARD, {unitID})
		end
		if #blob.willAssist == 0 then break end
	end
end

local function AssignRepair(blob)
	if #blob.needsRepair == 0 or #blob.willRepair == 0 then return end
	local quota = 1
	if #blob.needsRepair == 1 then
		quota = #blob.willRepair
	else
		quota = math.floor(#blob.needsRepair / #blob.willRepair)
	end
	for ti, unitID in pairs(blob.needsRepair) do
		if ti == #blob.needsRepair then quota = #blob.willRepair end
		for i = 1, quota do
			local guard = table.remove(blob.willRepair)
			GiveCommand(guard.unitID, CMD.REPAIR, {unitID})
		end
		if #blob.willRepair == 0 then break end
	end
end

local function AssignRemaining(blob)
	if #blob.willGuard == 0 then return end
	for gi, guard in pairs(blob.willGuard) do
		local ti = random(1, #blob.targets)
		local unitID = blob.targets[ti].unitID
		GiveCommand(guard.unitID, CMD.GUARD, {unitID})
	end
end

local function FilterTargets(guardList, targetList)
	-- filter out targets that are guards
	local theseGuards = {}
	local filteredTargets = {}
	for i, unitID in pairs(guardList) do theseGuards[unitID] = true end
	for i, unitID in pairs(targetList) do
		if not theseGuards[unitID] then
			table.insert(filteredTargets, unitID)
		end
	end
	return filteredTargets
end

local function QueueGuardTargets(unitID, cmdID, cmdParams, targetted)
	if guardTargetQueue[unitID] == nil then guardTargetQueue[unitID] = {} end
	guardTargetQueue[unitID][CommandString(cmdID, cmdParams)] = targetted
end

local cmdAreaGuard = {
	id      = CMD_AREA_GUARD,
	type    = CMDTYPE.ICON_AREA,
	tooltip = 'Define an area within which to guard all units',
	name    = 'Area Guard',
	cursor  = 'Guard',
	action  = 'areaguard',
}


-- SPRING CALLINS

function widget:CommandsChanged()
	local customCommands = widgetHandler.customCommands
	table.insert(customCommands, cmdAreaGuard)
end

function widget:KeyPress(key, mods, isRepeat) 
	--[[
	if (key == 0x067) and (not isRepeat) and (not mods.ctrl) and not (mods.shift) and (not mods.alt) then --g
		local cmdDescs = Spring.GetActiveCmdDescs()
		for i, cmdDesc in pairs(cmdDescs) do
			if cmdDesc.type ~= 20 then
				for k, v in pairs(cmdDesc) do
					Spring.Echo(k, v)
					if k == "params" then
						for kk, vv in pairs(v) do
							Spring.Echo(kk, vv)
						end
					end
				end
				Spring.Echo(" ")
			end
		end
		-- Spring.Echo("g")
		-- Spring.SetActiveCommand("areaguard")
		return true
	end
	return false
	]]--
end

function widget:Initialize()
	myTeam = Spring.GetMyTeamID()
	myAllies = GetAllies(myTeam)
end

function widget:CommandNotify(cmdID, cmdParams, cmdOpts)
	if cmdID == CMD_AREA_GUARD then
		local selected = Spring.GetSelectedUnits()
		if #selected == 0 then return end
		local cx, cy, cz, cr = cmdParams[1], cmdParams[2], cmdParams[3], cmdParams[4]
		-- find all units in area
		local targetted = {}
		for i, team in pairs(myAllies) do
			local units = Spring.GetUnitsInCylinder(cx, cz, cr, team)
			for i, unitID in pairs(units) do
				table.insert(targetted, unitID)
			end
		end
		if #targetted > 0 then
			targetted = FilterTargets(selected, targetted)
			if #targetted == 0 then return end
			if cmdOpts["shift"] then
				-- check if this command is current for each guard
				for i = 1, #selected do
					local unitID = selected[i]
					local commands = Spring.GetUnitCommands(unitID)
					if #commands == 0 then
						CreateBlob({unitID}, targetted)
					else
						QueueGuardTargets(unitID, cmdID, cmdParams, targetted)
					end
				end
			else
				CreateBlob(selected, targetted)
			end
		end
	end
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdOpts, cmdParams, cmdTag)
	if not interruptCmd[cmdID] then return end
	-- check if this is a command issued from this widget
	local cmdString = CommandString(cmdID, cmdParams, unitID)
	if widgetCommands[cmdString] then
		widgetCommands[cmdString] = nil
		return
	end
	-- below is not a widget command
	local shiftOpt = cmdOpts == CMD.OPT_SHIFT or cmdOpts == CMD.OPT_SHIFT + CMD.OPT_RIGHT
	if cmdID == CMD.GUARD then
		local currentCommand = true
		if shiftOpt then
			local commands = Spring.GetUnitCommands(unitID)
			if #commands > 0 then currentCommand = false end
		end
		if currentCommand then
			ClearGuard(unitID)
			CreateBlob({unitID}, {cmdParams[1]})
		else
			QueueGuardTargets(unitID, cmdID, cmdParams, {cmdParams[1]})
		end
	elseif cmdID ~= CMD_AREA_GUARD then
		if not shiftOpt and guards[unitID] then
			ClearGuard(unitID)
		end
	end
end

function widget:UnitCmdDone(unitID, unitDefID, unitTeam, cmdID, cmdTag, cmdParams, cmdOpts)
	local guardTargets = guardTargetQueue[unitID]
	if guardTargets then
		-- see if the current command is a guard command
		local commands = Spring.GetUnitCommands(unitID)
		if #commands == 0 then return end
		local cmdString = CommandString(commands[1].id, commands[1].params)
		local targets = guardTargets[cmdString]
		if targets then
			-- add it to the blob
			CreateBlob({unitID}, targets)
			-- remove the set of targets from the queue
			guardTargets[cmdString] = nil
			local count = 0
			for cs, t in pairs(guardTargets) do
				count = count + 1
			end
			if count == 0 then
				guardTargets = nil
				guardTargetQueue[unitID] = nil
			end
		end
	end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID, attackerID, attackerDefID, attackerTeamID)
	if guards[unitID] then ClearGuard(unitID) end
	if targets[unitID] then ClearTarget(unitID) end
end

function widget:UnitTaken(unitID, unitDefID, unitTeam, newTeam)
	if guards[unitID] then
		ClearGuard(unitID)
	end
end

function widget:GameFrame(gameFrame)
	if gameFrame % 30 == 0 then
		for bi, blob in pairs(blobs) do
			if blob.underFire ~= nil then
				-- blob is no longer under fire after 5 seconds
				if gameFrame > blob.underFire + 150 then
					blob.underFire = nil
				end
			end
			EvaluateTargets(blob) -- find blob position and minimum blob radius and who needs repair and assisting
			EvaluateGuards(blob) -- find which guards need to do what
			AssignCombat(blob) -- put combatant guards into circle slots
			AssignAssist(blob)
			AssignRepair(blob)
			AssignRemaining(blob)
			blob.lastVX = blob.vx
			blob.lastVZ = blob.vz
			if blob.radius and blob.lastRadius then
				blob.expansionRate = (blob.radius - blob.lastRadius) / 30
			end
			blob.lastRadius = blob.radius + 0
		end
		lastCalcFrame = gameFrame
	end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
	local guard = guards[unitID]
	if guard then
		guard.blob.underFire = Spring.GetGameFrame()
	end
	local target = targets[unitID]
	if target then
		target.blob.underFire = Spring.GetGameFrame()
	end
end

function widget:DrawWorldPreUnit()
	if not drawIndicators then return end
	if #blobs == 0 then return end
	local alt, ctrl, meta, shift = Spring.GetModKeyState()
	if not shift then return end
	local gameFrame = Spring.GetGameFrame()
	local framesSince = gameFrame - lastCalcFrame
	local divisor = 60 - framesSince
	gl.PushMatrix()
	gl.DepthTest(true)
	gl.LineWidth(3)
	gl.Color(0, 0, 1, 0.33)
	for bi, blob in pairs(blobs) do
		if #blob.targets > 1 and blob.x and blob.vx and blob.radius then
			if Spring.IsSphereInView(blob.x, blob.y, blob.z, blob.radius) then
				if blob.lastDrawFrame then
					if blob.lastDrawFrame + 10 < gameFrame then
						blob.displayX = nil
						blob.displayZ = nil
						blob.displayRadius = nil
					end
				end
				local x, z
				if blob.displayX then
					local adjustmentX = (blob.x - blob.displayX) / divisor
					local adjustmentZ = (blob.z - blob.displayZ) / divisor
					x, z = ApplyVector(blob.displayX, blob.displayZ, adjustmentX, adjustmentZ, 1)
				else
					x, z = ApplyVector(blob.preVectorX, blob.preVectorZ, blob.vx, blob.vz, framesSince)
				end
				local y = Spring.GetGroundHeight(x, z)
				local radius
				if blob.displayRadius then
					local adjustment = (blob.radius - blob.displayRadius) / divisor
					radius = blob.displayRadius + adjustment
				else
					radius = blob.radius
				end
				gl.DrawGroundCircle(x, y, z, radius, 8)
				blob.displayRadius = radius
				blob.displayX, blob.displayZ = x, z
				blob.lastDrawFrame = gameFrame
			end
		end
	end
	gl.DepthTest(false)
	gl.PopMatrix()
end
