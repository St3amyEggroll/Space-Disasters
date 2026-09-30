--!strict
--[[
	S8: When the server changes replicated state and then fires a reliable RemoteEvent, has the client already
	applied the state change when the event's handler runs?

	Setup (server): an anchored part "S8_Probe", a 20-part Model "S8_Craft" (anchored root + 19 unanchored parts
	joined with WeldConstraints, PrimaryPart = root) and two Folders "S8_PocketA" / "S8_PocketB" in Workspace.
	300 iterations: pick a deterministic pseudo-random CFrame (position within +/-4000 studs, y 50..4000, random
	rotation) for the probe and another for the model; set Probe.CFrame, model:PivotTo(...); every 10th iteration
	re-parent the model to the other pocket; set PocketA's "Epoch" attribute to the iteration; then fire reliable
	"moved" with the iteration, the expected probe CFrame, the expected model pivot, the expected parent name and the
	epoch. Between iterations the server randomly waits 0 frames (several iterations in one frame), 1 frame or 2.

	Client handler, per category (probe position, probe rotation, model pivot, model rigidity, model parent, Epoch
	attribute): is the state exactly the one this event describes? A wrong state is classified by which iteration
	it belongs to (the targets are deterministic, so the client can recompute them): NEWER (a later iteration's state
	was already applied: fine for "has the client seen the change"), STALE (an older state: an ordering violation)
	or OTHER (matches no iteration, e.g. a torn / half-applied state). Stale and other states are polled for a few
	frames to learn how late the correct state shows up.

	Expected (if Roblox keeps property changes and remote events in one ordered stream): 0 stale for every
	category, so "ordering guaranteed for 300/300". NEWER results are possible when several iterations share a frame
	and the handler runs deferred after the whole packet batch was applied.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local ITERATIONS = 300
local SEED = 8008
local RANGE_XZ = 4000
local Y_MIN = 50
local Y_MAX = 4000
local MODEL_PARTS = 20 -- root included
local RING_RADIUS = 6 -- studs, layout of the welded parts around the root
local REPARENT_EVERY = 10
local SAME_FRAME_CHANCE = 0.35 -- chance to run the next iteration in the same frame
local ONE_FRAME_CHANCE = 0.45 -- chance to wait one frame (the rest waits two frames)
local POSITION_TOLERANCE = 1e-3 -- studs
local ROTATION_TOLERANCE = 1e-3 -- largest difference between matching rotation axes (~radians)
local RIGID_TOLERANCE = 1e-2 -- studs, welded part position relative to the root
local IDENTIFY_TOLERANCE = 0.5 -- studs, used only to find WHICH iteration a wrong state belongs to
local POLL_FRAMES = 30 -- frames a wrong state is polled for
local READY_TIMEOUT = 20
local FINISH_TIMEOUT = 30
local PROBE_NAME = "S8_Probe"
local MODEL_NAME = "S8_Craft"
local POCKET_A = "S8_PocketA"
local POCKET_B = "S8_PocketB"
--============================================================================

type Expectation = { index: number, probe: CFrame, pivot: CFrame, parentName: string, epoch: number }
-- ok: state matches this event; identity: iteration the observed state belongs to (nil = unknown); err: error size
type Check = (exp: Expectation) -> (boolean, number?, number)
type Category = {
	name: string,
	check: Check,
	correct: number,
	newer: number,
	stale: number,
	imprecise: number, -- right iteration, outside the tolerance
	other: number,
	late: { number }, -- frames until a wrong state became correct
	superseded: number, -- a newer state replaced it before the expected one was seen
	never: number,
	maxError: number, -- worst error among correct observations
}

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

--============================================================================
-- Deterministic targets (same on server and client)
--============================================================================

local function randomCFrame(rng: Random): CFrame
	local position = Vector3.new(
		rng:NextNumber(-RANGE_XZ, RANGE_XZ),
		rng:NextNumber(Y_MIN, Y_MAX),
		rng:NextNumber(-RANGE_XZ, RANGE_XZ)
	)
	local rotation = CFrame.fromEulerAnglesYXZ(
		rng:NextNumber(-math.pi, math.pi),
		rng:NextNumber(-math.pi, math.pi),
		rng:NextNumber(-math.pi, math.pi)
	)
	return CFrame.new(position) * rotation
end

-- Probe CFrame and model pivot for an iteration (iteration 0 = the initial build).
local function targetsFor(iteration: number): (CFrame, CFrame)
	local rng = Random.new(SEED * 1000 + iteration)
	local probe = randomCFrame(rng)
	local pivot = randomCFrame(rng)
	return probe, pivot
end

local function parentNameFor(iteration: number): string
	return if (iteration // REPARENT_EVERY) % 2 == 0 then POCKET_A else POCKET_B
end

-- Offset of welded part k (1..MODEL_PARTS-1) in the root's space.
local function partOffset(k: number): Vector3
	local angle = 2 * math.pi * k / (MODEL_PARTS - 1)
	return Vector3.new(math.cos(angle) * RING_RADIUS, (k % 3) - 1, math.sin(angle) * RING_RADIUS)
end

local function rotationError(a: CFrame, b: CFrame): number
	return math.max(
		(a.XVector - b.XVector).Magnitude,
		(a.YVector - b.YVector).Magnitude,
		(a.ZVector - b.ZVector).Magnitude
	)
end

--============================================================================
-- Server
--============================================================================

type World = { probe: Part, model: Model, pocketA: Folder, pocketB: Folder }

local function buildWorld(): World
	local pocketA = Instance.new("Folder")
	pocketA.Name = POCKET_A
	pocketA:SetAttribute("Epoch", 0)
	pocketA.Parent = Workspace
	local pocketB = Instance.new("Folder")
	pocketB.Name = POCKET_B
	pocketB.Parent = Workspace

	local probeCFrame, pivot = targetsFor(0)
	local probe = Instance.new("Part")
	probe.Name = PROBE_NAME
	probe.Anchored = true
	probe.CanCollide = false
	probe.Size = Vector3.new(2, 2, 2)
	probe.Color = Color3.fromRGB(255, 120, 0)
	probe.CFrame = probeCFrame
	probe.Parent = Workspace

	local model = Instance.new("Model")
	model.Name = MODEL_NAME
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Anchored = true
	root.CanCollide = false
	root.Size = Vector3.new(4, 1, 4)
	root.CFrame = pivot
	root.Parent = model
	for k = 1, MODEL_PARTS - 1 do
		local part = Instance.new("Part")
		part.Name = "P" .. k
		part.Anchored = false
		part.CanCollide = false
		part.Size = Vector3.new(1, 1, 1)
		part.CFrame = pivot * CFrame.new(partOffset(k))
		part.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = part
	end
	model.PrimaryPart = root
	model.Parent = pocketA
	return { probe = probe, model = model, pocketA = pocketA, pocketB = pocketB }
end

local function runServer(ctx: SpikeKit.ServerContext)
	local remote = ctx.remote("Sync") -- first: clients wait for it
	local players = ctx.players()
	local ready: { [Player]: boolean } = {}
	local reported: { [Player]: boolean } = {}
	local connection = remote.OnServerEvent:Connect(function(player: Player, kind: unknown)
		if kind == "ready" then
			ready[player] = true
		elseif kind == "reported" then
			reported[player] = true
		end
	end)
	local world = buildWorld()

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

		local rng = Random.new(SEED)
		local sameFrame, oneFrame, twoFrames = 0, 0, 0
		local startClock = os.clock()
		for i = 1, ITERATIONS do
			local probeCFrame, pivot = targetsFor(i)
			world.probe.CFrame = probeCFrame
			world.model:PivotTo(pivot)
			if i % REPARENT_EVERY == 0 then
				world.model.Parent = if world.model.Parent == world.pocketA then world.pocketB else world.pocketA
			end
			world.pocketA:SetAttribute("Epoch", i)
			local parent = world.model.Parent
			remote:FireAllClients(
				"moved",
				i,
				world.probe.CFrame,
				world.model:GetPivot(),
				if parent then parent.Name else "nil",
				i
			)

			local roll = rng:NextNumber()
			if roll < SAME_FRAME_CHANCE then
				sameFrame += 1
			elseif roll < SAME_FRAME_CHANCE + ONE_FRAME_CHANCE then
				oneFrame += 1
				task.wait()
			else
				twoFrames += 1
				task.wait()
				task.wait()
			end
		end
		ctx.report(
			string.format(
				"Server ran %d iterations in %.2f s: %d followed by another in the same frame, %d by a 1-frame wait, %d by a 2-frame wait",
				ITERATIONS,
				os.clock() - startClock,
				sameFrame,
				oneFrame,
				twoFrames
			)
		)
		remote:FireAllClients("finish", ITERATIONS)
		local allReported = waitUntil(function(): boolean
			for player in ready do
				if player.Parent ~= nil and not reported[player] then
					return false
				end
			end
			return true
		end, FINISH_TIMEOUT)
		if not allReported then
			ctx.report("WARNING: not every client reported its results")
		end
	end)
	connection:Disconnect()
	world.model:Destroy()
	world.probe:Destroy()
	world.pocketA:Destroy()
	world.pocketB:Destroy()
	if not ok then
		error(err, 0)
	end
end

--============================================================================
-- Client
--============================================================================

local function waitForChildOf(parent: Instance, name: string): Instance
	local child = parent:WaitForChild(name, 15)
	if child == nil then
		error(string.format("%s never replicated to the client", name), 0)
	end
	return child
end

local function newCategory(name: string, check: Check): Category
	return {
		name = name,
		check = check,
		correct = 0,
		newer = 0,
		stale = 0,
		imprecise = 0,
		other = 0,
		late = {},
		superseded = 0,
		never = 0,
		maxError = 0,
	}
end

local function lateSummary(frames: { number }): string
	if #frames == 0 then
		return "none"
	end
	local sorted = table.clone(frames)
	table.sort(sorted)
	return string.format(
		"%d (after %d..%d frames, median %d)",
		#sorted,
		sorted[1],
		sorted[#sorted],
		sorted[math.ceil(#sorted / 2)]
	)
end

local function runClient(ctx: SpikeKit.ClientContext)
	local remote = ctx.remote("Sync")
	ctx.status("S8: waiting for the test objects to replicate")
	local probe = waitForChildOf(Workspace, PROBE_NAME)
	local pocketA = waitForChildOf(Workspace, POCKET_A)
	waitForChildOf(Workspace, POCKET_B)
	local model = waitForChildOf(pocketA, MODEL_NAME)
	local root = waitForChildOf(model, "Root")
	if not probe:IsA("BasePart") or not model:IsA("Model") or not root:IsA("BasePart") then
		error("S8 test objects have unexpected classes", 0)
	end
	local probePart: BasePart = probe
	local craft: Model = model
	local rootPart: BasePart = root
	local parts: { BasePart } = {}
	for k = 1, MODEL_PARTS - 1 do
		local part = waitForChildOf(craft, "P" .. k)
		if not part:IsA("BasePart") then
			error("S8 model part has an unexpected class", 0)
		end
		parts[k] = part
	end

	-- Deterministic targets, for identifying which iteration a wrong state belongs to (index = iteration + 1)
	local probePositions: { Vector3 } = {}
	local pivotPositions: { Vector3 } = {}
	for iteration = 0, ITERATIONS do
		local probeCFrame, pivot = targetsFor(iteration)
		probePositions[iteration + 1] = probeCFrame.Position
		pivotPositions[iteration + 1] = pivot.Position
	end
	local function identify(position: Vector3, list: { Vector3 }): number?
		for index, candidate in list do
			if (candidate - position).Magnitude <= IDENTIFY_TOLERANCE then
				return index - 1
			end
		end
		return nil
	end

	local categories: { Category } = {
		newCategory("probe position", function(exp: Expectation): (boolean, number?, number)
			local position = probePart.Position
			local err = (position - exp.probe.Position).Magnitude
			local correct = err <= POSITION_TOLERANCE
			return correct, if correct then exp.index else identify(position, probePositions), err
		end),
		newCategory("probe rotation", function(exp: Expectation): (boolean, number?, number)
			local err = rotationError(probePart.CFrame, exp.probe)
			if err <= ROTATION_TOLERANCE then
				return true, exp.index, err
			end
			local identity = identify(probePart.Position, probePositions)
			-- right position but wrong rotation: a torn state, not an older/newer one
			return false, if identity == exp.index then nil else identity, err
		end),
		newCategory("model pivot", function(exp: Expectation): (boolean, number?, number)
			local pivot = craft:GetPivot()
			local positionError = (pivot.Position - exp.pivot.Position).Magnitude
			local correct = positionError <= POSITION_TOLERANCE
				and rotationError(pivot, exp.pivot) <= ROTATION_TOLERANCE
			return correct, if correct then exp.index else identify(pivot.Position, pivotPositions), positionError
		end),
		newCategory("model rigidity", function(exp: Expectation): (boolean, number?, number)
			local rootCFrame = rootPart.CFrame
			local worst = 0
			for k, part in parts do
				local offset = rootCFrame:PointToObjectSpace(part.Position)
				worst = math.max(worst, (offset - partOffset(k)).Magnitude)
			end
			local correct = worst <= RIGID_TOLERANCE
			return correct, if correct then exp.index else nil, worst
		end),
		newCategory("model parent", function(exp: Expectation): (boolean, number?, number)
			local parent = craft.Parent
			local name = if parent then parent.Name else "nil"
			if name == exp.parentName then
				return true, exp.index, 0
			elseif name == parentNameFor(exp.index - 1) then
				return false, exp.index - 1, 1
			elseif name == parentNameFor(exp.index + 1) then
				return false, exp.index + 1, 1
			end
			return false, nil, 1
		end),
		newCategory("PocketA Epoch attribute", function(exp: Expectation): (boolean, number?, number)
			local epoch = finiteNumber(pocketA:GetAttribute("Epoch"))
			if epoch == nil then
				return false, nil, math.huge
			end
			return epoch == exp.epoch, epoch, math.abs(epoch - exp.epoch)
		end),
	}

	local received = 0
	local latestIndex = 0
	local pendingPolls = 0
	local malformed = 0
	local mismatchedTargets = 0
	local finishedCount: number? = nil

	local function pollLate(category: Category, exp: Expectation)
		pendingPolls += 1
		task.spawn(function()
			for frame = 1, POLL_FRAMES do
				RunService.Heartbeat:Wait()
				local correct, identity = category.check(exp)
				if correct then
					table.insert(category.late, frame)
					pendingPolls -= 1
					return
				end
				if identity ~= nil and identity > exp.index then
					category.superseded += 1
					pendingPolls -= 1
					return
				end
			end
			category.never += 1
			pendingPolls -= 1
		end)
	end

	local function onMoved(exp: Expectation)
		received += 1
		latestIndex = math.max(latestIndex, exp.index)
		local expectedProbe, expectedPivot = targetsFor(exp.index)
		if
			(expectedProbe.Position - exp.probe.Position).Magnitude > IDENTIFY_TOLERANCE
			or (expectedPivot.Position - exp.pivot.Position).Magnitude > IDENTIFY_TOLERANCE
		then
			mismatchedTargets += 1
		end
		for _, category in categories do
			local correct, identity, err = category.check(exp)
			if correct then
				category.correct += 1
				category.maxError = math.max(category.maxError, err)
			elseif identity == nil then
				category.other += 1
				pollLate(category, exp)
			elseif identity > exp.index then
				category.newer += 1
			elseif identity == exp.index then
				category.imprecise += 1
			else
				category.stale += 1
				pollLate(category, exp)
			end
		end
	end

	local connection = remote.OnClientEvent:Connect(
		function(kind: unknown, a: unknown, b: unknown, c: unknown, d: unknown, e: unknown)
			if kind == "moved" then
				local index, epoch = finiteNumber(a), finiteNumber(e)
				if index and typeof(b) == "CFrame" and typeof(c) == "CFrame" and type(d) == "string" and epoch then
					onMoved({ index = index, probe = b, pivot = c, parentName = d, epoch = epoch })
				else
					malformed += 1
				end
			elseif kind == "finish" then
				finishedCount = finiteNumber(a)
			end
		end
	)

	local ok, err = pcall(function()
		remote:FireServer("ready")
		ctx.status("S8: measuring (about 10 s)")
		waitUntil(function(): boolean
			return finishedCount ~= nil
		end, READY_TIMEOUT + ITERATIONS * 0.1 + FINISH_TIMEOUT)
		waitUntil(function(): boolean
			return pendingPolls == 0
		end, POLL_FRAMES / 20 + 5)

		ctx.report(
			string.format(
				"Received %d/%d 'moved' events (last index %d, %d malformed, %d with targets that differ from the local recomputation)",
				received,
				finishedCount or ITERATIONS,
				latestIndex,
				malformed,
				mismatchedTargets
			)
		)
		local resultParts: { string } = {}
		for _, category in categories do
			ctx.report(
				string.format(
					"[%s] correct when the handler ran: %d/%d (max error %.6f); newer state already applied: %d; STALE: %d; right state but imprecise: %d; other/torn: %d; late fixes: %s; superseded before correct: %d; never correct within %d frames: %d",
					category.name,
					category.correct,
					received,
					category.maxError,
					category.newer,
					category.stale,
					category.imprecise,
					category.other,
					lateSummary(category.late),
					category.superseded,
					POLL_FRAMES,
					category.never
				)
			)
			local guaranteed = category.correct + category.newer + category.imprecise
			table.insert(resultParts, string.format("%s %d/%d", category.name, guaranteed, ITERATIONS))
		end
		ctx.report(
			"RESULT: ordering guaranteed (state at least as new as the event) for "
				.. table.concat(resultParts, ", ")
				.. " (exact-state counts are in the lines above)"
		)
	end)
	connection:Disconnect()
	remote:FireServer("reported")
	if not ok then
		error(err, 0)
	end
end

local spike: SpikeKit.SpikeDef = {
	Id = "S8",
	Title = "Replication vs RemoteEvent ordering",
	Players = 1,
	Instructions = "Automatic, about 10 s; Play Solo is fine (2 players also work, each client reports). Nothing to look at: the test objects are thousands of studs away.",
	Server = runServer,
	Client = runClient,
}

return spike
