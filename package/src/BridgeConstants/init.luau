--!strict

-- Tunables of the bridge. Limit and Rate only bind what a client sends.
return table.freeze({
	Remote = table.freeze({
		Reliable = "Bridge",
		Unreliable = "BridgeUnreliable",
		Await = 15, -- seconds a client waits for them
	}),

	Timeout = 10, -- seconds a call waits for its answer

	Limit = table.freeze({
		Inbound = 16384, -- bytes in one client packet
		Unreliable = 900, -- engine cap of an unreliable packet
		Parked = 1048576, -- bytes kept for a client that is still loading
		Held = 64, -- early frames kept per endpoint on the client
		Running = 32, -- handlers one client may have in flight
		Depth = 16, -- nesting of a table a client sends
		Nodes = 4096, -- values in one call from a client
	}),

	Rate = table.freeze({
		Bytes = 32768, -- refilled per second, per player
		Burst = 65536,
		Overhead = 32, -- flat cost of a packet
		Frames = 400, -- calls per second, every endpoint together
		Calls = 120, -- per second, on an endpoint that answers nothing
		Requests = 30, -- per second, on an endpoint that answers
	}),

	Strike = table.freeze({
		Limit = 5, -- offences before the kick
		Message = "Connection lost.",
	}),

	-- Remotes left in plain sight that no game code fires: whoever does is running a scanner.
	Decoys = table.freeze({ "GiveCurrency", "AdminCommand" }),

	Seal = table.freeze({
		Salt = "nodeal-bridge", -- change it per game
		Window = 4096, -- packet numbers a client may skip
	}),
})
