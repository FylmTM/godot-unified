// Input log (the replay file): "UNIL", version u16, seed u64, content hash u64 (the level, 0: none),
// players u8, input size u16, tick count u32 (0 with ticks after it: a recording that never ended, read to the
// end), then per tick (write_tick, also the netcode's finalized tick):
// present u32, replaced u32, players × the input's bytes (plain data, so its memory is its little-endian
// serialization), command count u8, then per command: player u8, kind u8, size u8, the struct's bytes.
package sim

import "core:os"

import "unified:wire"

LOG_MAGIC :: "UNIL"
// 4: commands per tick; 5: the #6 sitting's sim (u32 handles, SplitMix64, keyed rolls), so a log recorded
// before replays differently: the bytes are laid out as in 4.
LOG_VERSION :: 5
LOG_HEADER :: 29
LOG_TICKS_AT :: 25 // the header's tick count
COMMAND_HEAD :: 3 // player, kind, size: a command's bytes on the wire and in the log, before its data

// A tick of the log, compact: its commands live in Input_Log.commands.
Log_Tick :: struct($Input: typeid, $PLAYERS: int) {
	present:       Players,
	replaced:      Players,
	input:         [PLAYERS]Input,
	first_command: u32, // index into Input_Log.commands
	command_count: u32,
}

Input_Log :: struct($Input: typeid, $PLAYERS: int) {
	seed:     u64,
	content:  u64, // content_hash of the session's content (0: none)
	ticks:    [dynamic]Log_Tick(Input, PLAYERS), // ticks[k] holds tick k + 1
	commands: [dynamic]Raw_Command, // every tick's commands, in tick order
}

log_destroy :: proc(input_log: ^Input_Log($Input, $PLAYERS)) {
	delete(input_log.ticks)
	delete(input_log.commands)
	input_log.ticks = nil
	input_log.commands = nil
}

// Appends a tick's inputs (the next tick).
log_append :: proc(input_log: ^Input_Log($Input, $PLAYERS), inputs: ^Inputs(Input, PLAYERS)) {
	append(
		&input_log.ticks,
		Log_Tick(Input, PLAYERS) {
			present = inputs.present,
			replaced = inputs.replaced,
			input = inputs.input,
			first_command = u32(len(input_log.commands)),
			command_count = u32(inputs.command_count),
		},
	)
	append(&input_log.commands, ..inputs.commands[:inputs.command_count])
}

// The commands of the log's tick k + 1.
log_commands :: proc(input_log: ^Input_Log($Input, $PLAYERS), k: int) -> []Raw_Command {
	log_tick := &input_log.ticks[k]
	return input_log.commands[log_tick.first_command:][:log_tick.command_count]
}

// The inputs of the log's tick k + 1, ready for sim.step.
log_inputs :: proc(input_log: ^Input_Log($Input, $PLAYERS), k: int) -> (inputs: Inputs(Input, PLAYERS)) {
	log_tick := &input_log.ticks[k]
	inputs.present = log_tick.present
	inputs.replaced = log_tick.replaced
	inputs.input = log_tick.input
	commands := log_commands(input_log, k)
	inputs.command_count = len(commands)
	copy(inputs.commands[:], commands)
	return
}

// The bytes of a tick's record (write_tick), for sizing datagrams.
tick_bytes :: proc($Input: typeid, $PLAYERS: int, commands: []Raw_Command) -> int {
	size := 9 + PLAYERS * size_of(Input)
	for &command in commands {
		size += COMMAND_HEAD + int(command.size)
	}
	return size
}

// Writes a tick's record: present, replaced, the inputs, then the commands.
write_tick :: proc(writer: ^wire.Writer, present, replaced: Players, input: []u8, commands: []Raw_Command) {
	wire.w_u32(writer, transmute(u32)present)
	wire.w_u32(writer, transmute(u32)replaced)
	wire.w_bytes(writer, input)
	wire.w_u8(writer, u8(len(commands)))
	for &command in commands {
		wire.w_u8(writer, command.player)
		wire.w_u8(writer, command.kind)
		wire.w_u8(writer, command.size)
		wire.w_bytes(writer, command.data[:command.size])
	}
}

// Reads a tick's record into `input` and `commands`; false when it is malformed: cut short, more than
// TICK_COMMANDS commands or COMMANDS_PER_PLAYER of one player, a player out of range or out of order, a
// command over COMMAND_MAX bytes. Command kinds are not checked here (command_value reads an unknown
// kind as nil).
read_tick :: proc(
	reader: ^wire.Reader,
	input: []u8,
	players: int,
	commands: ^[TICK_COMMANDS]Raw_Command,
) -> (
	present, replaced: Players,
	count: int,
	ok: bool,
) {
	present = transmute(Players)wire.r_u32(reader)
	replaced = transmute(Players)wire.r_u32(reader)
	copy(input, wire.r_bytes(reader, len(input)))
	count = int(wire.r_u8(reader))
	if !reader.ok || count > TICK_COMMANDS {
		return
	}
	per_player := 0
	for i in 0 ..< count {
		command := &commands[i]
		command^ = {}
		command.player = wire.r_u8(reader)
		command.kind = wire.r_u8(reader)
		command.size = wire.r_u8(reader)
		if int(command.player) >= players || int(command.size) > COMMAND_MAX {
			return
		}
		copy(command.data[:], wire.r_bytes(reader, int(command.size)))
		per_player = i > 0 && commands[i - 1].player == command.player ? per_player + 1 : 1
		if !reader.ok || (i > 0 && commands[i - 1].player > command.player) || per_player > COMMANDS_PER_PLAYER {
			return
		}
	}
	return present, replaced, count, true
}

// Writes a tick's inputs as write_tick does.
inputs_write :: proc(writer: ^wire.Writer, inputs: ^Inputs($Input, $PLAYERS)) {
	write_tick(
		writer,
		inputs.present,
		inputs.replaced,
		([^]u8)(&inputs.input)[:size_of([PLAYERS]Input)],
		inputs.commands[:inputs.command_count],
	)
}

// Reads a tick's inputs written by inputs_write (or log_write_tick).
inputs_read :: proc(reader: ^wire.Reader, inputs: ^Inputs($Input, $PLAYERS)) -> bool {
	inputs^ = {}
	input := ([^]u8)(&inputs.input)[:size_of([PLAYERS]Input)]
	present, replaced, count, ok := read_tick(reader, input, PLAYERS, &inputs.commands)
	inputs.present, inputs.replaced, inputs.command_count = present, replaced, count
	return ok
}

// Writes the log's tick k + 1 as write_tick does.
log_write_tick :: proc(writer: ^wire.Writer, input_log: ^Input_Log($Input, $PLAYERS), k: int) {
	log_tick := &input_log.ticks[k]
	input := ([^]u8)(&log_tick.input)[:size_of([PLAYERS]Input)]
	write_tick(writer, log_tick.present, log_tick.replaced, input, log_commands(input_log, k))
}

// The log's bytes: the header, then the ticks.
log_encode :: proc(input_log: ^Input_Log($Input, $PLAYERS), allocator := context.allocator) -> []u8 {
	size_hint :=
		LOG_HEADER +
		len(input_log.ticks) * tick_bytes(Input, PLAYERS, nil) +
		len(input_log.commands) * (COMMAND_HEAD + 8)
	writer := wire.writer_make(size_hint, allocator)
	header := Log_Header{input_log.seed, input_log.content, PLAYERS, size_of(Input), len(input_log.ticks)}
	write_log_header(&writer, header)
	for k in 0 ..< len(input_log.ticks) {
		log_write_tick(&writer, input_log, k)
	}
	return writer.buf[:]
}

log_decode :: proc(data: []u8, $Input: typeid, $PLAYERS: int) -> (input_log: Input_Log(Input, PLAYERS), ok: bool) {
	header, body := decode_log(data) or_return
	if header.players != PLAYERS ||
	   header.input_size != size_of(Input) ||
	   len(body) < header.ticks * tick_bytes(Input, PLAYERS, nil) {
		return
	}
	input_log.seed = header.seed
	input_log.content = header.content
	input_log.ticks = make([dynamic]Log_Tick(Input, PLAYERS), 0, header.ticks)
	reader := wire.reader_make(body)
	inputs: Inputs(Input, PLAYERS)
	// A recording whose writer never patched the count (it stopped without ending): every tick to the end.
	unended := header.ticks == 0
	for k := 0; unended ? wire.r_remaining(&reader) > 0 : k < header.ticks; k += 1 {
		if !inputs_read(&reader, &inputs) {
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

log_write :: proc(path: string, input_log: ^Input_Log($Input, $PLAYERS)) -> bool {
	data := log_encode(input_log)
	defer delete(data)
	return write_file(path, data)
}

log_read :: proc(path: string, $Input: typeid, $PLAYERS: int) -> (input_log: Input_Log(Input, PLAYERS), ok: bool) {
	data := read_file(path) or_return
	defer delete(data)
	return log_decode(data, Input, PLAYERS)
}

// Where a log goes as it grows (a relay's recording, src/netcode/SPEC.md): `write` puts bytes at an offset (the
// end, to append; the header's tick count, when it ends), `close` (optional) ends it. log_sink_memory and
// log_sink_file are the two the library has.
Log_Sink :: struct {
	user:  rawptr,
	write: proc(user: rawptr, offset: int, bytes: []u8) -> bool,
	close: proc(user: rawptr),
}

// A sink into `buf` (the caller owns it): log_decode reads the bytes back.
log_sink_memory :: proc(buf: ^[dynamic]u8) -> Log_Sink {
	return {user = buf, write = proc(user: rawptr, offset: int, bytes: []u8) -> bool {
			buf := (^[dynamic]u8)(user)
			if offset + len(bytes) > len(buf) {
				resize(buf, offset + len(bytes))
			}
			copy(buf[offset:], bytes)
			return true
		}}
}

@(private)
File_Sink :: struct {
	file:    ^os.File,
	pending: [dynamic]u8, // appended bytes not written yet, from offset `written`
	written: int,
	ok:      bool,
}

@(private)
file_sink_flush :: proc(sink: ^File_Sink) {
	if len(sink.pending) > 0 {
		_, err := os.write_at(sink.file, sink.pending[:], i64(sink.written))
		sink.ok &&= err == nil
		sink.written += len(sink.pending)
		clear(&sink.pending)
	}
}

// A sink into a new file at `path` (64 KB written at a time). The sink owns the file: close flushes and closes it.
log_sink_file :: proc(path: string) -> (sink: Log_Sink, ok: bool) {
	file, err := os.create(path)
	if err != nil {
		return
	}
	file_sink := new(File_Sink)
	file_sink.file = file
	file_sink.ok = true
	sink.user = file_sink
	sink.write = proc(user: rawptr, offset: int, bytes: []u8) -> bool {
		file_sink := (^File_Sink)(user)
		if offset == file_sink.written + len(file_sink.pending) {
			append(&file_sink.pending, ..bytes)
			if len(file_sink.pending) >= 64 * 1024 {
				file_sink_flush(file_sink)
			}
		} else {
			file_sink_flush(file_sink)
			_, err := os.write_at(file_sink.file, bytes, i64(offset))
			file_sink.ok &&= err == nil
		}
		return file_sink.ok
	}
	sink.close = proc(user: rawptr) {
		file_sink := (^File_Sink)(user)
		file_sink_flush(file_sink)
		os.close(file_sink.file)
		delete(file_sink.pending)
		free(file_sink)
	}
	return sink, true
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

log_stream_tick :: proc(stream: ^Log_Stream, inputs: ^Inputs($Input, $PLAYERS)) {
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

Log_Header :: struct {
	seed:       u64,
	content:    u64,
	players:    int,
	input_size: int,
	ticks:      int,
}

write_log_header :: proc(writer: ^wire.Writer, header: Log_Header) {
	wire.w_bytes(writer, transmute([]u8)string(LOG_MAGIC))
	wire.w_u16(writer, LOG_VERSION)
	wire.w_u64(writer, header.seed)
	wire.w_u64(writer, header.content)
	wire.w_u8(writer, u8(header.players))
	wire.w_u16(writer, u16(header.input_size))
	wire.w_u32(writer, u32(header.ticks))
}

// The header and the tick bytes (a view into data).
decode_log :: proc(data: []u8) -> (header: Log_Header, body: []u8, ok: bool) {
	reader := wire.reader_make(data)
	magic := wire.r_bytes(&reader, 4)
	version := wire.r_u16(&reader)
	header.seed = wire.r_u64(&reader)
	header.content = wire.r_u64(&reader)
	header.players = int(wire.r_u8(&reader))
	header.input_size = int(wire.r_u16(&reader))
	header.ticks = int(wire.r_u32(&reader))
	if !reader.ok || string(magic) != LOG_MAGIC || version != LOG_VERSION {
		return
	}
	return header, data[reader.pos:], true
}

write_file :: proc(path: string, data: []u8) -> bool {
	return os.write_entire_file(path, data) == nil
}

read_file :: proc(path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	file_data, err := os.read_entire_file(path, allocator)
	return file_data, err == nil
}
