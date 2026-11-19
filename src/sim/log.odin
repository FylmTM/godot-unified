// Input log (the replay file): "UNIL", version u16, seed u64, content hash u64 (the level, 0: none), compat u64
// (compat_of of the build that recorded it, 0: unknown), players u8, input size u16, tick count u32 (0 with ticks after it: a recording that never ended, read to its
// last whole tick), then per tick (write_tick, also the netcode's finalized tick):
// present u32, replaced u32, players × the input's bytes (plain data, so its memory is its little-endian
// serialization), command count u8, then per command: slot u8, kind u8, size u8, the struct's bytes; then the join
// record count u8, then per record (in slot order): slot u8, member u16.
package sim

@(require) import "base:intrinsics" // only in a where clause

import "unified:wire"

@(private)
LOG_MAGIC :: "UNIL"
// Bump on any change to what the bytes hold.
LOG_VERSION :: 7
LOG_HEADER :: 37
@(private)
LOG_TICKS_AT :: 33 // the header's tick count
COMMAND_HEAD :: 3 // slot, kind, size: a command's bytes on the wire and in the log, before its data
JOIN_BYTES :: 3 // slot u8, member u16: a join record's bytes on the wire and in the log

// A tick of the log, compact: its commands live in Input_Log.commands.
@(private)
Log_Tick :: struct($G: typeid) {
	present:       Slots,
	replaced:      Slots,
	input:         [part(G, GAME_PLAYERS)]part(G, GAME_INPUT),
	joins:         [part(G, GAME_PLAYERS)]u16, // join records
	first_command: u32, // index into Input_Log.commands
	command_count: u32,
}

// A recorded session's inputs in memory, tick by tick (log_append, log_inputs; log_encode and log_decode go to and
// from the file's bytes). With the seed and the content it is the whole session.
Input_Log :: struct($G: typeid) where intrinsics.type_is_specialization_of(G, Game) {
	seed:     u64,
	content:  u64, // content_hash of the session's content (0: none)
	compat:   u64, // compat_of of the build that recorded it (0: unknown, e.g. a relay that accepts any build)
	ticks:    [dynamic]Log_Tick(G), // ticks[k] holds tick k + 1
	commands: [dynamic]Raw_Command, // every tick's commands, in tick order
}

// Frees the log's ticks and commands and leaves it empty, ready to append to again.
log_destroy :: proc(input_log: ^Input_Log($G)) {
	delete(input_log.ticks)
	delete(input_log.commands)
	input_log.ticks = nil
	input_log.commands = nil
}

// Appends a tick's inputs (the next tick).
log_append :: proc(input_log: ^Input_Log($G), inputs: ^Inputs(G)) {
	append(&input_log.ticks, Log_Tick(G) {
		present       = inputs.present,
		replaced      = inputs.replaced,
		input         = inputs.input,
		joins         = inputs.joins,
		first_command = u32(len(input_log.commands)),
		command_count = u32(inputs.command_count),
	})
	append(&input_log.commands, ..inputs.commands[:inputs.command_count])
}

// The commands of the log's tick k + 1.
log_commands :: proc(input_log: ^Input_Log($G), k: int) -> []Raw_Command {
	log_tick := &input_log.ticks[k]
	return input_log.commands[log_tick.first_command:][:log_tick.command_count]
}

// The inputs of the log's tick k + 1, ready for sim.step.
log_inputs :: proc(input_log: ^Input_Log($G), k: int) -> (inputs: Inputs(G)) {
	log_tick := &input_log.ticks[k]
	inputs.present = log_tick.present
	inputs.replaced = log_tick.replaced
	inputs.input = log_tick.input
	inputs.joins = log_tick.joins
	commands := log_commands(input_log, k)
	inputs.command_count = len(commands)
	copy(inputs.commands[:], commands)
	return
}

// The bytes of a tick's record (write_tick) with these commands and `joins` join records, for sizing datagrams.
@(private)
tick_bytes :: proc($Input: typeid, $PLAYERS: int, commands: []Raw_Command, joins := 0) -> int {
	size := 10 + PLAYERS * size_of(Input) + joins * JOIN_BYTES
	for &command in commands {
		size += COMMAND_HEAD + int(command.size)
	}
	return size
}

// The join records of a tick: its slots with a non-zero member.
join_count :: proc(member: []u16) -> (count: int) {
	for id in member do count += int(id != 0)
	return
}

// Writes a tick's record: present, replaced, the inputs, the commands, then the join records (`member`, by slot:
// the non-zero ones).
write_tick :: proc(
	writer: ^wire.Writer,
	present, replaced: Slots,
	input: []u8,
	commands: []Raw_Command,
	member: []u16,
) {
	wire.w_u32(writer, transmute(u32)present)
	wire.w_u32(writer, transmute(u32)replaced)
	wire.w_bytes(writer, input)
	write_commands(writer, commands)
	write_joins(writer, member)
}

// Writes a tick's commands as write_tick does: the count, then per command slot, kind, size and its bytes.
write_commands :: proc(writer: ^wire.Writer, commands: []Raw_Command) {
	wire.w_u8(writer, u8(len(commands)))
	for &command in commands {
		wire.w_u8(writer, command.slot)
		wire.w_u8(writer, command.kind)
		wire.w_u8(writer, command.size)
		wire.w_bytes(writer, command.data[:command.size])
	}
}

// Writes a tick's join records as write_tick does: the count, then per record (in slot order) slot u8, member u16.
write_joins :: proc(writer: ^wire.Writer, member: []u16) {
	wire.w_u8(writer, u8(join_count(member)))
	for id, slot in member {
		if id != 0 {
			wire.w_u8(writer, u8(slot))
			wire.w_u16(writer, id)
		}
	}
}

// Reads a tick's record into `input`, `commands` and `member` (one per slot); false when it is malformed: cut short,
// a slot past the session's (len(member)) present or replaced, or its commands (read_commands) or join records
// (read_joins) malformed.
@(private)
read_tick :: proc(
	reader: ^wire.Reader,
	input: []u8,
	commands: ^[TICK_COMMANDS]Raw_Command,
	member: []u16,
) -> (
	present, replaced: Slots,
	count: int,
	ok: bool,
) {
	present = transmute(Slots)wire.r_u32(reader)
	replaced = transmute(Slots)wire.r_u32(reader)
	outside := ~u32(0) << uint(len(member)) // Odin: a shift by the width or more is 0 (all 32 slots)
	if (transmute(u32)present | transmute(u32)replaced) & outside != 0 {
		return
	}
	copy(input, wire.r_bytes(reader, len(input)))
	count, ok = read_commands(reader, len(member), commands)
	ok = ok && read_joins(reader, present, member)
	return present, replaced, count, ok && reader.ok
}

// Reads a tick's commands written by write_commands; false when they are malformed: cut short, more than
// TICK_COMMANDS commands or COMMANDS_PER_SLOT of one slot, a slot out of range or out of order, a command over
// COMMAND_MAX bytes. Command kinds are not checked here (command_value reads an unknown kind as nil).
read_commands :: proc(
	reader: ^wire.Reader,
	players: int,
	commands: ^[TICK_COMMANDS]Raw_Command,
) -> (
	count: int,
	ok: bool,
) {
	count = int(wire.r_u8(reader))
	if !reader.ok || count > TICK_COMMANDS {
		return
	}
	per_slot := 0
	for i in 0 ..< count {
		command := &commands[i]
		command^ = {}
		command.slot = wire.r_u8(reader)
		command.kind = wire.r_u8(reader)
		command.size = wire.r_u8(reader)
		if int(command.slot) >= players || int(command.size) > COMMAND_MAX {
			return
		}
		copy(command.data[:], wire.r_bytes(reader, int(command.size)))
		per_slot = i > 0 && commands[i - 1].slot == command.slot ? per_slot + 1 : 1
		if !reader.ok || (i > 0 && commands[i - 1].slot > command.slot) || per_slot > COMMANDS_PER_SLOT {
			return
		}
	}
	return count, true
}

// Reads a tick's join records written by write_joins into `member` (by slot, zeroed first); false when they are
// malformed: cut short, a slot out of range, out of order or not present, member 0, or a member in two records.
read_joins :: proc(reader: ^wire.Reader, present: Slots, member: []u16) -> bool {
	for &id in member do id = 0
	joins := int(wire.r_u8(reader))
	last := -1
	for _ in 0 ..< joins {
		slot := int(wire.r_u8(reader))
		id := wire.r_u16(reader)
		if !reader.ok || slot <= last || slot >= len(member) || slot not_in present || id == 0 {
			return false
		}
		for other in member[:slot] {
			if other == id do return false // one person in two slots: the relay never writes it (players_update can't take it)
		}
		member[slot] = id
		last = slot
	}
	return reader.ok
}

// Writes a tick's inputs as write_tick does.
inputs_write :: proc(writer: ^wire.Writer, inputs: ^Inputs($G)) {
	Input :: part(G, GAME_INPUT)
	PLAYERS :: part(G, GAME_PLAYERS)
	write_tick(
		writer,
		inputs.present,
		inputs.replaced,
		([^]u8)(&inputs.input)[:size_of([PLAYERS]Input)],
		inputs.commands[:inputs.command_count],
		inputs.joins[:],
	)
}

// Reads a tick's inputs written by inputs_write (or log_write_tick).
inputs_read :: proc(reader: ^wire.Reader, inputs: ^Inputs($G)) -> bool {
	Input :: part(G, GAME_INPUT)
	PLAYERS :: part(G, GAME_PLAYERS)
	inputs^ = {}
	input := ([^]u8)(&inputs.input)[:size_of([PLAYERS]Input)]
	present, replaced, count, ok := read_tick(reader, input, &inputs.commands, inputs.joins[:])
	inputs.present, inputs.replaced, inputs.command_count = present, replaced, count
	return ok
}

// Writes the log's tick k + 1 as write_tick does.
@(private)
log_write_tick :: proc(writer: ^wire.Writer, input_log: ^Input_Log($G), k: int) {
	Input :: part(G, GAME_INPUT)
	PLAYERS :: part(G, GAME_PLAYERS)
	log_tick := &input_log.ticks[k]
	input := ([^]u8)(&log_tick.input)[:size_of([PLAYERS]Input)]
	write_tick(writer, log_tick.present, log_tick.replaced, input, log_commands(input_log, k), log_tick.joins[:])
}

// The log's bytes: the header, then the ticks.
log_encode :: proc(input_log: ^Input_Log($G), allocator := context.allocator) -> []u8 {
	Input :: part(G, GAME_INPUT)
	PLAYERS :: part(G, GAME_PLAYERS)
	size_hint :=
		LOG_HEADER +
		len(input_log.ticks) * tick_bytes(Input, PLAYERS, nil) +
		len(input_log.commands) * (COMMAND_HEAD + 8)
	writer := wire.writer_make(size_hint, allocator)
	header := Log_Header {
		seed       = input_log.seed,
		content    = input_log.content,
		compat     = input_log.compat,
		players    = PLAYERS,
		input_size = size_of(Input),
		ticks      = len(input_log.ticks),
	}
	write_log_header(&writer, header)
	for k in 0 ..< len(input_log.ticks) {
		log_write_tick(&writer, input_log, k)
	}
	return writer.buf[:]
}

// Parses log_encode's bytes into an Input_Log of game G; false when the header does not match G's Input and
// PLAYERS or the bytes are malformed. A recording that never ended (tick count 0) is read to its last whole tick (a
// cut one after it is left out).
log_decode :: proc(data: []u8, $G: typeid) -> (input_log: Input_Log(G), ok: bool) {
	Input :: part(G, GAME_INPUT)
	PLAYERS :: part(G, GAME_PLAYERS)
	header, body := decode_log(data) or_return
	if header.players != PLAYERS ||
	   header.input_size != size_of(Input) ||
	   len(body) < header.ticks * tick_bytes(Input, PLAYERS, nil) {
		return
	}
	input_log.seed = header.seed
	input_log.content = header.content
	input_log.compat = header.compat
	input_log.ticks = make([dynamic]Log_Tick(G), 0, header.ticks)
	reader := wire.reader_make(body)
	inputs: Inputs(G)
	// A recording whose writer never patched the count (it stopped without ending): every whole tick to the end. Its
	// last tick may be cut (a torn write, a copy of a growing file): the ticks before it are the recording.
	unended := header.ticks == 0
	for k := 0; unended ? wire.r_remaining(&reader) > 0 : k < header.ticks; k += 1 {
		if !inputs_read(&reader, &inputs) {
			if unended do return input_log, true
			log_destroy(&input_log)
			return {}, false
		}
		log_append(&input_log, &inputs)
	}
	if wire.r_remaining(&reader) != 0 {
		log_destroy(&input_log)
		return {}, false
	}
	return input_log, true
}

// Where a log goes as it grows (a relay's recording, src/netcode/README.md): `write` puts bytes at an offset (the
// end, to append; the header's tick count, when it ends), `close` (optional) ends it. log_sink_memory here,
// headless.log_sink_file for a file.
Log_Sink :: struct {
	user:  rawptr,
	write: proc(user: rawptr, offset: int, bytes: []u8) -> bool,
	close: proc(user: rawptr),
}

// A sink into `buf` (the caller owns it): log_decode reads the bytes back.
log_sink_memory :: proc(buf: ^[dynamic]u8) -> Log_Sink {
	return {
		user = buf,
		write = proc(user: rawptr, offset: int, bytes: []u8) -> bool {
			buf := (^[dynamic]u8)(user)
			if offset + len(bytes) > len(buf) {
				resize(buf, offset + len(bytes))
			}
			copy(buf[offset:], bytes)
			return true
		},
	}
}


// A log being written to a sink tick by tick: log_stream_begin writes the header (tick count 0), log_stream_tick
// each tick, log_stream_end the count, then closes the sink.
Log_Stream :: struct {
	sink:   Log_Sink,
	size:   int, // bytes written so far
	ticks:  int,
	ok:     bool, // every write succeeded
	writer: wire.Writer,
}

// Starts a recording into `sink` with the header's tick count 0, so a recording cut short still reads to its
// end. A sink without `write` means no recording: the stream's other procs then do nothing.
log_stream_begin :: proc(stream: ^Log_Stream, sink: Log_Sink, header: Log_Header) {
	if sink.write == nil {
		stream^ = {} // no recording
		return
	}
	stream^ = {
		sink   = sink,
		ok     = true,
		writer = wire.writer_make(LOG_HEADER),
	}
	unended := header
	unended.ticks = 0
	write_log_header(&stream.writer, unended)
	log_stream_put(stream)
}

@(private)
log_stream_put :: proc(stream: ^Log_Stream) {
	stream.ok &&= stream.sink.write(stream.sink.user, stream.size, stream.writer.buf[:])
	stream.size += len(stream.writer.buf)
	clear(&stream.writer.buf)
}

// Appends one tick's inputs to the recording (the relay calls it for each finalized tick).
log_stream_tick :: proc(stream: ^Log_Stream, inputs: ^Inputs($G)) {
	if stream.sink.write == nil {
		return
	}
	inputs_write(&stream.writer, inputs)
	log_stream_put(stream)
	stream.ticks += 1
}

// Patches the tick count, closes the sink; false if a write failed.
log_stream_end :: proc(stream: ^Log_Stream) -> bool {
	if stream.sink.write == nil {
		return true
	}
	count := transmute([4]u8)u32le(u32(stream.ticks))
	stream.ok &&= stream.sink.write(stream.sink.user, LOG_TICKS_AT, count[:])
	if stream.sink.close != nil {
		stream.sink.close(stream.sink.user)
	}
	delete(stream.writer.buf)
	ok := stream.ok
	stream^ = {}
	return ok
}

// What an input log's header says (log_stream_begin writes one; its `ticks` is ignored there).
Log_Header :: struct {
	seed:       u64,
	content:    u64,
	compat:     u64, // compat_of of the recording build (0: unknown)
	players:    int,
	input_size: int,
	ticks:      int,
}

// Writes the log header (LOG_HEADER bytes, the tick count at LOG_TICKS_AT), for log_encode and log streams.
@(private)
write_log_header :: proc(writer: ^wire.Writer, header: Log_Header) {
	wire.w_bytes(writer, transmute([]u8)string(LOG_MAGIC))
	wire.w_u16(writer, LOG_VERSION)
	wire.w_u64(writer, header.seed)
	wire.w_u64(writer, header.content)
	wire.w_u64(writer, header.compat)
	wire.w_u8(writer, u8(header.players))
	wire.w_u16(writer, u16(header.input_size))
	wire.w_u32(writer, u32(header.ticks))
}

// The header and the tick bytes (a view into data).
@(private)
decode_log :: proc(data: []u8) -> (header: Log_Header, body: []u8, ok: bool) {
	reader := wire.reader_make(data)
	magic := wire.r_bytes(&reader, 4)
	version := wire.r_u16(&reader)
	header.seed = wire.r_u64(&reader)
	header.content = wire.r_u64(&reader)
	header.compat = wire.r_u64(&reader)
	header.players = int(wire.r_u8(&reader))
	header.input_size = int(wire.r_u16(&reader))
	header.ticks = int(wire.r_u32(&reader))
	if !reader.ok || string(magic) != LOG_MAGIC || version != LOG_VERSION {
		return
	}
	return header, data[reader.pos:], true
}
