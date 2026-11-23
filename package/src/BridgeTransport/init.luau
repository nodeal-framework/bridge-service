--!native
--!optimize 2

-- Two remotes for the whole game. Every call of a frame leaves in one packet per lane:
-- [seal, client only] then frames of [varint size][u32 endpoint][u16 call?][arguments].
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type Endpoint = {
	Id: number,
	Name: string,
	Lane: number,
	Returns: boolean,
	Args: any,
	Results: any,
	Arity: number,
	Rate: number,
	Handler: ((...any) -> ...any)?,
}

local RELIABLE, UNRELIABLE = 1, 2
local ANSWER = 0 -- endpoint id of the frame that carries a call's result
local SEAL = 6 -- bytes a client packet opens with

return function(Constants: any, Wire: any, Guard: any, Dynamic: any)
	local Transport = { Debug = false, Dynamic = Dynamic }

	local IsClient = RunService:IsClient()
	local IsStudio = RunService:IsStudio()
	local Limit, Rate = Constants.Limit, Constants.Rate
	local Head = if IsClient then SEAL else 0

	local Endpoints: { [number]: Endpoint } = {}
	local Held: { [number]: { buffer } } = {} -- client frames that came before their handler
	local Dirty: { any } = {} -- streams with something to send
	local ClientHeader = table.freeze({})

	-- per player: { reliable stream, unreliable stream, header }. Weak: see Guard.
	local Down: { [Player]: { any } } = setmetatable({}, { __mode = "k" }) :: any

	-- calls waiting for their answer, by call number: four flat lists, nothing allocated per call
	local Threads: { [number]: thread } = {}
	local Asked: { [number]: Endpoint } = {}
	local Owners: { [number]: Player } = {}
	local Deadlines: { [number]: number } = {}
	local Waiting, NextSweep = 0, 0

	local Scratch = buffer.create(4096)
	local LastCall = 0
	local Opened = not IsClient
	local Idle: thread? = nil

	--// Remotes //--
	local function remote(Class: string, Name: string): any
		if not IsClient then
			local Made = Instance.new(Class)
			Made.Name = Name
			Made.Parent = ReplicatedStorage
			return Made
		end

		local Found = ReplicatedStorage:WaitForChild(Name, Constants.Remote.Await)
		assert(Found, `[Bridge] remote '{Name}' never arrived`)

		-- out of sight of a casual remote spy
		Found.Name = ""
		Found.Parent = game:GetService("NetworkClient")
		return Found
	end

	local Remotes = {
		remote("RemoteEvent", Constants.Remote.Reliable),
		remote("UnreliableRemoteEvent", Constants.Remote.Unreliable),
	}

	-- The seed of this server's seals travels with the remote itself.
	if IsClient then
		Guard.Seed = Remotes[RELIABLE]:GetAttribute("Seed") or Remotes[RELIABLE]:GetAttributeChangedSignal("Seed"):Wait() or Remotes[RELIABLE]:GetAttribute("Seed")
	else
		Guard.Seed = Random.new():NextInteger(1, 2147483647)
		Remotes[RELIABLE]:SetAttribute("Seed", Guard.Seed)

		for _, Name in Constants.Decoys do
			local Decoy = Instance.new("RemoteEvent")
			Decoy.Name = Name
			Decoy.Parent = ReplicatedStorage

			Decoy.OnServerEvent:Connect(function(Player: Player)
				Guard.Strike(Player, "Decoy", Name, true)
			end)
		end
	end

	--// Streams //--
	local function stream(Lane: number, Player: Player?): any
		local Cap = if Lane == UNRELIABLE then Limit.Unreliable elseif IsClient then Limit.Inbound else Wire.MaxFrame
		local Stream = Wire.Stream(Head, Cap)

		Stream.Lane = Lane
		Stream.Player = Player
		Stream.Parked = Player ~= nil -- until that client says it is ready

		return Stream
	end

	local Up = if IsClient then { stream(RELIABLE), stream(UNRELIABLE) } else {}

	-- nil for anything that is not a player in the game: a table lookup then spares the engine a read
	local function join(Player: Player): { any }?
		if Player.Parent ~= Players then
			return nil
		end

		local Pair = { stream(RELIABLE, Player), stream(UNRELIABLE, Player), table.freeze({ Player = Player }) }
		Down[Player] = Pair

		return Pair
	end

	local function flush(Stream: any): ()
		Stream.Queued = false

		if Stream.Used == Head then
			return
		elseif Stream.Parked then
			-- a loading client keeps what must arrive, within reason
			if Stream.Lane == UNRELIABLE then
				Stream.Used = Head
			elseif Stream.Used > Limit.Parked then
				-- said once per overflow: dropped reliable frames used to vanish without a word
				warn(`[Bridge] {Stream.Player.Name} is still loading: {Stream.Used} bytes of reliable frames dropped`)
				Stream.Used = Head
				Stream.Data = buffer.create(1024)
			end
			return
		end

		local Packet = Wire.Take(Stream)

		if IsClient then
			Guard.Seal(Packet, Stream.Lane)
			Remotes[Stream.Lane]:FireServer(Packet)
		elseif Stream.Player.Parent == Players then
			Remotes[Stream.Lane]:FireClient(Stream.Player, Packet)
		end
	end

	-- Queues the frame sitting in Scratch.
	local function push(Stream: any, Length: number): ()
		if Head + Length + 3 > Stream.Cap then
			error(`[Bridge] a {Length} byte frame does not fit a {Stream.Cap} byte packet`, 0)
		elseif Stream.Used + Length + 3 > Stream.Cap then
			flush(Stream)
		end

		Wire.Push(Stream, Scratch, Length)

		if not Stream.Queued then
			Stream.Queued = true
			table.insert(Dirty, Stream)
		end
	end

	--// Outbound //--

	-- Writes the values into Scratch from Start and answers where they end.
	local function write(Schema: any, Start: number, ...: any): number
		if Schema == Dynamic then
			-- nothing to check them against: written at once, measured only when they do not fit
			local Fits, Written = pcall(Schema.BufferizeTo, Schema, Scratch, Start, ...)
			if Fits then
				return Start + Written
			end
		end

		-- GetSize is also what refuses a value the schema does not allow
		local Length = Start + Schema:GetSize(...)

		if Length > buffer.len(Scratch) then
			Scratch = buffer.create(Length * 2)
		end

		Schema:BufferizeTo(Scratch, Start, ...)
		return Length
	end

	local function encode(Endpoint: Endpoint, Call: number?, ...: any): number
		local Length = write(Endpoint.Args, if Call then 6 else 4, ...)

		buffer.writeu32(Scratch, 0, Endpoint.Id)
		if Call then
			buffer.writeu16(Scratch, 4, Call)
		end

		if Transport.Debug then
			print(`[Bridge] -> {Endpoint.Name} ({Length} B)`)
		end

		return Length
	end

	-- Fine comes straight from xpcall: the results follow it, or the error does.
	local function answer(Endpoint: Endpoint, Player: Player?, Call: number, Fine: boolean, ...: any): ()
		local Length = 7

		if Fine then
			Length = write(Endpoint.Results, 7, ...)
		elseif (...) ~= nil then
			warn(`[Bridge] {Endpoint.Name} failed: {(...)}`)
		end

		local Pair = Player and Down[Player]
		local Stream = if IsClient then Up[RELIABLE] else Pair and Pair[RELIABLE]

		if not Stream then
			return
		end

		buffer.writeu32(Scratch, 0, ANSWER)
		buffer.writeu16(Scratch, 4, Call)
		buffer.writeu8(Scratch, 6, if Fine then 1 else 0)

		push(Stream, Length)
	end

	local function ask(Endpoint: Endpoint, Stream: any, Player: Player?, ...: any): ...any
		repeat
			LastCall = LastCall % 65535 + 1
		until not Threads[LastCall]

		local Call = LastCall
		push(Stream, encode(Endpoint, Call, ...))

		Threads[Call] = coroutine.running()
		Asked[Call] = Endpoint
		Owners[Call] = Player :: Player
		Deadlines[Call] = os.clock() + Constants.Timeout
		Waiting += 1

		return coroutine.yield()
	end

	-- Stops waiting for a call and hands back who was.
	local function take(Call: number): (thread, Endpoint)
		local Thread, Endpoint = Threads[Call], Asked[Call]

		Threads[Call], Asked[Call], Owners[Call], Deadlines[Call] = nil, nil, nil, nil
		Waiting -= 1

		return Thread, Endpoint
	end

	--// Inbound //--

	-- Handlers run on a parked thread, reused whenever the last one did not yield.
	local function run(Callback: (...any) -> (), ...: any): ()
		local Thread = Idle
		Idle = nil
		Callback(...)
		Idle = Thread
	end

	local function runner(): ()
		while true do
			run(coroutine.yield())
		end
	end

	local function spawn(Callback: (...any) -> (), ...: any): ()
		if not Idle then
			Idle = coroutine.create(runner)
			coroutine.resume(Idle :: thread)
		end

		task.spawn(Idle :: thread, Callback, ...)
	end

	-- Gives the client its handler slot back and passes the results through.
	local function done(Player: Player?, ...: any): ...any
		if Player then
			Guard.Leave(Player)
		end

		return ...
	end

	-- Decoded comes straight from pcall: the arguments follow it.
	local function finish(Endpoint: Endpoint, Header: any, Player: Player?, Call: number?, Decoded: boolean, ...: any): ()
		if not Decoded or (Endpoint.Arity < math.huge and select("#", ...) > Endpoint.Arity) or (Player and not Guard.Sane(Player, ...)) then
			if Player then
				Guard.Strike(Player, "Value", Endpoint.Name)
			else
				warn(`[Bridge] {Endpoint.Name} could not be read`)
			end

			if Call then
				answer(Endpoint, Player, Call, false)
			end
			return
		end

		-- a client already running its share of handlers gets no more
		if Player and not Guard.Enter(Player) then
			if Call then
				answer(Endpoint, Player, Call, false)
			end
			return
		end

		if Transport.Debug then
			print(`[Bridge] <- {Endpoint.Name}`)
		end

		local Handler = Endpoint.Handler :: (...any) -> ...any

		if Call then
			answer(Endpoint, Player, Call, done(Player, xpcall(Handler, debug.traceback, Header, ...)))
		else
			local Fine, Message = done(Player, xpcall(Handler, debug.traceback, Header, ...))
			if not Fine then
				warn(`[Bridge] {Endpoint.Name} failed: {Message}`)
			end
		end
	end

	local function execute(Endpoint: Endpoint, Header: any, Player: Player?, Packet: buffer, Offset: number, Length: number): ()
		local Call: number? = nil

		if Endpoint.Returns then
			if Length < 2 then
				if Player then
					Guard.Strike(Player, "Frame", Endpoint.Name)
				end
				return
			end

			Call = buffer.readu16(Packet, Offset)
			Offset += 2
			Length -= 2
		end

		finish(Endpoint, Header, Player, Call, pcall(Endpoint.Args.DebufferizeFrom, Endpoint.Args, Packet, Offset, Length))
	end

	-- What a client answers is as untrusted as what it asks.
	local function resume(Thread: thread, Player: Player?, Decoded: boolean, ...: any): ()
		if Decoded and (not Player or Guard.Sane(Player, ...)) then
			task.spawn(Thread, ...)
			return
		end

		if Player then
			Guard.Strike(Player, "Value", "answer")
		end

		task.spawn(Thread)
	end

	-- An answer nobody waits for (late, or forged) is dropped without a word.
	local function resolve(Packet: buffer, Offset: number, Length: number, Player: Player?): ()
		if Length < 3 then
			return
		end

		local Call = buffer.readu16(Packet, Offset)

		if not Threads[Call] or Owners[Call] ~= Player then
			return
		end

		local Thread, Endpoint = take(Call)

		if buffer.readu8(Packet, Offset + 2) == 1 then
			local Results = Endpoint.Results
			resume(Thread, Player, pcall(Results.DebufferizeFrom, Results, Packet, Offset + 3, Length - 3))
		else
			task.spawn(Thread)
		end
	end

	local function hold(Id: number, Packet: buffer, Offset: number, Length: number): ()
		local Frames = Held[Id]

		if not Frames then
			Frames = {}
			Held[Id] = Frames
		end

		if #Frames < Limit.Held then
			local Frame = buffer.create(Length)
			buffer.copy(Frame, 0, Packet, Offset, Length)
			table.insert(Frames, Frame)
		end
	end

	-- Walks the frames of a packet. Player is nil on the client, where the sender is trusted.
	local function receive(Packet: buffer, Offset: number, Header: any, Player: Player?): ()
		local Size = buffer.len(Packet)

		while Offset < Size do
			local Length, Start = Wire.ReadVarInt(Packet, Offset, Size)

			if not Length or Length < 4 or Start + Length > Size then
				if Player then
					Guard.Strike(Player, "Frame")
				end
				return
			end

			Offset = Start + Length

			local Id = buffer.readu32(Packet, Start)
			local Endpoint = Endpoints[Id]

			if Player and not Guard.Allow(Player, Id, if Endpoint then Endpoint.Rate else Rate.Calls) then
				continue -- over this client's budget: dropped unread
			elseif Id == ANSWER then
				resolve(Packet, Start + 4, Length - 4, Player)
			elseif Endpoint and Endpoint.Handler then
				spawn(execute, Endpoint, Header, Player, Packet, Start + 4, Length - 4)
			elseif IsClient then
				hold(Id, Packet, Start, Length)
			elseif IsStudio then
				warn(`[Bridge] nothing listens to '{if Endpoint then Endpoint.Name else Id}' on the server`)
			end
		end
	end

	if IsClient then
		for _, Remote in Remotes do
			Remote.OnClientEvent:Connect(function(Packet: buffer)
				receive(Packet, 0, ClientHeader, nil)
			end)
		end
	else
		for Lane, Remote in Remotes do
			Remote.OnServerEvent:Connect(function(Player: Player, Packet: any)
				local Pair = Down[Player] or join(Player)

				if not Pair or not Guard.Open(Player, Packet, Lane) then
					return
				end

				-- its first packet is the client saying it is ready
				local Main = Pair[RELIABLE]
				if Main.Parked then
					Main.Parked = false
					Pair[UNRELIABLE].Parked = false
					flush(Main)
				end

				receive(Packet, SEAL, Pair[3], Player)
			end)
		end

		Players.PlayerRemoving:Connect(function(Player: Player)
			Down[Player] = nil
			Guard.Forget(Player)

			for Call, Owner in Owners do
				if Owner == Player then
					task.defer((take(Call)))
				end
			end
		end)
	end

	--// Public //--
	function Transport.Register(Name: string, Reliable: boolean, Returns: boolean, Args: any?, Results: any?): Endpoint
		local Id = Wire.Hash(Name)
		local Found = Endpoints[Id]

		if Found then
			assert(Found.Name == Name, `[Bridge] '{Name}' and '{Found.Name}' share an id: rename one`)
			return Found
		end

		local Endpoint: Endpoint = {
			Id = Id,
			Name = Name,
			Lane = if Reliable then RELIABLE else UNRELIABLE,
			Returns = Returns,
			Args = Args or Dynamic,
			Results = Results or Dynamic,
			Arity = math.huge,
			Rate = if Returns then Rate.Requests else Rate.Calls,
			Handler = nil,
		}

		Endpoints[Id] = Endpoint
		return Endpoint
	end

	-- A call keeps its last handler; an event stacks them, like connections.
	function Transport.Listen(Endpoint: Endpoint, Handler: (...any) -> ...any): ()
		local Former = Endpoint.Handler

		if Former and not Endpoint.Returns then
			Endpoint.Handler = function(...)
				task.spawn(Former, ...)
				Handler(...)
			end
		else
			Endpoint.Handler = Handler
		end

		local Frames = Held[Endpoint.Id]
		if Frames then
			Held[Endpoint.Id] = nil

			for _, Frame in Frames do
				spawn(execute, Endpoint, ClientHeader, nil, Frame, 4, buffer.len(Frame) - 4)
			end
		end
	end

	function Transport.Flush(): ()
		if not Opened or #Dirty == 0 then
			return
		end

		for Index = 1, #Dirty do
			flush(Dirty[Index])
		end

		table.clear(Dirty)
	end

	-- Client: every handler is wired, the server may start sending.
	function Transport.Open(): ()
		if Opened then
			return
		end

		Opened = true

		local Hello = Wire.Take(Up[RELIABLE])
		Guard.Seal(Hello, RELIABLE)
		Remotes[RELIABLE]:FireServer(Hello)
	end

	if IsClient then
		function Transport.Send(Endpoint: Endpoint, ...: any): ()
			push(Up[Endpoint.Lane], encode(Endpoint, nil, ...))
		end

		function Transport.Call(Endpoint: Endpoint, ...: any): ...any
			return ask(Endpoint, Up[RELIABLE], nil, ...)
		end
	else
		function Transport.Send(Endpoint: Endpoint, Target: any, ...: any): ()
			if typeof(Target) == "Instance" then
				local Pair = Down[Target] or join(Target)

				if Pair then
					push(Pair[Endpoint.Lane], encode(Endpoint, nil, ...))
				end
				return
			elseif type(Target) ~= "table" then
				warn(debug.traceback(`[Bridge] {Endpoint.Name}: the target must be a Player or a list of Players`, 2))
				return
			end

			-- encoded once, copied to each player
			local Length = encode(Endpoint, nil, ...)
			local Lane = Endpoint.Lane

			for _, Player in Target do
				local Pair = Down[Player] or join(Player)

				if Pair then
					push(Pair[Lane], Length)
				end
			end
		end

		-- A list of players answers with { [Player] = first result }.
		function Transport.Call(Endpoint: Endpoint, Target: any, ...: any): ...any
			if typeof(Target) == "Instance" then
				local Pair = Down[Target] or join(Target)

				if not Pair then
					return nil
				end

				return ask(Endpoint, Pair[RELIABLE], Target, ...)
			elseif type(Target) ~= "table" then
				warn(debug.traceback(`[Bridge] {Endpoint.Name}: the target must be a Player or a list of Players`, 2))
				return nil
			end

			local Answers, Pending, Thread = {}, 0, coroutine.running()

			for _, Player in Target do
				local Pair = Down[Player] or join(Player)
				if not Pair then continue end

				Pending += 1

				task.spawn(function(...)
					Answers[Player] = ask(Endpoint, Pair[RELIABLE], Player, ...)
					Pending -= 1

					if Pending == 0 and coroutine.status(Thread) == "suspended" then
						task.spawn(Thread)
					end
				end, ...)
			end

			if Pending > 0 then
				coroutine.yield()
			end

			return Answers
		end
	end

	RunService.Heartbeat:Connect(function()
		Transport.Flush()

		if Waiting == 0 then
			return
		end

		-- an answer that never came: checked four times a second, that is precise enough
		local Now = os.clock()
		if Now < NextSweep then
			return
		end

		NextSweep = Now + 0.25

		for Call, Until in Deadlines do
			if Now >= Until then
				task.defer((take(Call)))
			end
		end
	end)

	return Transport
end
