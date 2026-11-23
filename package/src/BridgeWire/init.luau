--!native
--!optimize 2

-- Bytes on the wire: hashes, varints and the growable stream a packet is built in.
local Wire = {}

export type Stream = {
	Data: buffer,
	Used: number,
	Head: number,
	Cap: number,
	Queued: boolean,
	[string]: any,
}

-- Largest frame a three byte varint can announce.
Wire.MaxFrame = 4194303

-- FNV-1a on 32 bits. Never 0: that id marks an answer.
function Wire.Hash(Text: string): number
	local Hash = 2166136261

	for Index = 1, #Text do
		Hash = bit32.bxor(Hash, string.byte(Text, Index))
		Hash = (Hash * 403 + bit32.lshift(Hash, 24)) % 4294967296
	end

	return if Hash == 0 then 1 else Hash
end

-- 32 bit tag of a packet number under a key.
function Wire.Tag(Key: number, Number: number): number
	local Mixed = bit32.bxor(Key, Number * 40503)
	Mixed = (bit32.bxor(Mixed, bit32.rshift(Mixed, 13)) * 23505) % 4294967296
	Mixed = (bit32.bxor(Mixed, bit32.rshift(Mixed, 11)) * 44117) % 4294967296

	return bit32.bxor(Mixed, bit32.rshift(Mixed, 16))
end

function Wire.WriteVarInt(Data: buffer, Offset: number, Value: number): number
	if Value < 128 then
		buffer.writeu8(Data, Offset, Value)
		return Offset + 1
	elseif Value < 16384 then
		buffer.writeu8(Data, Offset, bit32.bor(bit32.band(Value, 0x7F), 0x80))
		buffer.writeu8(Data, Offset + 1, bit32.rshift(Value, 7))
		return Offset + 2
	end

	buffer.writeu8(Data, Offset, bit32.bor(bit32.band(Value, 0x7F), 0x80))
	buffer.writeu8(Data, Offset + 1, bit32.bor(bit32.band(bit32.rshift(Value, 7), 0x7F), 0x80))
	buffer.writeu8(Data, Offset + 2, bit32.rshift(Value, 14))
	return Offset + 3
end

-- Never reads past Limit: nil when the varint is cut short.
function Wire.ReadVarInt(Data: buffer, Offset: number, Limit: number): (number?, number)
	if Offset >= Limit then
		return nil, Offset
	end

	local First = buffer.readu8(Data, Offset)
	if First < 128 then
		return First, Offset + 1
	elseif Offset + 1 >= Limit then
		return nil, Offset
	end

	local Second = buffer.readu8(Data, Offset + 1)
	if Second < 128 then
		return bit32.bor(bit32.band(First, 0x7F), bit32.lshift(Second, 7)), Offset + 2
	elseif Offset + 2 >= Limit then
		return nil, Offset
	end

	local Third = buffer.readu8(Data, Offset + 2)
	return bit32.bor(bit32.band(First, 0x7F), bit32.lshift(bit32.band(Second, 0x7F), 7), bit32.lshift(Third, 14)), Offset + 3
end

-- Head bytes are left free at the start of every packet.
function Wire.Stream(Head: number, Cap: number): Stream
	return {
		Data = buffer.create(1024),
		Used = Head,
		Head = Head,
		Cap = Cap,
		Queued = false,
	}
end

-- Appends Length bytes of Frame behind their varint size.
function Wire.Push(Stream: Stream, Frame: buffer, Length: number): ()
	local Needed = Stream.Used + Length + 3

	if Needed > buffer.len(Stream.Data) then
		local Grown = buffer.create(Needed * 2)
		buffer.copy(Grown, 0, Stream.Data, 0, Stream.Used)
		Stream.Data = Grown
	end

	local Offset = Wire.WriteVarInt(Stream.Data, Stream.Used, Length)
	buffer.copy(Stream.Data, Offset, Frame, 0, Length)
	Stream.Used = Offset + Length
end

-- Hands the pending bytes over as an exact packet and empties the stream.
function Wire.Take(Stream: Stream): buffer
	local Packet = buffer.create(Stream.Used)
	buffer.copy(Packet, 0, Stream.Data, 0, Stream.Used)
	Stream.Used = Stream.Head

	-- a burst grew it: drained, it gives the memory back instead of holding it per player for good
	if buffer.len(Stream.Data) > 65536 then
		Stream.Data = buffer.create(1024)
	end

	return Packet
end

return Wire
