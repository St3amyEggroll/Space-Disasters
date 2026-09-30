--!strict
--[[
	S3: Does a client-side change to workspace.Gravity affect only that client's own character?

	Setup: the first player (name sorts first, "Player1") sets workspace.Gravity = 50 on its own client; the other
	player keeps the default. The server never touches Gravity and reports the value it sees at the start, after the
	clients changed theirs, and at the end. Both clients switch their own Humanoid to the classic JumpPower mode
	(UseJumpPower = true, JumpPower = 40) for the test so the jump HEIGHT depends on gravity: in the newer JumpHeight
	mode the engine derives the take-off speed from Gravity, so heights would match and only airtimes would differ.
	Gravity and the jump settings are restored at the end.

	Automatic: the server fires "jump" 3 times, 2.5 s apart. Each client makes its own character jump and measures its
	own HumanoidRootPart peak height above the take-off point and its airtime (time spent more than 0.5 studs above
	the take-off point), plus the peak and airtime of the other player's character as replicated to its screen. The
	server measures both characters as it sees them too.

	Expected: the low-gravity player's jumps are about 4x higher (40^2 / (2 * 50) = 16 studs vs 4.1 studs) and 4x
	longer (about 1.6 s vs 0.4 s) on BOTH screens and on the server, the other player's jumps are normal, and the
	server's Gravity stays 196.2. Gravity is then a per-machine simulation setting that only affects what that machine
	simulates (its own character), and the result replicates like any other movement.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local LOW_GRAVITY = 50 -- workspace.Gravity on the first player's client
local FORCED_JUMP_POWER: number? = 40 -- nil keeps the place's jump settings
local JUMP_COUNT = 3
local JUMP_INTERVAL = 2.5 -- s between "jump" signals
local MEASURE_WINDOW = 2.3 -- s every observer tracks each jump (must stay below JUMP_INTERVAL)
local AIRBORNE_HEIGHT = 0.5 -- studs above the take-off point that count as "in the air"
local STAND_X = 8 -- the first player stands at x = -8, the others at x = +8 (off the SpawnLocation)
local STAND_Z = 12
local SETTLE_TIME = 1.5 -- s after moving to the stand point before reporting ready
local READY_TIMEOUT = 20
local RESULT_TIMEOUT = 10
local RESTORE_TIMEOUT = 5
local AFFECTED_RATIO = 1.5 -- the low-gravity airtime must be at least this many times the normal airtime
local MATCH_TOLERANCE = 0.25 -- an observed peak within 25% of the jumper's own measurement counts as the same jump
--============================================================================

type Target = { name: string, root: BasePart, humanoid: Humanoid? }
type Track = { target: Target, startY: number, peak: number, airborneAt: number?, landedAt: number? }
type JumpResult = { peak: number, airtime: number } -- airtime < 0: never left the ground or did not land in the window
type ResultsByJump = { [number]: JumpResult }

local LANDED_STATES: { [Enum.HumanoidStateType]: boolean } = {
	[Enum.HumanoidStateType.Landed] = true,
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
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
		task.wait(0.1)
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

local function ownCharacter(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character or player.CharacterAdded:Wait()
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if humanoid and humanoid:IsA("Humanoid") and root and root:IsA("BasePart") then
		return character, humanoid, root
	end
	return nil, nil, nil
end

local function formatNumber(value: number?, pattern: string): string
	if value == nil then
		return "n/a"
	end
	return string.format(pattern, value)
end

--============================================================================
-- Jump tracking (shared by the server and the clients)
--============================================================================

local function stepTrack(track: Track, now: number)
	local height = track.target.root.Position.Y - track.startY
	if height > track.peak then
		track.peak = height
	end
	if track.airborneAt == nil then
		if height > AIRBORNE_HEIGHT then
			track.airborneAt = now
		end
	elseif track.landedAt == nil then
		local humanoid = track.target.humanoid
		local landedState = humanoid ~= nil and LANDED_STATES[humanoid:GetState()] == true
		if height < AIRBORNE_HEIGHT or landedState then
			track.landedAt = now
		end
	end
end

-- Tracks every target for `duration` seconds; `onStart` runs right after the take-off heights are recorded.
local function measure(targets: { Target }, duration: number, onStart: (() -> ())?): { Track }
	local tracks: { Track } = {}
	for _, target in targets do
		table.insert(tracks, {
			target = target,
			startY = target.root.Position.Y,
			peak = 0,
			airborneAt = nil,
			landedAt = nil,
		})
	end
	if onStart then
		onStart()
	end
	local startClock = os.clock()
	while os.clock() - startClock < duration do
		RunService.Heartbeat:Wait()
		local now = os.clock()
		for _, track in tracks do
			if track.target.root.Parent ~= nil then
				stepTrack(track, now)
			end
		end
	end
	return tracks
end

local function resultOf(track: Track): JumpResult
	local airborneAt, landedAt = track.airborneAt, track.landedAt
	local airtime = if airborneAt and landedAt then landedAt - airborneAt else -1
	return { peak = track.peak, airtime = airtime }
end

local function describe(result: JumpResult): string
	if result.airtime < 0 then
		return string.format(
			"peak %.2f studs, airtime n/a (did not leave the ground or did not land within %.1f s)",
			result.peak,
			MEASURE_WINDOW
		)
	end
	return string.format("peak %.2f studs, airtime %.2f s", result.peak, result.airtime)
end

-- Average peak and airtime over the jumps (airtime ignores jumps that did not land in the window).
local function average(results: ResultsByJump?): (number?, number?)
	if results == nil then
		return nil, nil
	end
	local peakSum, peakCount, airSum, airCount = 0, 0, 0, 0
	for _, result in results do
		peakSum += result.peak
		peakCount += 1
		if result.airtime >= 0 then
			airSum += result.airtime
			airCount += 1
		end
	end
	local peak = if peakCount > 0 then peakSum / peakCount else nil
	local airtime = if airCount > 0 then airSum / airCount else nil
	return peak, airtime
end

local function expectedJump(humanoid: Humanoid, gravity: number): string
	if humanoid.UseJumpPower then
		local speed = humanoid.JumpPower
		return string.format(
			"ballistic expectation: peak %.1f studs, airtime %.2f s",
			speed * speed / (2 * gravity),
			2 * speed / gravity
		)
	end
	local height = humanoid.JumpHeight
	return string.format(
		"ballistic expectation (JumpHeight mode): peak %.1f studs, airtime %.2f s",
		height,
		2 * math.sqrt(2 * height / gravity)
	)
end

--============================================================================
-- Server
--============================================================================

local function runServer(ctx: SpikeKit.ServerContext)
	local remote = ctx.remote("Sync") -- first: clients wait for it
	local players = ctx.players()
	table.sort(players, function(a: Player, b: Player): boolean
		return a.Name < b.Name
	end)
	local gravityAtStart = Workspace.Gravity
	ctx.report(string.format("Server workspace.Gravity at start: %.2f", gravityAtStart))
	if #players < 2 then
		ctx.report("WARNING: fewer than 2 players; the 'other player' measurements will be missing")
	end

	local readyGravity: { [Player]: number } = {}
	local restoredGravity: { [Player]: number } = {}
	local measured: { [Player]: boolean } = {}
	local own: { [Player]: ResultsByJump } = {}
	local seen: { [Player]: { [string]: ResultsByJump } } = {} -- observer -> jumper name -> results
	local serverSeen: { [string]: ResultsByJump } = {}

	local function isPlayerName(name: string): boolean
		for _, player in players do
			if player.Name == name then
				return true
			end
		end
		return false
	end

	local function validJump(value: number?): number?
		if value and value >= 1 and value <= JUMP_COUNT and value % 1 == 0 then
			return value
		end
		return nil
	end

	local connection = remote.OnServerEvent:Connect(
		function(player: Player, kind: unknown, a: unknown, b: unknown, c: unknown, d: unknown)
			if kind == "ready" then
				local gravity = finiteNumber(a)
				if gravity then
					readyGravity[player] = gravity
				end
			elseif kind == "restored" then
				local gravity = finiteNumber(a)
				if gravity then
					restoredGravity[player] = gravity
				end
			elseif kind == "measured" then
				measured[player] = true
			elseif kind == "own" then
				local jump, peak, airtime = validJump(finiteNumber(a)), finiteNumber(b), finiteNumber(c)
				if jump and peak and airtime then
					local results = own[player] or {}
					results[jump] = { peak = peak, airtime = airtime }
					own[player] = results
				end
			elseif kind == "seen" then
				local jump, peak, airtime = validJump(finiteNumber(a)), finiteNumber(c), finiteNumber(d)
				if jump and type(b) == "string" and isPlayerName(b) and peak and airtime then
					local byJumper = seen[player] or {}
					local results = byJumper[b] or {}
					results[jump] = { peak = peak, airtime = airtime }
					byJumper[b] = results
					seen[player] = byJumper
				end
			end
		end
	)

	local ok, err = pcall(function()
		local allReady = waitUntil(function(): boolean
			for _, player in players do
				if player.Parent ~= nil and readyGravity[player] == nil then
					return false
				end
			end
			return true
		end, READY_TIMEOUT)
		if not allReady then
			ctx.report("WARNING: not every client reported ready in time; continuing with the ones that did")
		end
		for _, player in players do
			ctx.report(
				string.format(
					"%s reports its local workspace.Gravity = %s",
					player.Name,
					formatNumber(readyGravity[player], "%.2f")
				)
			)
		end
		local gravityAfterClients = Workspace.Gravity
		ctx.report(string.format("Server workspace.Gravity after the clients set theirs: %.2f", gravityAfterClients))

		for jump = 1, JUMP_COUNT do
			local jumpStart = os.clock()
			local targets: { Target } = {}
			for _, player in players do
				local _, root = characterParts(player)
				if root then
					table.insert(targets, { name = player.Name, root = root, humanoid = nil })
				end
			end
			remote:FireAllClients("jump", jump)
			for _, track in measure(targets, MEASURE_WINDOW, nil) do
				local result = resultOf(track)
				local results = serverSeen[track.target.name] or {}
				results[jump] = result
				serverSeen[track.target.name] = results
				ctx.report(string.format("Jump %d, SERVER view of %s: %s", jump, track.target.name, describe(result)))
			end
			local remaining = JUMP_INTERVAL - (os.clock() - jumpStart)
			if jump < JUMP_COUNT and remaining > 0 then
				task.wait(remaining)
			end
		end

		waitUntil(function(): boolean
			for player in readyGravity do
				if player.Parent ~= nil and not measured[player] then
					return false
				end
			end
			return true
		end, RESULT_TIMEOUT)
		remote:FireAllClients("finish")
		waitUntil(function(): boolean
			for player in readyGravity do
				if player.Parent ~= nil and restoredGravity[player] == nil then
					return false
				end
			end
			return true
		end, RESTORE_TIMEOUT)
		ctx.report(string.format("Server workspace.Gravity at the end: %.2f", Workspace.Gravity))

		-- Summary per jumper: own measurement vs what everyone else saw
		for _, jumper in players do
			local ownPeak, ownAir = average(own[jumper])
			local serverPeak, serverAir = average(serverSeen[jumper.Name])
			local parts = {
				string.format(
					"%s (local Gravity %s): own avg peak %s studs / airtime %s s",
					jumper.Name,
					formatNumber(readyGravity[jumper], "%.1f"),
					formatNumber(ownPeak, "%.2f"),
					formatNumber(ownAir, "%.2f")
				),
				string.format("server saw %s / %s", formatNumber(serverPeak, "%.2f"), formatNumber(serverAir, "%.2f")),
			}
			for _, observer in players do
				if observer ~= jumper then
					local byJumper = seen[observer]
					local seenPeak, seenAir = average(if byJumper then byJumper[jumper.Name] else nil)
					table.insert(
						parts,
						string.format(
							"%s's screen saw %s / %s",
							observer.Name,
							formatNumber(seenPeak, "%.2f"),
							formatNumber(seenAir, "%.2f")
						)
					)
				end
			end
			ctx.report("Summary: " .. table.concat(parts, "; "))
		end

		-- Verdict
		local problems: { string } = {}
		if
			math.abs(gravityAfterClients - gravityAtStart) > 1e-6
			or math.abs(Workspace.Gravity - gravityAtStart) > 1e-6
		then
			table.insert(problems, "the SERVER's Gravity changed")
		end
		local low = players[1]
		local lowPeak, lowAir = average(own[low])
		local normalPeaks: { string } = {}
		for index = 2, #players do
			local normal = players[index]
			local normalPeak, normalAir = average(own[normal])
			table.insert(
				normalPeaks,
				string.format(
					"%s %s studs / %s s",
					normal.Name,
					formatNumber(normalPeak, "%.1f"),
					formatNumber(normalAir, "%.2f")
				)
			)
			local normalGravity = readyGravity[normal]
			if normalGravity == nil or math.abs(normalGravity - gravityAtStart) > 1e-6 then
				table.insert(problems, string.format("%s's local Gravity was not the default", normal.Name))
			end
			if lowAir == nil or normalAir == nil then
				table.insert(problems, "missing airtime measurements")
			elseif lowAir < AFFECTED_RATIO * normalAir then
				table.insert(
					problems,
					string.format("%s's airtime is not clearly longer than %s's", low.Name, normal.Name)
				)
			end
		end
		-- Every observer (server + other clients) must have seen the same jump as the jumper measured
		for _, jumper in players do
			local ownPeak = average(own[jumper])
			if ownPeak then
				local tolerance = MATCH_TOLERANCE * math.max(ownPeak, 1)
				local serverPeak = average(serverSeen[jumper.Name])
				if serverPeak == nil or math.abs(serverPeak - ownPeak) > tolerance then
					table.insert(problems, string.format("the server saw a different jump height for %s", jumper.Name))
				end
				for _, observer in players do
					if observer ~= jumper then
						local byJumper = seen[observer]
						local seenPeak = average(if byJumper then byJumper[jumper.Name] else nil)
						if seenPeak == nil or math.abs(seenPeak - ownPeak) > tolerance then
							table.insert(
								problems,
								string.format(
									"%s's screen saw a different jump height for %s",
									observer.Name,
									jumper.Name
								)
							)
						end
					end
				end
			end
		end

		local numbers = string.format(
			"%s (local Gravity %.0f) %s studs / %s s vs %s",
			low.Name,
			LOW_GRAVITY,
			formatNumber(lowPeak, "%.1f"),
			formatNumber(lowAir, "%.2f"),
			if #normalPeaks > 0 then table.concat(normalPeaks, ", ") else "no second player"
		)
		if #problems == 0 then
			ctx.report(
				string.format(
					"RESULT: LOCAL ONLY. A client-side Gravity change moved only that client's own character: %s; every screen and the server saw the same jumps; server Gravity stayed %.2f.",
					numbers,
					Workspace.Gravity
				)
			)
		else
			ctx.report(string.format("RESULT: UNEXPECTED (%s). %s", table.concat(problems, "; "), numbers))
		end
	end)
	connection:Disconnect()
	if not ok then
		error(err, 0)
	end
end

--============================================================================
-- Client
--============================================================================

local function runClient(ctx: SpikeKit.ClientContext)
	local remote = ctx.remote("Sync")
	local character, humanoidOrNil, rootOrNil = ownCharacter(ctx.player)
	if character == nil or humanoidOrNil == nil or rootOrNil == nil then
		ctx.report("ERROR: own character has no Humanoid / HumanoidRootPart")
		return
	end
	local humanoid: Humanoid = humanoidOrNil
	local root: BasePart = rootOrNil

	local originalGravity = Workspace.Gravity
	local originalUseJumpPower = humanoid.UseJumpPower
	local originalJumpPower = humanoid.JumpPower

	local pendingJumps: { number } = {}
	local finished = false
	local connection = remote.OnClientEvent:Connect(function(kind: unknown, a: unknown)
		if kind == "jump" then
			local jump = finiteNumber(a)
			if jump then
				table.insert(pendingJumps, jump)
			end
		elseif kind == "finish" then
			finished = true
		end
	end)

	local function runJump(jump: number)
		local targets: { Target } = { { name = ctx.player.Name, root = root, humanoid = humanoid } }
		for _, other in Players:GetPlayers() do
			if other ~= ctx.player then
				local _, otherRoot = characterParts(other)
				if otherRoot then
					table.insert(targets, { name = other.Name, root = otherRoot, humanoid = nil })
				end
			end
		end
		local tracks = measure(targets, MEASURE_WINDOW, function()
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end)
		for index, track in tracks do
			local result = resultOf(track)
			if index == 1 then
				ctx.report(
					string.format(
						"Jump %d, OWN character (local Gravity %.2f): %s",
						jump,
						Workspace.Gravity,
						describe(result)
					)
				)
				remote:FireServer("own", jump, result.peak, result.airtime)
			else
				ctx.report(
					string.format("Jump %d, %s as seen on my screen: %s", jump, track.target.name, describe(result))
				)
				remote:FireServer("seen", jump, track.target.name, result.peak, result.airtime)
			end
		end
		if jump >= JUMP_COUNT then
			remote:FireServer("measured")
		end
	end

	local ok, err = pcall(function()
		if ctx.isFirstPlayer then
			Workspace.Gravity = LOW_GRAVITY
		end
		local forcedJumpPower = FORCED_JUMP_POWER
		if forcedJumpPower then
			humanoid.UseJumpPower = true
			humanoid.JumpPower = forcedJumpPower
		end
		ctx.report(
			string.format(
				"Role: %s. Local Gravity %.2f, UseJumpPower=%s JumpPower=%.1f JumpHeight=%.2f; %s",
				if ctx.isFirstPlayer then "LOW gravity jumper" else "normal gravity jumper",
				Workspace.Gravity,
				tostring(humanoid.UseJumpPower),
				humanoid.JumpPower,
				humanoid.JumpHeight,
				expectedJump(humanoid, Workspace.Gravity)
			)
		)

		-- Stand apart from the other player, off the SpawnLocation
		root.AssemblyLinearVelocity = Vector3.zero
		local standX = if ctx.isFirstPlayer then -STAND_X else STAND_X
		character:PivotTo(CFrame.new(standX, root.Position.Y + 1, STAND_Z))
		ctx.status("S3: stand still, your character will jump 3 times by itself")
		task.wait(SETTLE_TIME)
		remote:FireServer("ready", Workspace.Gravity)

		local deadline = os.clock() + READY_TIMEOUT + JUMP_COUNT * JUMP_INTERVAL + RESULT_TIMEOUT + 30
		while not finished and os.clock() < deadline do
			local jump = table.remove(pendingJumps, 1)
			if jump then
				ctx.status(string.format("S3: jump %d of %d", jump, JUMP_COUNT))
				runJump(jump)
			else
				task.wait()
			end
		end
		if not finished then
			ctx.report("WARNING: never received 'finish' from the server")
		end
	end)

	connection:Disconnect()
	Workspace.Gravity = originalGravity
	humanoid.UseJumpPower = originalUseJumpPower
	humanoid.JumpPower = originalJumpPower
	remote:FireServer("restored", Workspace.Gravity)
	ctx.report(string.format("Restored local Gravity to %.2f and the jump settings", Workspace.Gravity))
	if not ok then
		error(err, 0)
	end
end

local spike: SpikeKit.SpikeDef = {
	Id = "S3",
	Title = "Client-side workspace.Gravity isolation",
	Players = 2,
	Instructions = "Needs 2 players (Test > Clients and Servers). Don't touch the controls: both characters move a few studs off the spawn and jump 3 times by themselves (Player1 with local Gravity 50). Watch both client windows; results are automatic. Takes about 15 s.",
	Server = runServer,
	Client = runClient,
}

return spike
