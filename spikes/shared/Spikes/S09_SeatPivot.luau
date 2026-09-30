--!strict
--[[
	S9: A Humanoid seated in a Seat whose model is moved with Model:PivotTo: does the character follow the seat on the
	server and on every client?

	Two variants, same motion program:
	  A: the Seat itself is anchored inside the model (next to an anchored root platform).
	  B: the Seat is unanchored and joined to the anchored root platform with a WeldConstraint (how our craft models
	     are built).
	The server builds the craft (12x1x12 platform + Seat) 12 studs above the spawn area and seats the FIRST player
	with seat:Sit(humanoid). Motion (server, PivotTo): hold 2 s; teleport +500 studs X; smooth move 30 studs/s along
	Z for 5 s (PivotTo every Heartbeat); snap-rotate 90 deg about Y; smooth-rotate 180 deg about Z over 3 s (upside
	down); hold 2 s.

	Automatic: the server and every client sample, every frame, the seated character's HumanoidRootPart CFrame
	relative to the Seat (seat.CFrame:ToObjectSpace(hrp.CFrame)) and report per phase the largest drift of that
	relative position (studs) and rotation (degrees) from its value at the start, plus whether the SeatWeld still
	exists and whether seat.Occupant is still the humanoid. Every frame is sampled (not only 10 Hz) so single-frame
	glitches are caught. The second player's camera follows the seated character during the motion.
	Visual: the seated player is asked whether the camera and character moved smoothly with the seat; the other player
	whether the seated character stayed in the seat on their screen.

	Expected: drift ~0 on every observer in both variants (the character is welded into an anchored assembly and
	replicates with it), SeatWeld and Occupant kept throughout. If B drifts on clients while A does not, craft seats
	need to be anchored or the character must be re-seated after each move.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local CRAFT_START = CFrame.new(0, 12, -24) -- root platform centre, high enough to stay clear of the baseplate upside down
local PLATFORM_SIZE = Vector3.new(12, 1, 12)
local SEAT_SIZE = Vector3.new(2, 1, 2)
local OCCUPY_TIMEOUT = 10 -- s for seat.Occupant to become the humanoid
local SETTLE_TIME = 1 -- s after seating before sampling starts
local HOLD_TIME = 2
local TELEPORT_OFFSET = Vector3.new(500, 0, 0)
local MOVE_SPEED = 30 -- studs/s along Z
local MOVE_TIME = 5
local SNAP_DWELL = 1 -- s the snap phases (teleport, 90 deg) keep sampling after the single step
local ROTATE_TIME = 3
local FINAL_HOLD = 2
local FOLLOW_TOLERANCE = 0.25 -- studs of relative drift still counted as "follows"
local READY_TIMEOUT = 20
local SAMPLING_TIMEOUT = 10
local ANSWER_TIMEOUT = 180 -- s the server waits for the visual answers
local CLIENT_TIMEOUT = 600
local SPAWN_CFRAME = CFrame.new(0, 5, 8) -- where the seated character is put back afterwards
--============================================================================

type Variant = { key: string, label: string, anchoredSeat: boolean }
type PhaseStats = { samples: number, maxPos: number, maxRot: number, weldMissing: number, occupantWrong: number }
type Sampler = { phase: number, baseline: CFrame?, phases: { PhaseStats } }

local VARIANTS: { Variant } = {
	{ key = "A", label = "A (anchored Seat in the model)", anchoredSeat = true },
	{ key = "B", label = "B (unanchored Seat welded to an anchored root)", anchoredSeat = false },
}

local PHASES: { string } = {
	"hold 2 s",
	"teleport +500 X",
	"smooth move 30 studs/s along Z for 5 s",
	"snap rotate 90 deg about Y",
	"smooth rotate 180 deg about Z over 3 s",
	"final hold 2 s",
}
local SMOOTH_MOVE_PHASE = 3

local function finiteNumber(value: unknown): number?
	if type(value) == "number" and value == value and math.abs(value) ~= math.huge then
		return value
	end
	return nil
end

local function waitUntil(predicate: () -> boolean, timeout: number): boolean
	local deadline = os.clock() + timeout
	while not predicate() do
		if os.clock() > deadline then
			return false
		end
		task.wait(0.05)
	end
	return true
end

local function characterParts(player: Player): (Humanoid?, BasePart?)
	local character = player.Character
	if character == nil then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return humanoid, root
	end
	return humanoid, nil
end

--============================================================================
-- Sampling (shared by the server and the clients)
--============================================================================

local function newSampler(): Sampler
	local phases: { PhaseStats } = {}
	for index = 1, #PHASES do
		phases[index] = { samples = 0, maxPos = 0, maxRot = 0, weldMissing = 0, occupantWrong = 0 }
	end
	return { phase = 1, baseline = nil, phases = phases }
end

local function hasSeatWeld(seat: Seat): boolean
	local weld = seat:FindFirstChild("SeatWeld")
	return weld ~= nil and weld:IsA("Weld")
end

local function sample(sampler: Sampler, seat: Seat, humanoid: Humanoid, root: BasePart)
	local relative = seat.CFrame:ToObjectSpace(root.CFrame)
	local baseline: CFrame = sampler.baseline or relative
	sampler.baseline = baseline
	local stats = sampler.phases[sampler.phase]
	local _, angle = (baseline.Rotation:Inverse() * relative.Rotation):ToAxisAngle()
	stats.samples += 1
	stats.maxPos = math.max(stats.maxPos, (relative.Position - baseline.Position).Magnitude)
	stats.maxRot = math.max(stats.maxRot, math.deg(math.abs(angle)))
	if not hasSeatWeld(seat) then
		stats.weldMissing += 1
	end
	if seat.Occupant ~= humanoid then
		stats.occupantWrong += 1
	end
end

local function phaseLine(variant: Variant, observer: string, index: number, stats: PhaseStats): string
	return string.format(
		"Variant %s | %s | phase %d (%s): max rel-pos drift %.3f studs, max rel-rot drift %.2f deg, %d samples, SeatWeld missing in %d, Occupant wrong in %d",
		variant.key,
		observer,
		index,
		PHASES[index],
		stats.maxPos,
		stats.maxRot,
		stats.samples,
		stats.weldMissing,
		stats.occupantWrong
	)
end

-- Worst values over all phases: max drift, the phase it happened in, total weld-missing and occupant-wrong samples.
local function worstOf(phases: { [number]: PhaseStats }): (number, number, number, number)
	local maxPos, worstPhase, weldMissing, occupantWrong = 0, 0, 0, 0
	for index, stats in phases do
		if stats.maxPos > maxPos or worstPhase == 0 then
			maxPos = math.max(maxPos, stats.maxPos)
			worstPhase = index
		end
		weldMissing += stats.weldMissing
		occupantWrong += stats.occupantWrong
	end
	return maxPos, worstPhase, weldMissing, occupantWrong
end

--============================================================================
-- Server
--============================================================================

local function buildCraft(variant: Variant): (Model, Seat)
	local model = Instance.new("Model")
	model.Name = "S9_Craft_" .. variant.key

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Anchored = true
	root.Size = PLATFORM_SIZE
	root.CFrame = CRAFT_START
	root.Color = Color3.fromRGB(90, 110, 140)
	root.Parent = model

	local seat = Instance.new("Seat")
	seat.Name = "Seat"
	seat.Anchored = variant.anchoredSeat
	seat.Size = SEAT_SIZE
	seat.CFrame = CRAFT_START * CFrame.new(0, (PLATFORM_SIZE.Y + SEAT_SIZE.Y) / 2, 0)
	seat.Color = Color3.fromRGB(255, 140, 40)
	seat.Parent = model

	-- Red nose on the -Z edge so observers can see the orientation
	local nose = Instance.new("Part")
	nose.Name = "Nose"
	nose.Anchored = variant.anchoredSeat
	nose.Size = Vector3.new(2, 1, 1)
	nose.CFrame = CRAFT_START * CFrame.new(0, 1, -PLATFORM_SIZE.Z / 2 + 0.5)
	nose.Color = Color3.fromRGB(220, 40, 40)
	nose.Parent = model

	if not variant.anchoredSeat then
		for _, part in { seat, nose } :: { BasePart } do
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part
		end
	end
	model.PrimaryPart = root
	model.Parent = Workspace
	return model, seat
end

local function runPhase(index: number, model: Model)
	if index == 1 then
		task.wait(HOLD_TIME)
	elseif index == 2 then
		model:PivotTo(model:GetPivot() + TELEPORT_OFFSET)
		task.wait(SNAP_DWELL)
	elseif index == 3 then
		local start = model:GetPivot()
		local startClock = os.clock()
		while true do
			local t = math.min(os.clock() - startClock, MOVE_TIME)
			model:PivotTo(start + Vector3.new(0, 0, MOVE_SPEED * t))
			if t >= MOVE_TIME then
				break
			end
			RunService.Heartbeat:Wait()
		end
	elseif index == 4 then
		model:PivotTo(model:GetPivot() * CFrame.Angles(0, math.rad(90), 0))
		task.wait(SNAP_DWELL)
	elseif index == 5 then
		local start = model:GetPivot()
		local startClock = os.clock()
		while true do
			local t = math.min(os.clock() - startClock, ROTATE_TIME)
			model:PivotTo(start * CFrame.Angles(0, 0, math.pi * t / ROTATE_TIME))
			if t >= ROTATE_TIME then
				break
			end
			RunService.Heartbeat:Wait()
		end
	else
		task.wait(FINAL_HOLD)
	end
end

local function runServer(ctx: SpikeKit.ServerContext)
	local remote = ctx.remote("Sync") -- first: clients wait for it
	local players = ctx.players()
	table.sort(players, function(a: Player, b: Player): boolean
		return a.Name < b.Name
	end)
	local seatedPlayerOrNil: Player? = players[1]
	if seatedPlayerOrNil == nil then
		ctx.report("ERROR: no players")
		return
	end
	local seatedPlayer: Player = seatedPlayerOrNil
	if #players < 2 then
		ctx.report("WARNING: only 1 player; there is no second observer")
	end

	local ready: { [Player]: boolean } = {}
	local sampling: { [Player]: number } = {} -- player -> variant index it is sampling
	local done: { [Player]: number } = {} -- player -> variant index it finished (answers given)
	local clientStats: { [number]: { [Player]: { [number]: PhaseStats } } } = {} -- variant -> player -> phase
	local connection = remote.OnServerEvent:Connect(
		function(
			player: Player,
			kind: unknown,
			a: unknown,
			b: unknown,
			c: unknown,
			d: unknown,
			e: unknown,
			f: unknown,
			g: unknown
		)
			local variantIndex = finiteNumber(a)
			if kind == "ready" then
				ready[player] = true
			elseif kind == "sampling" and variantIndex then
				sampling[player] = variantIndex
			elseif kind == "done" and variantIndex then
				done[player] = variantIndex
			elseif kind == "stats" and variantIndex and VARIANTS[variantIndex] ~= nil then
				local phase = finiteNumber(b)
				local maxPos, maxRot, samples, weldMissing, occupantWrong =
					finiteNumber(c), finiteNumber(d), finiteNumber(e), finiteNumber(f), finiteNumber(g)
				if
					phase
					and PHASES[phase] ~= nil
					and maxPos
					and maxRot
					and samples
					and weldMissing
					and occupantWrong
				then
					local byPlayer = clientStats[variantIndex] or {}
					local byPhase = byPlayer[player] or {}
					byPhase[phase] = {
						samples = samples,
						maxPos = maxPos,
						maxRot = maxRot,
						weldMissing = weldMissing,
						occupantWrong = occupantWrong,
					}
					byPlayer[player] = byPhase
					clientStats[variantIndex] = byPlayer
				end
			end
		end
	)

	local function everyReadyPlayer(predicate: (player: Player) -> boolean): () -> boolean
		return function(): boolean
			for player in ready do
				if player.Parent ~= nil and not predicate(player) then
					return false
				end
			end
			return true
		end
	end

	local model: Model? = nil
	local verdicts: { string } = {}

	local function unseatAndReturn(seat: Seat, humanoid: Humanoid, variantIndex: number)
		local weld = seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		humanoid.Sit = false
		remote:FireAllClients("unseat", variantIndex)
		task.wait(0.5)
		local character = seatedPlayer.Character
		if character then
			character:PivotTo(SPAWN_CFRAME)
		end
	end

	local function runVariant(variantIndex: number)
		local variant = VARIANTS[variantIndex]
		ctx.report("===== Variant " .. variant.label)
		local craft, seat = buildCraft(variant)
		model = craft
		local humanoid, root = characterParts(seatedPlayer)
		if humanoid == nil or root == nil then
			ctx.report(string.format("FAILURE: %s has no character to seat", seatedPlayer.Name))
			table.insert(verdicts, string.format("%s: no character", variant.key))
			return
		end
		local seatedHumanoid: Humanoid = humanoid
		local seatedRoot: BasePart = root

		local sitClock = os.clock()
		seat:Sit(seatedHumanoid)
		local occupied = waitUntil(function(): boolean
			return seat.Occupant == seatedHumanoid
		end, OCCUPY_TIMEOUT)
		if not occupied then
			ctx.report(
				string.format(
					"FAILURE: seat.Occupant never became %s's humanoid within %d s (Occupant = %s)",
					seatedPlayer.Name,
					OCCUPY_TIMEOUT,
					tostring(seat.Occupant)
				)
			)
			table.insert(verdicts, string.format("%s: could not seat the player", variant.key))
			unseatAndReturn(seat, seatedHumanoid, variantIndex)
			return
		end
		ctx.report(
			string.format(
				"Seated %s after %.2f s; SeatWeld present: %s",
				seatedPlayer.Name,
				os.clock() - sitClock,
				tostring(hasSeatWeld(seat))
			)
		)
		task.wait(SETTLE_TIME)

		remote:FireAllClients("begin", variantIndex, craft.Name, seatedPlayer)
		local sampler = newSampler()
		local sampleConnection = RunService.Heartbeat:Connect(function()
			sample(sampler, seat, seatedHumanoid, seatedRoot)
		end)
		local allSampling = waitUntil(
			everyReadyPlayer(function(player: Player): boolean
				return sampling[player] == variantIndex
			end),
			SAMPLING_TIMEOUT
		)
		if not allSampling then
			ctx.report("WARNING: not every client started sampling; moving anyway")
		end

		for phase = 1, #PHASES do
			sampler.phase = phase
			remote:FireAllClients("phase", phase)
			runPhase(phase, craft)
		end
		sampleConnection:Disconnect()
		remote:FireAllClients("end", variantIndex)
		for phase = 1, #PHASES do
			ctx.report(phaseLine(variant, "server", phase, sampler.phases[phase]))
		end

		ctx.report("Waiting for the clients' stats and visual answers...")
		local allDone = waitUntil(
			everyReadyPlayer(function(player: Player): boolean
				return done[player] == variantIndex
			end),
			ANSWER_TIMEOUT
		)
		if not allDone then
			ctx.report("WARNING: not every client answered in time")
		end

		-- Verdict for this variant
		local observers: { string } = {}
		local failures: { string } = {}
		local function judge(name: string, phases: { [number]: PhaseStats }?)
			if phases == nil then
				table.insert(observers, name .. " n/a")
				table.insert(failures, name .. " sent no stats")
				return
			end
			local maxPos, worstPhase, weldMissing, occupantWrong = worstOf(phases)
			table.insert(observers, string.format("%s %.3f", name, maxPos))
			if maxPos > FOLLOW_TOLERANCE then
				table.insert(
					failures,
					string.format("%s drift %.2f studs in phase %d (%s)", name, maxPos, worstPhase, PHASES[worstPhase])
				)
			end
			if weldMissing > 0 then
				table.insert(failures, string.format("%s saw no SeatWeld in %d samples", name, weldMissing))
			end
			if occupantWrong > 0 then
				table.insert(failures, string.format("%s saw a wrong Occupant in %d samples", name, occupantWrong))
			end
		end
		judge("server", sampler.phases)
		local byPlayer = clientStats[variantIndex] or {}
		for _, player in players do
			judge(player.Name, byPlayer[player])
		end
		local verdict = if #failures == 0
			then string.format(
				"FOLLOWS on every observer (worst drift in studs: %s; SeatWeld and Occupant kept)",
				table.concat(observers, ", ")
			)
			else string.format(
				"DOES NOT FOLLOW cleanly: %s (worst drift in studs: %s)",
				table.concat(failures, "; "),
				table.concat(observers, ", ")
			)
		ctx.report(string.format("RESULT variant %s: %s", variant.label, verdict))
		table.insert(verdicts, string.format("%s %s", variant.key, if #failures == 0 then "follows" else "FAILS"))

		unseatAndReturn(seat, seatedHumanoid, variantIndex)
	end

	local ok, err = pcall(function()
		local allReady = waitUntil(function(): boolean
			for _, player in players do
				if player.Parent ~= nil and not ready[player] then
					return false
				end
			end
			return true
		end, READY_TIMEOUT)
		if not allReady then
			ctx.report("WARNING: not every client reported ready; running anyway")
		end
		for variantIndex = 1, #VARIANTS do
			runVariant(variantIndex)
			local craft = model
			if craft then
				craft:Destroy()
				model = nil
			end
			task.wait(1)
		end
		ctx.report(
			"RESULT: seated character vs PivotTo'd seat: "
				.. table.concat(verdicts, ", ")
				.. " (visual answers are in the Q lines above)"
		)
	end)
	remote:FireAllClients("finish")
	connection:Disconnect()
	local craft = model
	if craft then
		craft:Destroy()
	end
	if not ok then
		error(err, 0)
	end
end

--============================================================================
-- Client
--============================================================================

type Message = { kind: string, a: unknown, b: unknown, c: unknown }
type Active = { variantIndex: number, sampler: Sampler, seat: Seat, humanoid: Humanoid, root: BasePart }

local function runClient(ctx: SpikeKit.ClientContext)
	local remote = ctx.remote("Sync")
	local camera = Workspace.CurrentCamera
	local originalSubject = camera.CameraSubject
	local queue: { Message } = {}
	local active: Active? = nil
	local seatedPlayer: Player? = nil
	local finished = false

	local connection = remote.OnClientEvent:Connect(function(kind: unknown, a: unknown, b: unknown, c: unknown)
		if type(kind) == "string" then
			table.insert(queue, { kind = kind, a = a, b = b, c = c })
		end
	end)
	local renderConnection = RunService.RenderStepped:Connect(function()
		local current = active
		if current and current.root.Parent ~= nil then
			sample(current.sampler, current.seat, current.humanoid, current.root)
		end
	end)

	local function begin(variantIndex: number, modelName: string, player: Player)
		local modelInstance = Workspace:WaitForChild(modelName, 10)
		local seat = if modelInstance then modelInstance:WaitForChild("Seat", 10) else nil
		local humanoid, root = characterParts(player)
		if seat == nil or not seat:IsA("Seat") or humanoid == nil or root == nil then
			ctx.report(
				string.format(
					"ERROR: could not find the seat or %s's character for variant %d",
					player.Name,
					variantIndex
				)
			)
			remote:FireServer("sampling", variantIndex)
			return
		end
		seatedPlayer = player
		active = { variantIndex = variantIndex, sampler = newSampler(), seat = seat, humanoid = humanoid, root = root }
		if player ~= ctx.player then
			camera.CameraSubject = humanoid -- follow the seated character so it stays visible
		end
		ctx.status(
			if player == ctx.player
				then "S9: you are seated. Don't press any keys; watch how your character and camera follow the seat."
				else string.format(
					"S9: your camera follows %s. Watch whether the character stays in the seat.",
					player.Name
				)
		)
		remote:FireServer("sampling", variantIndex)
	end

	local function finishVariant(variantIndex: number)
		local current = active
		active = nil
		if current == nil or current.variantIndex ~= variantIndex then
			remote:FireServer("done", variantIndex)
			return
		end
		local variant = VARIANTS[variantIndex]
		local observer = ctx.player.Name .. "'s client" .. (if seatedPlayer == ctx.player then " (seated)" else "")
		for phase = 1, #PHASES do
			local stats = current.sampler.phases[phase]
			ctx.report(phaseLine(variant, observer, phase, stats))
			remote:FireServer(
				"stats",
				variantIndex,
				phase,
				stats.maxPos,
				stats.maxRot,
				stats.samples,
				stats.weldMissing,
				stats.occupantWrong
			)
		end
		ctx.status("")
		if seatedPlayer == ctx.player then
			ctx.ask(
				string.format(
					"[Variant %s] Did your camera and character move smoothly with the seat during the smooth move (phase %d, the 30 studs/s slide)?",
					variant.key,
					SMOOTH_MOVE_PHASE
				),
				{ "Yes, smooth", "Jittery / lagging", "Character left the seat", "Unsure" }
			)
		else
			ctx.ask(
				string.format(
					"[Variant %s] Did the other player's character stay in the seat on your screen?",
					variant.key
				),
				{ "Yes, always", "Lagged behind / jittered", "Left the seat", "Unsure" }
			)
		end
		camera.CameraSubject = originalSubject
		remote:FireServer("done", variantIndex)
	end

	local function unseat()
		if seatedPlayer ~= ctx.player then
			return
		end
		local character = ctx.player.Character
		local humanoid, root = characterParts(ctx.player)
		if character and humanoid and root then
			humanoid.Sit = false
			task.wait(0.3)
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			character:PivotTo(SPAWN_CFRAME)
		end
	end

	local function handle(message: Message)
		local index = finiteNumber(message.a) -- variant index, or the phase index for "phase"
		if message.kind == "begin" then
			local modelName, player = message.b, message.c
			if
				index
				and VARIANTS[index] ~= nil
				and type(modelName) == "string"
				and typeof(player) == "Instance"
				and player:IsA("Player")
			then
				begin(index, modelName, player)
			end
		elseif message.kind == "phase" then
			local current = active
			if current and index and PHASES[index] ~= nil then
				current.sampler.phase = index
				ctx.status(string.format("S9: phase %d/%d - %s", index, #PHASES, PHASES[index]))
			end
		elseif message.kind == "end" then
			if index and VARIANTS[index] ~= nil then
				finishVariant(index)
			end
		elseif message.kind == "unseat" then
			unseat()
		elseif message.kind == "finish" then
			finished = true
		end
	end

	local ok, err = pcall(function()
		remote:FireServer("ready")
		ctx.status("S9: waiting for the server to seat the first player")
		local deadline = os.clock() + CLIENT_TIMEOUT
		while not finished and os.clock() < deadline do
			local message = table.remove(queue, 1)
			if message then
				handle(message)
			else
				task.wait()
			end
		end
	end)
	connection:Disconnect()
	renderConnection:Disconnect()
	camera.CameraSubject = originalSubject
	if not ok then
		error(err, 0)
	end
end

local spike: SpikeKit.SpikeDef = {
	Id = "S9",
	Title = "Seated character on a PivotTo'd seat",
	Players = 2,
	Instructions = "Needs 2 players (Test > Clients and Servers). Player1 gets seated on an orange seat on a platform that teleports, slides and flips (don't press keys, especially Space). Player2's camera follows Player1. Twice (variant A, then B), about 20 s each, then one question per player per variant.",
	Server = runServer,
	Client = runClient,
}

return spike
