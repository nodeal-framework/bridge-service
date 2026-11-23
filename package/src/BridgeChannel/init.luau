--!native
--!optimize 2

-- A named channel: three endpoints (reliable, unreliable, call) behind the former Network API.
return function(Transport: any, Bufferize: any)
	local Channel = {}
	Channel.__index = Channel

	local Send, Call, Listen = Transport.Send, Transport.Call, Transport.Listen

	function Channel.new(Name: string)
		return setmetatable({
			Name = Name,
			Event = Transport.Register(Name .. "#E", true, false),
			Stream = Transport.Register(Name .. "#U", false, false),
			Request = Transport.Register(Name .. "#I", true, true),
		}, Channel)
	end

	-- On the server the first argument is the target: a Player or a list of them.
	function Channel:Fire(...: any): ()
		Send(self.Event, ...)
	end

	-- Unreliable: may be lost or arrive late, never resent.
	function Channel:Emit(...: any): ()
		Send(self.Stream, ...)
	end

	-- Yields for the answer; nil when the other side fails or takes too long.
	function Channel:Invoke(...: any): ...any
		return Call(self.Request, ...)
	end

	function Channel:OnEvent(Callback: (...any) -> ()): ()
		Listen(self.Event, Callback)
	end

	function Channel:OnEmit(Callback: (...any) -> ()): ()
		Listen(self.Stream, Callback)
	end

	function Channel:OnInvoke(Callback: (...any) -> ...any): ()
		Listen(self.Request, Callback)
	end

	-- Types the arguments (a schema or a BufferDescriptor); nil goes back to dynamic.
	function Channel:SetInterface(Interface: any?, ...: any): ()
		local Args = Transport.Dynamic

		if Interface then
			Args = if Interface.schemas then Interface else Bufferize.new(Interface, ...)
		end

		self.Event.Args, self.Stream.Args, self.Request.Args = Args, Args, Args
	end

	return Channel
end
