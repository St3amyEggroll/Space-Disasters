--!strict
--[[
	S7: What is the UnreliableRemoteEvent payload limit, and do remotes carry buffers?

	Roblox documents a limit of about 900 bytes for an UnreliableRemoteEvent payload. The limit applies to the whole
	serialized event (arguments plus type tags and length prefixes), so the usable buffer size is somewhat smaller.
	Oversized unreliable events are dropped, and Roblox may print a warning in the Output of the SENDING side when that
	happens: copy those warnings too (both the Server and the Client Output in a multi-client test; Play Solo shows
	both in one window).

	Automatic, four unreliable sweeps: client->server and server->client, each with a bare buffer and with extra
	arguments (buffer + number + 10-char string) to learn the per-argument overhead.
	  Coarse pass: sizes 100..800 step 50, 810..1000 step 10, 1100, 1200; 5 copies of each size, with a pause between
	  sizes so bandwidth throttling cannot pass for a size limit.
	  Fine pass: step 1 between the largest size that arrived and the smallest size that never arrived.
	Each buffer holds its size (u16) in bytes 0-1, the sweep id in byte 2, then a deterministic byte pattern; the
	receiver checks typeof(arg) == "buffer", the length, the header, every pattern byte and the extra arguments.
	Finally a 50 KB buffer goes over a reliable RemoteEvent in both directions.

	Expected: every arrival is typeof "buffer"; the bare-buffer limit is a bit under 900 bytes; the extras lower it
	by roughly their encoded size; nothing between the limit and 1200 bytes arrives; the 50 KB reliable buffer arrives
	intact both ways.
]]

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local COPIES_PER_SIZE = 5
local BURST_GAP = 0.25 -- s between sizes (5 x 1.2 KB per 0.25 s stays far below the bandwidth budget)
local GRACE = 1.5 -- s the receiver keeps listening after the sender's reliable "done"
local EXTRA_NUMBER = 1234.5678 -- non-integer so it cannot be packed as a small integer
local EXTRA_STRING = "ABCDEFGHIJ"
local RELIABLE_SIZE = 50 * 1024
local BOUNDARY_WINDOW = 40 -- bytes around the boundary listed in the per-size counts
local READY_TIMEOUT = 20
local REPLY_TIMEOUT = 30 -- s the server waits for a client reply
local CLIENT_TIMEOUT = 300 -- s the client waits for "finish"
local MAX_ARRAY = 256
--============================================================================

type Sweep = { id: number, label: string, toServer: boolean, extras: boolean }
type SizeCount = { sent: number, fireErrors: number, received: number, intact: number }
type Tally = { bySize: { [number]: SizeCount }, corrupt: number, firstError: string?, arrivalNote: string? }
type Arrivals = { buffers: number, strays: { [string]: number } } -- strays: arrivals that were not usable buffers
type Reply = { first: { number }, second: { number }, note: string? }
type BigResult = { intact: boolean, length: number, typeName: string }

local HEADER_SIZE = 3
local BIG_SWEEP_ID = 9
local SWEEPS: { Sweep } = {
	{ id = 1, label = "client->server, buffer only", toServer = true, extras = false },
	{ id = 2, label = "client->server, buffer + number + 10-char string", toServer = true, extras = true },
	{ id = 3, label = "server->client, buffer only", toServer = false, extras = false },
	{ id = 4, label = "server->client, buffer + number + 10-char string", toServer = false, extras = true },
}

local function findSweep(id: number?): Sweep?
	for _, sweep in SWEEPS do
		if sweep.id == id then
			return sweep
		end
	end
	return nil
end

local function finiteNumber(value: unknown): number?
	if type(value) == "number" and value == value and math.abs(value) ~= math.huge then
		return value
	end
	return nil
end

local function numberArray(value: unknown, expectedLength: number?): { number }?
	if type(value) ~= "table" then
		return nil
	end
	local list = value :: { unknown }
	local length = #list
	if length > MAX_ARRAY or (expectedLength ~= nil and length ~= expectedLength) then
		return nil
	end
	local result: { number } = {}
	for index = 1, length do
		local item = finiteNumber(list[index])
		if item == nil then
			return nil
		end
		result[index] = item
	end
	return result
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

local function coarseSizes(): { number }
	local sizes: { number } = {}
	for size = 100, 800, 50 do
		table.insert(sizes, size)
	end
	for size = 810, 1000, 10 do
		table.insert(sizes, size)
	end
	table.insert(sizes, 1100)
	table.insert(sizes, 1200)
	return sizes
end

--============================================================================
-- Payloads
--============================================================================

local function patternByte(size: number, index: number): number
	return (index * 37 + size * 11 + 5) % 256
end

local function makePayload(size: number, sweepId: number): buffer
	local payload = buffer.create(size)
	buffer.writeu16(payload, 0, size)
	buffer.writeu8(payload, 2, sweepId)
	for index = HEADER_SIZE, size - 1 do
		buffer.writeu8(payload, index, patternByte(size, index))
	end
	return payload
end

local function payloadIntact(payload: buffer, sweepId: number): boolean
	local length = buffer.len(payload)
	if length < HEADER_SIZE or buffer.readu16(payload, 0) ~= length or buffer.readu8(payload, 2) ~= sweepId then
		return false
	end
	for index = HEADER_SIZE, length - 1 do
		if buffer.readu8(payload, index) ~= patternByte(length, index) then
			return false
		end
	end
	return true
end

--============================================================================
-- Tallies
--============================================================================

local function newTallies(): { [number]: Tally }
	local tallies: { [number]: Tally } = {}
	for _, sweep in SWEEPS do
		tallies[sweep.id] = { bySize = {}, corrupt = 0, firstError = nil, arrivalNote = nil }
	end
	return tallies
end

local function countFor(tally: Tally, size: number): SizeCount
	local count = tally.bySize[size]
	if count == nil then
		count = { sent = 0, fireErrors = 0, received = 0, intact = 0 }
		tally.bySize[size] = count
	end
	return count
end

local function addStray(arrivals: Arrivals, reason: string)
	arrivals.strays[reason] = (arrivals.strays[reason] or 0) + 1
end

-- Receiver side: classify one unreliable event.
local function recordArrival(
	tallies: { [number]: Tally },
	arrivals: Arrivals,
	payload: unknown,
	extraNumber: unknown,
	extraString: unknown
)
	if type(payload) ~= "buffer" then
		addStray(arrivals, "typeof " .. typeof(payload))
		return
	end
	local length = buffer.len(payload)
	if length < HEADER_SIZE then
		addStray(arrivals, "buffer shorter than the header")
		return
	end
	local sweepId = buffer.readu8(payload, 2)
	local sweep = findSweep(sweepId)
	local tally: Tally? = tallies[sweepId]
	if sweep == nil or tally == nil then
		addStray(arrivals, "buffer with an unknown sweep id")
		return
	end
	arrivals.buffers += 1
	local count = countFor(tally, length)
	count.received += 1
	local extrasOk = if sweep.extras
		then extraNumber == EXTRA_NUMBER and extraString == EXTRA_STRING
		else extraNumber == nil and extraString == nil
	if extrasOk and payloadIntact(payload, sweepId) then
		count.intact += 1
	else
		tally.corrupt += 1
	end
end

local function arrivalSummary(arrivals: Arrivals): string
	local strays: { string } = {}
	for reason, count in arrivals.strays do
		table.insert(strays, string.format("%s x%d", reason, count))
	end
	table.sort(strays)
	return string.format(
		"typeof(arg) == 'buffer' for %d arrivals; unusable arrivals: %s",
		arrivals.buffers,
		if #strays > 0 then table.concat(strays, ", ") else "none"
	)
end

-- Sender side: fire COPIES_PER_SIZE copies of every size, pausing between sizes.
local function sendSweep(
	sweepId: number,
	sizes: { number },
	fire: (payload: buffer) -> ()
): ({ number }, { number }, string?)
	local sent: { number } = {}
	local errors: { number } = {}
	local firstError: string? = nil
	for index, size in sizes do
		local payload = makePayload(size, sweepId)
		sent[index] = 0
		errors[index] = 0
		for _ = 1, COPIES_PER_SIZE do
			local ok, err = pcall(function()
				fire(payload)
			end)
			if ok then
				sent[index] += 1
			else
				errors[index] += 1
				if firstError == nil then
					firstError = string.format("size %d: %s", size, tostring(err))
				end
			end
		end
		task.wait(BURST_GAP)
	end
	return sent, errors, firstError
end

local function sortedSizes(tally: Tally): { number }
	local sizes: { number } = {}
	for size in tally.bySize do
		table.insert(sizes, size)
	end
	table.sort(sizes)
	return sizes
end

-- firstGap: smallest tested size that never arrived; lastOk: largest intact size below it; largestOk: overall.
local function boundary(tally: Tally): (number?, number?, number?)
	local firstGap: number? = nil
	local lastOk: number? = nil
	local largestOk: number? = nil
	for _, size in sortedSizes(tally) do
		local count = tally.bySize[size]
		if count.intact > 0 then
			largestOk = size
			if firstGap == nil then
				lastOk = size
			end
		end
		if count.received == 0 and firstGap == nil then
			firstGap = size
		end
	end
	return firstGap, lastOk, largestOk
end

local function formatBytes(value: number?): string
	return if value then string.format("%d B", value) else "none"
end

--============================================================================
-- Server
--============================================================================

local function runServer(ctx: SpikeKit.ServerContext)
	local unreliable = ctx.unreliableRemote("U") -- first: clients wait for these
	local reliable = ctx.remote("R")
	local players = ctx.players()
	table.sort(players, function(a: Player, b: Player): boolean
		return a.Name < b.Name
	end)
	local firstPlayer: Player? = players[1]
	if firstPlayer == nil then
		ctx.report("ERROR: no players")
		return
	end
	local target: Player = firstPlayer
	ctx.report("Test client: " .. target.Name .. (if #players > 1 then " (other players idle)" else ""))

	local tallies = newTallies()
	local arrivals: Arrivals = { buffers = 0, strays = {} }
	local requests: { [number]: number } = {} -- serial -> number of sizes in the request
	local replies: { [number]: Reply } = {}
	local ready = false
	local bigRequestedAt = 0
	local bigToServer: BigResult? = nil
	local bigToServerSeconds = 0
	local bigToClient: BigResult? = nil

	local connections: { RBXScriptConnection } = {}
	table.insert(
		connections,
		unreliable.OnServerEvent:Connect(
			function(player: Player, payload: unknown, extraNumber: unknown, extraString: unknown)
				if player == target then
					recordArrival(tallies, arrivals, payload, extraNumber, extraString)
				end
			end
		)
	)
	table.insert(
		connections,
		reliable.OnServerEvent:Connect(
			function(player: Player, kind: unknown, a: unknown, b: unknown, c: unknown, d: unknown)
				if player ~= target then
					return
				end
				if kind == "ready" then
					ready = true
				elseif kind == "done" or kind == "tally" then
					-- a = request serial, b / c = per-size arrays (sent + fire errors, or received + intact), d = note
					local serial = finiteNumber(a)
					local length = if serial then requests[serial] else nil
					if serial == nil or length == nil then
						return
					end
					local first, second = numberArray(b, length), numberArray(c, length)
					if first and second then
						replies[serial] = {
							first = first,
							second = second,
							note = if type(d) == "string" then string.sub(d, 1, 500) else nil,
						}
					end
				elseif kind == "big" then
					bigToServerSeconds = os.clock() - bigRequestedAt
					if type(a) == "buffer" then
						bigToServer = {
							intact = buffer.len(a) == RELIABLE_SIZE and payloadIntact(a, BIG_SWEEP_ID),
							length = buffer.len(a),
							typeName = typeof(a),
						}
					else
						bigToServer = { intact = false, length = -1, typeName = typeof(a) }
					end
				elseif kind == "bigResult" then
					local length = finiteNumber(b)
					if type(a) == "boolean" and length and type(c) == "string" then
						bigToClient = { intact = a, length = length, typeName = string.sub(c, 1, 50) }
					end
				end
			end
		)
	)

	local serialCounter = 0
	local function request(kind: string, sweep: Sweep, sizes: { number }, timeout: number): Reply?
		serialCounter += 1
		local serial = serialCounter
		requests[serial] = #sizes
		reliable:FireClient(target, kind, serial, sweep.id, sizes)
		waitUntil(function(): boolean
			return replies[serial] ~= nil
		end, timeout)
		return replies[serial]
	end

	local function runPass(sweep: Sweep, sizes: { number })
		local tally = tallies[sweep.id]
		if sweep.toServer then
			local reply = request("send", sweep, sizes, #sizes * BURST_GAP + REPLY_TIMEOUT)
			task.wait(GRACE) -- unreliable events may trail the reliable "done"
			if reply == nil then
				ctx.report(string.format("[%s] ERROR: the client never confirmed the sweep", sweep.label))
				return
			end
			for index, size in sizes do
				local count = countFor(tally, size)
				count.sent += reply.first[index]
				count.fireErrors += reply.second[index]
			end
			if tally.firstError == nil then
				tally.firstError = reply.note
			end
		else
			local sent, errors, firstError = sendSweep(sweep.id, sizes, function(payload: buffer)
				if sweep.extras then
					unreliable:FireClient(target, payload, EXTRA_NUMBER, EXTRA_STRING)
				else
					unreliable:FireClient(target, payload)
				end
			end)
			for index, size in sizes do
				local count = countFor(tally, size)
				count.sent += sent[index]
				count.fireErrors += errors[index]
			end
			if tally.firstError == nil then
				tally.firstError = firstError
			end
			task.wait(GRACE)
			local reply = request("tally", sweep, sizes, REPLY_TIMEOUT)
			if reply == nil then
				ctx.report(string.format("[%s] ERROR: the client never sent its tally", sweep.label))
				return
			end
			for index, size in sizes do
				-- the client's counts are cumulative per size, so they replace ours
				local count = countFor(tally, size)
				count.received = reply.first[index]
				count.intact = reply.second[index]
			end
			tally.arrivalNote = reply.note
		end
	end

	local function summarize(sweep: Sweep): number?
		local tally = tallies[sweep.id]
		local firstGap, lastOk, largestOk = boundary(tally)
		local oddity = ""
		if largestOk and firstGap and largestOk > firstGap then
			oddity = string.format(" (NON-MONOTONIC: %d B arrived although %d B never did)", largestOk, firstGap)
		end
		ctx.report(
			string.format(
				"[%s] largest size that arrived intact: %s; smallest size that never arrived: %s%s",
				sweep.label,
				formatBytes(lastOk),
				formatBytes(firstGap),
				oddity
			)
		)
		local center = lastOk or firstGap
		if center then
			local parts: { string } = {}
			for _, size in sortedSizes(tally) do
				if math.abs(size - center) <= BOUNDARY_WINDOW then
					local count = tally.bySize[size]
					local corrupt = count.received - count.intact
					table.insert(
						parts,
						string.format(
							"%d:%d/%d%s",
							size,
							count.intact,
							count.sent,
							if corrupt > 0 then string.format("(+%d corrupt)", corrupt) else ""
						)
					)
				end
			end
			ctx.report(
				string.format("[%s] intact/sent per size near the boundary: %s", sweep.label, table.concat(parts, " "))
			)
		end
		local sent, fireErrors, received, intact = 0, 0, 0, 0
		for _, count in tally.bySize do
			sent += count.sent
			fireErrors += count.fireErrors
			received += count.received
			intact += count.intact
		end
		ctx.report(
			string.format(
				"[%s] totals: sent %d, Fire errors %d, arrived %d, intact %d, corrupt %d%s",
				sweep.label,
				sent,
				fireErrors,
				received,
				intact,
				received - intact,
				if tally.arrivalNote then "; client side: " .. tally.arrivalNote else ""
			)
		)
		if tally.firstError then
			ctx.report(string.format("[%s] first Fire error: %s", sweep.label, tally.firstError))
		end
		return lastOk
	end

	local ok, err = pcall(function()
		local clientReady = waitUntil(function(): boolean
			return ready
		end, READY_TIMEOUT)
		if not clientReady then
			error("the test client never reported ready", 0)
		end

		local limits: { [number]: number? } = {}
		for _, sweep in SWEEPS do
			ctx.report(string.format("Sweep: %s", sweep.label))
			runPass(sweep, coarseSizes())
			local firstGap, lastOk = boundary(tallies[sweep.id])
			if firstGap and lastOk and firstGap - lastOk > 1 then
				local fine: { number } = {}
				for size = lastOk + 1, firstGap - 1 do
					table.insert(fine, size)
				end
				ctx.report(string.format("[%s] fine pass %d..%d B", sweep.label, lastOk + 1, firstGap - 1))
				runPass(sweep, fine)
			end
			limits[sweep.id] = summarize(sweep)
		end
		ctx.report("Server side arrivals: " .. arrivalSummary(arrivals))

		-- Reliable RemoteEvent with a 50 KB buffer, both directions
		bigRequestedAt = os.clock()
		reliable:FireClient(target, "bigRequest")
		waitUntil(function(): boolean
			return bigToServer ~= nil
		end, REPLY_TIMEOUT)
		local toServer = bigToServer
		if toServer then
			ctx.report(
				string.format(
					"Reliable %d B buffer client->server: arrived as typeof %s, %d B, intact=%s, %.2f s after the request",
					RELIABLE_SIZE,
					toServer.typeName,
					toServer.length,
					tostring(toServer.intact),
					bigToServerSeconds
				)
			)
		else
			ctx.report(string.format("Reliable %d B buffer client->server: NEVER ARRIVED", RELIABLE_SIZE))
		end
		local fireOk, fireErr = pcall(function()
			reliable:FireClient(target, "big", makePayload(RELIABLE_SIZE, BIG_SWEEP_ID))
		end)
		if not fireOk then
			ctx.report(
				string.format(
					"Reliable %d B buffer server->client: FireClient error %s",
					RELIABLE_SIZE,
					tostring(fireErr)
				)
			)
		end
		waitUntil(function(): boolean
			return bigToClient ~= nil
		end, REPLY_TIMEOUT)
		local toClient = bigToClient
		if toClient then
			ctx.report(
				string.format(
					"Reliable %d B buffer server->client: arrived as typeof %s, %d B, intact=%s",
					RELIABLE_SIZE,
					toClient.typeName,
					toClient.length,
					tostring(toClient.intact)
				)
			)
		else
			ctx.report(string.format("Reliable %d B buffer server->client: NEVER ARRIVED", RELIABLE_SIZE))
		end

		-- Verdict
		local c2sBare, c2sExtras, s2cBare, s2cExtras = limits[1], limits[2], limits[3], limits[4]
		local overheads: { string } = {}
		if c2sBare and c2sExtras then
			table.insert(overheads, string.format("c2s %d B", c2sBare - c2sExtras))
		end
		if s2cBare and s2cExtras then
			table.insert(overheads, string.format("s2c %d B", s2cBare - s2cExtras))
		end
		local clientStrays = false
		for id = 3, 4 do
			local note = tallies[id].arrivalNote
			if note and not string.find(note, "unusable arrivals: none", 1, true) then
				clientStrays = true
			end
		end
		local buffersOk = next(arrivals.strays) == nil and not clientStrays and arrivals.buffers > 0
		ctx.report(
			string.format(
				"RESULT: largest unreliable buffer that arrives: client->server %s bare / %s with number+10-char string; server->client %s bare / %s with extras (extras cost %s). Remotes deliver typeof 'buffer': %s. Reliable 50 KB buffer: c2s %s, s2c %s. Copy any payload-size warnings from the Output too.",
				formatBytes(c2sBare),
				formatBytes(c2sExtras),
				formatBytes(s2cBare),
				formatBytes(s2cExtras),
				if #overheads > 0 then table.concat(overheads, ", ") else "n/a",
				if buffersOk then "yes" else "NO (see the arrival lines)",
				if toServer and toServer.intact then "intact" else "FAILED",
				if toClient and toClient.intact then "intact" else "FAILED"
			)
		)
	end)
	reliable:FireClient(target, "finish")
	for _, connection in connections do
		connection:Disconnect()
	end
	if not ok then
		error(err, 0)
	end
end

--============================================================================
-- Client
--============================================================================

local function runClient(ctx: SpikeKit.ClientContext)
	if not ctx.isFirstPlayer then
		ctx.report("Not the test client (S7 only uses the first player); idle")
		return
	end
	local unreliable = ctx.unreliableRemote("U")
	local reliable = ctx.remote("R")
	local tallies = newTallies()
	local arrivals: Arrivals = { buffers = 0, strays = {} }
	local jobs: { () -> () } = {}
	local finished = false

	local unreliableConnection = unreliable.OnClientEvent:Connect(
		function(payload: unknown, extraNumber: unknown, extraString: unknown)
			recordArrival(tallies, arrivals, payload, extraNumber, extraString)
		end
	)
	local reliableConnection = reliable.OnClientEvent:Connect(
		function(kind: unknown, a: unknown, b: unknown, c: unknown)
			if kind == "send" or kind == "tally" then
				local serial, sweep, sizes = finiteNumber(a), findSweep(finiteNumber(b)), numberArray(c, nil)
				if serial == nil or sweep == nil or sizes == nil then
					return
				end
				local validSerial: number, validSweep: Sweep, validSizes: { number } = serial, sweep, sizes
				if kind == "send" then
					table.insert(jobs, function()
						ctx.status(string.format("S7: sending %s (%d sizes)", validSweep.label, #validSizes))
						local sent, errors, firstError = sendSweep(validSweep.id, validSizes, function(payload: buffer)
							if validSweep.extras then
								unreliable:FireServer(payload, EXTRA_NUMBER, EXTRA_STRING)
							else
								unreliable:FireServer(payload)
							end
						end)
						reliable:FireServer("done", validSerial, sent, errors, firstError)
					end)
				else
					local tally = tallies[validSweep.id]
					local received: { number } = {}
					local intact: { number } = {}
					for index, size in validSizes do
						local count = countFor(tally, size)
						received[index] = count.received
						intact[index] = count.intact
					end
					reliable:FireServer("tally", validSerial, received, intact, arrivalSummary(arrivals))
				end
			elseif kind == "bigRequest" then
				table.insert(jobs, function()
					reliable:FireServer("big", makePayload(RELIABLE_SIZE, BIG_SWEEP_ID))
				end)
			elseif kind == "big" then
				if type(a) == "buffer" then
					local intact = buffer.len(a) == RELIABLE_SIZE and payloadIntact(a, BIG_SWEEP_ID)
					reliable:FireServer("bigResult", intact, buffer.len(a), typeof(a))
				else
					reliable:FireServer("bigResult", false, -1, typeof(a))
				end
			elseif kind == "finish" then
				finished = true
			end
		end
	)

	local ok, err = pcall(function()
		ctx.status("S7: measuring remote payload limits (about 1 minute)")
		reliable:FireServer("ready")
		local deadline = os.clock() + CLIENT_TIMEOUT
		while not finished and os.clock() < deadline do
			local job = table.remove(jobs, 1)
			if job then
				job()
			else
				task.wait(0.05)
			end
		end
		ctx.report("Client side arrivals (server->client sweeps): " .. arrivalSummary(arrivals))
	end)
	unreliableConnection:Disconnect()
	reliableConnection:Disconnect()
	if not ok then
		error(err, 0)
	end
end

local spike: SpikeKit.SpikeDef = {
	Id = "S7",
	Title = "UnreliableRemoteEvent payload limit + buffers",
	Players = 1,
	Instructions = "Automatic, about 1 minute; Play Solo is fine. Roblox may print WARNINGS about dropped or oversized remote payloads while this runs: copy those too (Server AND Client Output in a multi-client test).",
	Server = runServer,
	Client = runClient,
}

return spike
