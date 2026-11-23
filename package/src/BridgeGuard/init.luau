--!native
--!optimize 2

-- What the server accepts from a client: a genuine and fresh packet, within budget,
-- carrying only values a client is entitled to send.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")

type State = {
	Key: number,
	Last: { number },
	Tokens: number,
	At: number,
	Second: number,
	Frames: number,
	Calls: { [number]: number },
	Running: number,
	Strikes: number,
}

local UNRELIABLE = 2

return function(Constants: any, Wire: any)
	local Guard = {}

	local IsStudio = RunService:IsStudio()
	local Rate, Limit, Seal, Strike = Constants.Rate, Constants.Limit, Constants.Seal, Constants.Strike

	-- weak: a packet that lands while its sender leaves must not keep a state for ever
	local States: { [Player]: State } = setmetatable({}, { __mode = "k" }) :: any
	local Sent = { 0, 0 }
	local Poison = 0
	local Mine: number? = nil
	local Budget = 0 -- values left to the call being checked

	-- Replaced by the service: told about every offence.
	Guard.Report = function(_Player: Player, _Reason: string, _Detail: string?) end

	-- Drawn by the server, set by the transport on both sides. Not JobId: Studio gives each side its own.
	Guard.Seed = 0

	local function key(Player: Player): number
		return Wire.Hash(`{Seal.Salt}:{Player.UserId}:{Guard.Seed}`)
	end

	local function enter(Player: Player): State
		local State: State = {
			Key = key(Player),
			Last = { 0, 0 },
			Tokens = Rate.Burst,
			At = os.clock(),
			Second = 0,
			Frames = 0,
			Calls = {},
			Running = 0,
			Strikes = 0,
		}

		States[Player] = State
		return State
	end

	-- Counts an offence and answers false; Fatal removes the player at once.
	-- Studio only warns: there it is your own bug.
	function Guard.Strike(Player: Player, Reason: string, Detail: string?, Fatal: boolean?): boolean
		local State = States[Player] or enter(Player)
		State.Strikes += 1

		Guard.Report(Player, Reason, Detail)

		if IsStudio then
			warn(`[Bridge] {Player.Name} broke the protocol: {Reason}` .. (if Detail then ` ({Detail})` else ""))
		elseif Fatal or State.Strikes >= Strike.Limit then
			Player:Kick(Strike.Message)
		end

		return false
	end

	-- Whether a client packet may be read. Frames start at byte 6.
	function Guard.Open(Player: Player, Packet: any, Lane: number): boolean
		if typeof(Packet) ~= "buffer" then
			return Guard.Strike(Player, "Type")
		end

		local Size = buffer.len(Packet)
		if Size < 6 or Size > Limit.Inbound then
			return Guard.Strike(Player, "Size")
		end

		local State = States[Player] or enter(Player)
		local Number = buffer.readu16(Packet, 0)

		if buffer.readu32(Packet, 2) ~= Wire.Tag(State.Key + Lane, Number) then
			return Guard.Strike(Player, "Seal")
		end

		local Ahead = (Number - State.Last[Lane]) % 65536
		if Ahead == 0 or Ahead > Seal.Window then
			-- unreliable packets overtake each other; a reliable one never comes twice
			if Lane == UNRELIABLE then
				return false
			end

			return Guard.Strike(Player, "Replay")
		end

		State.Last[Lane] = Number

		local Now = os.clock()
		local Second = Now // 1

		if State.Second ~= Second then
			State.Second = Second
			State.Frames = 0
			table.clear(State.Calls)
		end

		local Tokens = math.min(Rate.Burst, State.Tokens + (Now - State.At) * Rate.Bytes) - Size - Rate.Overhead
		State.At = Now

		if Tokens < -Rate.Burst then
			State.Tokens = -Rate.Burst
			return Guard.Strike(Player, "Flood")
		end

		State.Tokens = Tokens
		return Tokens >= 0
	end

	-- One call of the packet Open let in: within the client's second, and the endpoint's.
	function Guard.Allow(Player: Player, Id: number, Most: number): boolean
		local State = States[Player]
		local Frames = State.Frames + 1
		State.Frames = Frames

		if Frames > Rate.Frames then
			-- far past the limit is no accident
			if Frames == Rate.Frames * 4 then
				Guard.Strike(Player, "Spam")
			end

			return false
		end

		local Count = (State.Calls[Id] or 0) + 1
		State.Calls[Id] = Count

		return Count <= Most
	end

	-- A slot for a handler about to run; false when this client already fills its share.
	function Guard.Enter(Player: Player): boolean
		local State = States[Player]

		if not State or State.Running >= Limit.Running then
			return false
		end

		State.Running += 1
		return true
	end

	function Guard.Leave(Player: Player): ()
		local State = States[Player]

		if State then
			State.Running -= 1
		end
	end

	-- Instances travel as a path: without this a client could name what never replicates to it.
	local function visible(Value: Instance, Player: Player): boolean
		if Value:IsDescendantOf(ServerStorage) or Value:IsDescendantOf(ServerScriptService) then
			return false
		end

		-- another player's Backpack, PlayerGui, scripts
		return Value:IsA("Player") or Value:IsDescendantOf(Player) or not Value:IsDescendantOf(Players)
	end

	local function sane(Value: any, Player: Player, Depth: number): boolean
		local Kind = typeof(Value)

		if Kind == "number" then
			return Value - Value == 0 -- false for NaN and both infinities
		elseif Kind == "string" then
			return utf8.len(Value) ~= nil -- anything else breaks a DataStore save
		elseif Kind == "table" then
			if Depth >= Limit.Depth then
				return false
			end

			for Key, Item in Value do
				Budget -= 1

				if Budget < 0 or not sane(Key, Player, Depth + 1) or not sane(Item, Player, Depth + 1) then
					return false
				end
			end

			return true
		elseif Kind == "Vector3" or Kind == "Vector2" then
			return Value.Magnitude < math.huge
		elseif Kind == "CFrame" then
			return Value.Position.Magnitude < math.huge and Value.LookVector.Magnitude < 2
		elseif Kind == "Instance" then
			return visible(Value, Player)
		end

		return true
	end

	-- Whether every value a client sent is one a handler can be handed.
	function Guard.Sane(Player: Player, ...: any): boolean
		Budget = Limit.Nodes

		for Index = 1, select("#", ...) do
			if not sane((select(Index, ...)), Player, 0) then
				return false
			end
		end

		return true
	end

	-- Client: numbers and signs the packet in its first six bytes.
	function Guard.Seal(Packet: buffer, Lane: number): ()
		local Key = Mine or key(Players.LocalPlayer)
		Mine = Key

		local Number = (Sent[Lane] + 1) % 65536
		Sent[Lane] = Number

		buffer.writeu16(Packet, 0, Number)
		buffer.writeu32(Packet, 2, Wire.Tag(Key + Lane + Poison * 7919, Number))
	end

	-- A tampered client signs wrong from here on, and the server strikes it out.
	function Guard.Poison(Amount: number): ()
		Poison += Amount
	end

	function Guard.Forget(Player: Player): ()
		States[Player] = nil
	end

	return Guard
end
