--!native
--!optimize 2

--[[
    © 2026 Nodeal Official Package. All rights reserved.

    This source code is open-source and free for modification and use in your projects.
    However, you may not sell, sublicense, or distribute this framework (or 
    any rebranded version of it) as a standalone product.

    Any public use or redistribution of this module requires this header 
    to remain intact in the source code. For the complete license terms, 
    please visit: https://www.nodeal.dev/license
]]

local __=_G() local BridgeService = {}

--// Services //--
local SignalService = game:GetService("SignalService")
local BufferizeService = game:GetService("BufferizeService")

--// Modules //--
local Constants = require(script.BridgeConstants)
local Wire = require(script.BridgeWire)
local Guard = require(script.BridgeGuard)(Constants, Wire)
local Transport = require(script.BridgeTransport)(Constants, Wire, Guard, BufferizeService.new())
local Channel = require(script.BridgeChannel)(Transport, BufferizeService)

--// Types //--
export type Header = { Player: Player? }

export type Record = {
	Name: string,
	Method: string,
	Modules: { string },
	Services: { string },
	Colon: boolean,
	Header: boolean,
	Endpoint: any,
}

--// Private //--
local Channels: { [string]: any } = {}
local Records: { [string]: Record } = {}
local Stubs: { [string]: any } = {}
local Exposed: { [any]: { [string]: any } } = {}

-- One collected @expose usage: { modules, services, method, access, exports, reliable }.
local function record(Entry: any): Record
	local Modules, Services = Entry[1] or {}, Entry[2] or {}
	local Colon = Entry[4] == ":"
	local Exports = Entry[5] or {}
	local Parameters = Exports.arguments or {}

	local First = if Colon and Parameters[1] and Parameters[1].name == "self" then 2 else 1
	local Header = Parameters[First] ~= nil and string.lower(Parameters[First].name or "") == "header"

	local Schemas, Arity = {}, 0
	for Index = if Header then First + 1 else First, #Parameters do
		if Parameters[Index].name == "..." then
			Arity = math.huge
		else
			table.insert(Schemas, BufferizeService:GetSchemaFromAST(Parameters[Index].type))
		end
	end

	local Results = nil
	local Returns = Exports.returns
	if Returns and Returns.name ~= "void" then
		local Types = if Returns.kind == "tuple" then Returns.types or {} else { Returns }
		if #Types > 0 then
			local Outputs = table.create(#Types)
			for Index, Type in Types do
				Outputs[Index] = BufferizeService:GetSchemaFromAST(Type)
			end
			Results = BufferizeService.new(table.unpack(Outputs))
		end
	end

	local Name = `{Services[1] or Modules[1]}.{Entry[3]}`
	local Endpoint = Transport.Register(Name, Entry[6] ~= false, Results ~= nil, BufferizeService.new(table.unpack(Schemas)), Results)
	Endpoint.Arity = math.max(Arity, #Schemas)

	return {
		Name = Name,
		Method = Entry[3],
		Modules = Modules,
		Services = Services,
		Colon = Colon,
		Header = Header,
		Endpoint = Endpoint,
	}
end

-- What the other side calls: a method with a return type waits for its answer.
local function caller(Record: Record): (...any) -> ...any
	local Endpoint = Record.Endpoint
	local Route = if Endpoint.Returns then Transport.Call else Transport.Send

	if Record.Colon then
		return function(_, ...)
			return Route(Endpoint, ...)
		end
	end

	return function(...)
		return Route(Endpoint, ...)
	end
end

-- Adapts the real method to the (Header, ...) shape the transport calls.
local function handler(Record: Record, Owner: any, Method: (...any) -> ...any): (...any) -> ...any
	if Record.Colon then
		if Record.Header then
			return function(Header, ...)
				return Method(Owner, Header, ...)
			end
		end

		return function(_, ...)
			return Method(Owner, ...)
		end
	elseif Record.Header then
		return Method
	end

	return function(_, ...)
		return Method(...)
	end
end

-- The table standing in for a module or service that lives on the other side.
local function stub(Name: string, Service: boolean): any
	local Key = (if Service then "S:" else "M:") .. Name
	local Stub = Stubs[Key]

	if not Stub then
		Stub = {}
		Stubs[Key] = Stub

		if Service then
			game:RegisterService(Name, Stub)
		else
			game:RegisterModule(Name, Stub)
		end
	end

	return Stub
end

local function isLocal(Record: Record): boolean
	for _, Name in Record.Modules do
		if game:HasModule(Name) and not Stubs["M:" .. Name] then
			return true
		end
	end

	return false
end

-- Wires the local method to its endpoint, or routes it when this side had it stripped.
local function bind(Record: Record): ()
	for _, Name in Record.Modules do
		if not game:HasModule(Name, true) then continue end

		local Owner = game:GetModule(Name)
		local Method = (Exposed[Owner] and Exposed[Owner][Record.Method]) or Owner[Record.Method]

		if type(Method) == "function" then
			Transport.Listen(Record.Endpoint, handler(Record, Owner, Method))
			return
		end

		local Call = caller(Record)
		Owner[Record.Method] = Call

		for _, ServiceName in Record.Services do
			local Service = game:HasService(ServiceName) and game:GetService(ServiceName)
			if type(Service) == "table" and Service[Record.Method] == nil then
				Service[Record.Method] = Call
			end
		end

		return
	end
end

--// Decorators //--

--[=[
    @collect
    @export usages arguments:advanced returns:advanced
    @context *
]=]
game:RegisterDecorator("expose", function(Context, Wrapped: (...any) -> ...any)
	local Owner = Context.Instance.Content

	Exposed[Owner] = Exposed[Owner] or {}
	Exposed[Owner][Context.Method] = Wrapped

	-- local calls skip the decorators nested under @expose
	return Context.OriginalFunction
end)

game:RegisterDecorator("OnEvent", function(_, Callback: (Header, ...any) -> (), Name: string)
	BridgeService:GetNetwork(Name):OnEvent(Callback)
	return Callback
end)

game:RegisterDecorator("OnEmit", function(_, Callback: (Header, ...any) -> (), Name: string)
	BridgeService:GetNetwork(Name):OnEmit(Callback)
	return Callback
end)

game:RegisterDecorator("OnInvoke", function(_, Callback: (Header, ...any) -> ...any, Name: string)
	BridgeService:GetNetwork(Name):OnInvoke(Callback)
	return Callback
end)

--// Public //--

-- Fires (Player, Reason, Detail?) each time a client breaks the protocol: the place to log or ban.
BridgeService.Violated = SignalService.new()

--[=[
	A named channel: Fire / Emit / Invoke one way, OnEvent / OnEmit / OnInvoke the other.
	The server passes its target (a Player or a list) first.
]=]
function BridgeService:GetNetwork(Name: string): any
	local Network = Channels[Name]

	if not Network then
		Network = Channel.new(Name)
		Channels[Name] = Network
	end

	return Network
end

BridgeService.RegisterNetwork = BridgeService.GetNetwork

--[=[
	The record of an exposed method, by "Target.Method".
]=]
function BridgeService:GetRecord(Name: string): Record?
	return Records[Name]
end

function BridgeService:IsExposed(Name: string): boolean
	return Records[Name] ~= nil
end

--[=[
	The clock both sides agree on.
]=]
function BridgeService:GetSyncedTime(): number
	return workspace:GetServerTimeNow()
end

--[=[
	Sends what is queued now instead of at the end of the frame.
]=]
function BridgeService:Flush(): ()
	Transport.Flush()
end

function BridgeService:SetDebug(Enabled: boolean): ()
	Transport.Debug = Enabled
end

--[=[
	@hidden
	Called by the loader when it detects tampering: this client's packets stop being accepted.
]=]
function BridgeService:IncrementOffset(Increment: number): ()
	Guard.Poison(Increment)
end

--// BridgeService //--

--[=[
	@hidden
]=]
function BridgeService.Build(): ()
	Guard.Report = function(Player: Player, Reason: string, Detail: string?)
		BridgeService.Violated:Fire(Player, Reason, Detail)
	end

	for _, Entry in script:GetCollected("expose") do
		local Record = record(Entry)
		Records[Record.Name] = Record

		if isLocal(Record) then continue end

		for _, Name in Record.Services do
			stub(Name, true)[Record.Method] = caller(Record)
		end

		for _, Name in Record.Modules do
			stub(Name, false)[Record.Method] = caller(Record)
		end
	end
end

--[=[
	@hidden
]=]
function BridgeService.Init(): ()
	for _, Record in Records do
		if isLocal(Record) then
			bind(Record)
		end
	end

	-- deferred: every Init has run before the first packet is handled
	task.defer(Transport.Open)
end

game:RegisterService("BridgeService", BridgeService)
game:RegisterService("NetworkService", BridgeService) -- former name, same service

--[=[
	Client-server bridge: exposed methods called across the network, and named channels.
]=]
return __(BridgeService)
