function widget:GetInfo()
	return {
		name	= "Blob Guard",
		desc	= "guards multiple units",
		author  = "zoggop",
		date 	= "February 2014",
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

local circleDivs = 16
local circleTexture = "LuaUI/Images/blobguard/circle.png"

local drawIndicators = true
local mapBuffer = 32
local CMD_AREA_GUARD = 10125

local myTeam
local myAllies
local blobs = {}
local targets = {}
local guards = {}
local defSpeed = {}
local defSize = {}
local defRange = {}
local widgetCommands = {}
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

local function AngleDist(angle1, angle2)
	return abs((angle1 + 180 -  angle2) % 360 - 180)
	-- Spring.Echo(math.floor(angleDist * 57.29), math.floor(high * 57.29), math.floor(low * 57.29))
end

local function GetLongestWeaponRange(unitDefID)
	local weaponRange = 0
	local unitDef = UnitDefs[unitDefID]
	local weapons = unitDef["weapons"]
	for i=1, #weapons do
		local weaponDefID = weapons[i]["weaponDef"]
		local weaponDef = WeaponDefs[weaponDefID]
		if weaponDef["range"] > weaponRange then
			weaponRange = weaponDef["range"]
		end
	end
	return weaponRange
end

local function GetUnitDefInfo()
	local speeds = {}
	local types = {}
	local sizes = {}
	local ranges = {}
	for uDefID, uDef in pairs(UnitDefs) do
		speeds[uDefID] = uDef.speed
		local x = uDef.xsize * 8
		local z = uDef.zsize * 8
		sizes[uDefID] = ceil(Pythagorean(x, z))
		ranges[uDefID] = GetLongestWeaponRange(uDefID)
	end
	return speeds, sizes, ranges
end

local function GiveCommand(unitID, cmdID, cmdParams)
	local command = Spring.GiveOrderToUnit(unitID, cmdID, cmdParams, {})
	if command == true then
		local cmd = { unitID = unitID, cmdID = cmdID, cmdParams = cmdParams }
		table.insert(widgetCommands, cmd)
		if (cmdID == CMD.GUARD or cmdID == CMD.REPAIR) and #cmdParams == 1 then
			-- what guard is guarding or repairing
			local guard = guards[unitID]
			if guard then guard.targetID = cmdParams[1] end
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
	local uDef = UnitDefs[defID]
	local states = Spring.GetUnitStates(unitID)
	local guard = { unitID = unitID, blobs = {}, initialMoveState = states["movestate"], moveState = states["movestate"], speed = defSpeed[defID], size = defSize[defID], range = defRange[defID], canMove = uDef.canMove, canAttack = uDef.canAttack, canAssist = uDef.canAssist, canRepair = uDef.canRepair, canFly = uDef.canFly }
	if guard.canAttack and not guard.canFly and not guard.canAssist and not guard.canRepair then
		guard.isCombatant = true
	end
	guards[unitID] = guard
	return guard
end

local function CreateTarget(unitID)
	local defID = Spring.GetUnitDefID(unitID)
	local target = { unitID = unitID, blobs = {}, size = defSize[defID] }
	targets[unitID] = target
	return target
end

local function CreateBlob(guardList, targetList)
	-- check for targets that are guards here
	local theseGuards = {}
	local theseTargets = {}
	local totalTargets = 0
	for i, unitID in pairs(guardList) do theseGuards[unitID] = true end
	for i, unitID in pairs(targetList) do
		if not theseGuards[unitID] then
			theseTargets[unitID] = true
			totalTargets = totalTargets + 1
		end
	end
	if totalTargets == 0 then return end
	-- check for duplicate blob
	local dupeBlob
	for bi, blob in pairs(blobs) do
		if #blob.targets == totalTargets then
			local dupe = true
			for ti, target in pairs(blob.targets) do
				if not theseTargets[target.unitID] then
					dupe = false
					break
				end
			end
			if dupe then
				dupeBlob = blob
				break
			end
		end
	end
	local blob = dupeBlob or { guards = {}, targets = {}, guardDistance = 100, canAssist = 0, canRepair = 0 }
	-- check for duplicate guards within the duplicate blob
	local dupeGuards = {}
	if dupeBlob then
		for gi, guard in pairs(blob.guards) do
			if theseGuards[guard.unitID] then dupeGuards[unitID] = true end
		end
	end
	if #dupeGuards ~= #guardList then
		for i, unitID in pairs(guardList) do
			if not dupeGuards[unitID] then
				local guard = guards[unitID]
				if guard == nil then guard = CreateGuard(unitID) end
				table.insert(guard.blobs, blob)
				table.insert(blob.guards, guard)
				if guard.canAssist then blob.canAssist = blob.canAssist + 1 end
				if guard.canRepair then blob.canRepair = blob.canRepair + 1 end
			end
		end
	end
	if not dupeBlob then
		for unitID, nothing in pairs(theseTargets) do
			local target = targets[unitID]
			if target == nil then target = CreateTarget(unitID) end
			table.insert(target.blobs, blob)
			table.insert(blob.targets, target)
		end
		table.insert(blobs, blob)
	end
end

local function CreateMonoBlob(guardID, targetID)
	local target = targets[targetID]
	local blob
	if target then
		for bi, targetBlob in pairs(target.blobs) do
			if #targetBlob.targets == 1 then
				blob = targetBlob
				break
			end
		end
	end
	if blob == nil then
		CreateBlob({guardID}, {targetID})
	else
		local guard = guards[unitID]
		if guard == nil then guard = CreateGuard(guardID) end
		table.insert(guard.blobs, blob)
		table.insert(blob.guards, guard)
		if guard.canAssist then blob.canAssist = blob.canAssist + 1 end
		if guard.canRepair then blob.canRepair = blob.canRepair + 1 end
	end
end

local function ClearTarget(unitID)
	local target = targets[unitID]
	if target == nil then return false end
	for bi, blob in pairs(target.blobs) do
		for ti, blobTarget in pairs(blob.targets) do
			if blobTarget == target then
				table.remove(blob.targets, ti)
				break
			end
		end
		if #blob.targets == 0 then
			table.remove(blobs, bi)
		end
	end
end

local function ClearGuard(unitID)
	local guard = guards[unitID]
	if guard == nil then return false end
	for bi, blob in pairs(guard.blobs) do
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
			table.remove(blobs, bi)
		end
	end
	guards[unitID] = nil
end

local function ClearGuards(guardList)
	for i, unitID in pairs(guardList) do
		ClearGuard(unitID)
	end
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
		blob.radius = (max(dx, dz) / 2) + (maxTargetSize / 2)
		blob.x = (maxX + minX) / 2
		blob.z = (maxZ + minZ) / 2
	else
		blob.x, blob.y, blob.z = Spring.GetUnitPosition(blob.targets[1].unitID)
		blob.vx, blob.vy, blob.vz = Spring.GetUnitVelocity(blob.targets[1].unitID)
		blob.radius = blob.targets[1].size / 2
		blob.speed = Pythagorean(blob.vx, blob.vz)
	end
	blob.preVectorX, blob.preVectorZ = blob.x, blob.z
	blob.x, blob.z = ApplyVector(blob.x, blob.z, blob.vx, blob.vz)
	blob.y = Spring.GetGroundHeight(blob.x, blob.z)
end

local function EvaluateGuards(blob)
	blob.slotThese = {}
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
				if guard.angle == nil then blob.needSlotting = true end
				if blob.underFire then
					SetGuardMoveState(guard, 2)
				else
					SetGuardMoveState(guard, 1)
				end
				table.insert(blob.slotThese, guard)
			end
		elseif guard.canRepair and #blob.needsRepair > 0 then
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

local function AssignCombat(blob)
	-- find angle slots if needed and move units to them
	local divisor = #blob.slotThese
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
			else
				angle = random() * twicePi
				blob.lastAngle = angle
			end
		end
		local guardDist = blob.radius + blob.guardDistance
		if blob.underFire then guardDist = blob.radius + (blob.guardDistance * 0.5) end
		local guardCircumfrence = 0
		for i = 1, divisor do
			local guard
			local ax, az
			if blob.needSlotting then
				-- if we need to reslot, find the nearest guard to this angle
				local a = angle + (angleAdd * (i - 1))
				if a > twicePi then a = a - twicePi end
				ax, az = RandomAway(blob.x, blob.z, guardDist, a)
				local leastDist = 10000
				local bestGuard
				for gi, guard in pairs(blob.slotThese) do
					if guard.angle == nil then
						local dist = Distance(guard.x, guard.z, ax, az)
						if dist < leastDist then
							leastDist = dist
							bestGuard = gi
						end
					else
						local angleDist = AngleDist(guard.angle, a)
						local dist = abs(2 * sin(angleDist / 2)) * guardDist
						Spring.Echo(math.floor(angleDist * 57.29), math.floor(dist))
						if dist < leastDist then
							leastDist = dist
							bestGuard = gi
						end
					end
				end
				if bestGuard then
					guard = table.remove(blob.slotThese, bestGuard)
				else
					guard = table.remove(blob.slotThese)
				end
				guard.angle = a
			end
			if guard == nil then guard = table.remove(blob.slotThese) end
			guardCircumfrence = guardCircumfrence + guard.size
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
			if ax == nil then ax, az = RandomAway(blob.x, blob.z, guardDist, guard.angle) end
			local slotDist = Distance(guard.x, guard.z, ax, az)
			if slotDist > maxDist then
				local ay = Spring.GetGroundHeight(ax, az)
				GiveCommand(guard.unitID, CMD.MOVE, {ax, ay, az})
			end
		end
		blob.guardDistance = max(100, ceil(guardCircumfrence / 7.5))
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



-- SPRING CALLINS

function widget:CommandsChanged()
	local customCommands = widgetHandler.customCommands
	table.insert(customCommands, {			
		id      = CMD_AREA_GUARD,
		type    = CMDTYPE.ICON_AREA,
		tooltip = 'Define an area within which to guard all units',
		name    = 'AreaGuard',
		cursor  = 'Guard',
		action  = 'areaguard',
	})
end

function widget:Initialize()
	defSpeed, defSize, defRange = GetUnitDefInfo()
	myTeam = Spring.GetMyTeamID()
	myAllies = GetAllies(myTeam)
	circlePolys = gl.CreateList(function()
    gl.BeginEnd(GL.TRIANGLE_FAN, function()
      local radstep = (2.0 * math.pi) / circleDivs
      for i = 1, circleDivs do
        local a = (i * radstep)
        gl.Vertex(math.sin(a), circleOffset, math.cos(a))
      end
    end)
  end)
end

function widget:CommandNotify(cmdID, cmdParams, cmdOpts)
	if not interruptCmd[cmdID] then return end
	local selected = Spring.GetSelectedUnits()
	if #selected == 0 then return end
	local targetted
	if cmdID == CMD_AREA_GUARD then
		local cx, cy, cz, cr = cmdParams[1], cmdParams[2], cmdParams[3], cmdParams[4]
		-- find all units in area
		targetted = {}
		for i, team in pairs(myAllies) do
			local units = Spring.GetUnitsInCylinder(cx, cz, cr, team)
			for i, unitID in pairs(units) do
				table.insert(targetted, unitID)
			end
		end
	end
	if targetted ~= nil then
		if #targetted > 0 then 
			local clearCurrent = true
			for i, opt in pairs(cmdOpts) do
				if opt == CMD.OPT_SHIFT then
					clearCurrent = false
				end
			end
			if clearCurrent then ClearGuards(selected) end
			CreateBlob(selected, targetted)
		end
	end
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdOpts, cmdParams, cmdTag)
	if not interruptCmd[cmdID] then return end
	-- check if this is a command issued from this widget
	for ci, cmd in pairs(widgetCommands) do
		if unitID == cmd.unitID and cmdID == cmd.cmdID then
			local paramsMatch = true
			for pi, param in pairs(cmdParams) do
				if cmd.cmdParams[pi] ~= param then
					paramsMatch = false
					break
				end
			end
			if paramsMatch then
				table.remove(widgetCommands, ci)
				return
			end
		end
	end
	-- below is not a widget command
	if cmdID == CMD.GUARD then
		local clearCurrent = true
		if cmdOpts == CMD.OPT_SHIFT then
			clearCurrent = false
		end
		if clearCurrent then ClearGuard(unitID) end
		CreateMonoBlob(unitID, cmdParams[1])
	elseif cmdID ~= CMD_AREA_GUARD then
		if guards[unitID] then ClearGuard(unitID) end
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
	if guards[unitID] then
		for bi, blob in pairs(guards[unitID].blobs) do
			blob.underFire = Spring.GetGameFrame()
		end
	end
	if targets[unitID] then
		for bi, blob in pairs(targets[unitID].blobs) do
			blob.underFire = Spring.GetGameFrame()
		end
	end
end

function widget:DrawWorldPreUnit()
	if not drawIndicators then return end
	if #blobs == 0 then return end
	local alt, ctrl, meta, shift = Spring.GetModKeyState()
	if not shift then return end
	local framesSince = Spring.GetGameFrame() - lastCalcFrame
	gl.MatrixMode(GL.TEXTURE)
	gl.PushMatrix()
	gl.PolygonOffset(-25, -2)
	gl.Culling(GL.BACK)
	gl.DepthTest(true)
	gl.Color(0, 0, 1, 0.25)
	gl.Texture(circleTexture)
	for bi, blob in pairs(blobs) do
		if blob.x and blob.vx and blob.radius then
			if Spring.IsSphereInView(blob.x, blob.y, blob.z, blob.radius) then
				local x, z = ApplyVector(blob.preVectorX, blob.preVectorZ, blob.vx, blob.vz, framesSince)
				local radius = blob.radius
				if blob.expansionRate then radius = radius + (blob.expansionRate * framesSince) end
				gl.LoadIdentity()
				gl.DrawGroundQuad(x-radius, z-radius, x+radius, z+radius, false, 0, 0, 1, 1)
			end
		end
	end
	gl.Texture(false)
	gl.DepthTest(false)
	gl.Culling(false)
	gl.PolygonOffset(false)
	gl.PopMatrix()
   	gl.MatrixMode(GL.MODELVIEW)
end
