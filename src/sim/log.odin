// Input log (the replay file): "UNIL", version u16, seed u64, content hash u64 (the level, 0: none),
// slots u8, input size u16, tick count u32, then per tick (write_tick, also the netcode's finalized tick):
// present u32, replaced u32, slots × the input's bytes (plain data, so its memory is its little-endian
// serialization), command count u8, then per command: slot u8, kind u8, size u8, the struct's bytes.
package sim

import "core:os"

import "unified:wire"

LOG_MAGIC :: "UNIL"
LOG_VERSION :: 4 // 4: commands per tick
LOG_HEADER :: 29
COMMAND_HEAD :: 3 // slot, kind, size: a command's bytes on the wire and in the log, before its data

// A tick of the log, compact: its commands live in Input_Log.commands.
Log_Tick :: struct($I: typeid, $P: int) {
	present:       Players,
	replaced:      Players,
	input:         [P]I,
	first_command: u32, // index into Input_Log.commands
	n_commands:    u32,
}

Input_Log :: struct($I: typeid, $P: int) {
	seed:     u64,
	content:  u64, // content_hash of the session's content (0: none)
	ticks:    [dynamic]Log_Tick(I, P), // ticks[k] holds tick k + 1
	commands: [dynamic]Command, // every tick's commands, in tick order
}

log_destroy :: proc(lg: ^Input_Log($I, $P)) {
	delete(lg.ticks)
	delete(lg.commands)
	lg.ticks = nil
	lg.commands = nil
}

// Appends a tick's inputs (the next tick).
log_append :: proc(lg: ^Input_Log($I, $P), inputs: ^Inputs(I, P)) {
	append(
		&lg.ticks,
		Log_Tick(I, P) {
			present = inputs.present,
			replaced = inputs.replaced,
			input = inputs.input,
			first_command = u32(len(lg.commands)),
			n_commands = u32(inputs.n_commands),
		},
	)
	append(&lg.commands, ..inputs.commands[:inputs.n_commands])
}

// The commands of the log's tick k + 1.
log_commands :: proc(lg: ^Input_Log($I, $P), k: int) -> []Command {
	tk := &lg.ticks[k]
	return lg.commands[tk.first_command:][:tk.n_commands]
}

// The inputs of the log's tick k + 1, ready for sim.step.
log_inputs :: proc(lg: ^Input_Log($I, $P), k: int) -> (inputs: Inputs(I, P)) {
	tk := &lg.ticks[k]
	inputs.present = tk.present
	inputs.replaced = tk.replaced
	inputs.input = tk.input
	cmds := log_commands(lg, k)
	inputs.n_commands = len(cmds)
	copy(inputs.commands[:], cmds)
	return
}

// The bytes of a tick's record (write_tick), for sizing datagrams.
tick_bytes :: proc($I: typeid, $P: int, cmds: []Command) -> int {
	n := 9 + P * size_of(I)
	for &c in cmds {
		n += COMMAND_HEAD + int(c.size)
	}
	return n
}

// Writes a tick's record: present, replaced, the inputs, then the commands.
write_tick :: proc(w: ^wire.Writer, present, replaced: Players, input: []u8, cmds: []Command) {
	wire.w_u32(w, transmute(u32)present)
	wire.w_u32(w, transmute(u32)replaced)
	wire.w_bytes(w, input)
	wire.w_u8(w, u8(len(cmds)))
	for &c in cmds {
		wire.w_u8(w, c.slot)
		wire.w_u8(w, c.kind)
		wire.w_u8(w, c.size)
		wire.w_bytes(w, c.data[:c.size])
	}
}

// Reads a tick's record into `input` and `cmds`; false when it is malformed: cut short, more than
// TICK_COMMANDS commands or COMMANDS_PER_PLAYER of one slot, a slot out of range or out of order, a
// command over COMMAND_MAX bytes. Command kinds are not checked here (bind_commands does that).
read_tick :: proc(
	r: ^wire.Reader,
	input: []u8,
	slots: int,
	cmds: ^[TICK_COMMANDS]Command,
) -> (
	present, replaced: Players,
	n: int,
	ok: bool,
) {
	present = transmute(Players)wire.r_u32(r)
	replaced = transmute(Players)wire.r_u32(r)
	copy(input, wire.r_bytes(r, len(input)))
	n = int(wire.r_u8(r))
	if !r.ok || n > TICK_COMMANDS {
		return
	}
	per_slot := 0
	for i in 0 ..< n {
		c := &cmds[i]
		c^ = {}
		c.slot = wire.r_u8(r)
		c.kind = wire.r_u8(r)
		c.size = wire.r_u8(r)
		if int(c.slot) >= slots || int(c.size) > COMMAND_MAX {
			return
		}
		copy(c.data[:], wire.r_bytes(r, int(c.size)))
		per_slot = i > 0 && cmds[i - 1].slot == c.slot ? per_slot + 1 : 1
		if !r.ok || (i > 0 && cmds[i - 1].slot > c.slot) || per_slot > COMMANDS_PER_PLAYER {
			return
		}
	}
	return present, replaced, n, true
}

// Writes a tick's inputs as write_tick does.
inputs_write :: proc(w: ^wire.Writer, inputs: ^Inputs($I, $P)) {
	write_tick(
		w,
		inputs.present,
		inputs.replaced,
		([^]u8)(&inputs.input)[:size_of([P]I)],
		inputs.commands[:inputs.n_commands],
	)
}

// Reads a tick's inputs written by inputs_write (or log_write_tick).
inputs_read :: proc(r: ^wire.Reader, inputs: ^Inputs($I, $P)) -> bool {
	inputs^ = {}
	present, replaced, n, ok := read_tick(r, ([^]u8)(&inputs.input)[:size_of([P]I)], P, &inputs.commands)
	inputs.present, inputs.replaced, inputs.n_commands = present, replaced, n
	return ok
}

// Writes the log's tick k + 1 as write_tick does.
log_write_tick :: proc(w: ^wire.Writer, lg: ^Input_Log($I, $P), k: int) {
	tk := &lg.ticks[k]
	write_tick(w, tk.present, tk.replaced, ([^]u8)(&tk.input)[:size_of([P]I)], log_commands(lg, k))
}

// The log's bytes: the header, then the ticks.
log_encode :: proc(lg: ^Input_Log($I, $P), allocator := context.allocator) -> []u8 {
	w := wire.writer_make(
		LOG_HEADER + len(lg.ticks) * tick_bytes(I, P, nil) + len(lg.commands) * (COMMAND_HEAD + 8),
		allocator,
	)
	write_log_header(&w, Log_Header{lg.seed, lg.content, P, size_of(I), len(lg.ticks)})
	for k in 0 ..< len(lg.ticks) {
		log_write_tick(&w, lg, k)
	}
	return w.buf[:]
}

log_decode :: proc(data: []u8, $I: typeid, $P: int) -> (lg: Input_Log(I, P), ok: bool) {
	h, body := decode_log(data) or_return
	if h.slots != P || h.input_size != size_of(I) || len(body) < h.ticks * tick_bytes(I, P, nil) {
		return
	}
	lg.seed = h.seed
	lg.content = h.content
	lg.ticks = make([dynamic]Log_Tick(I, P), 0, h.ticks)
	r := wire.reader_make(body)
	in_: Inputs(I, P)
	for _ in 0 ..< h.ticks {
		if !inputs_read(&r, &in_) {
			log_destroy(&lg)
			return {}, false
		}
		log_append(&lg, &in_)
	}
	if wire.r_remaining(&r) != 0 {
		log_destroy(&lg)
		return {}, false
	}
	return lg, true
}

log_write :: proc(path: string, lg: ^Input_Log($I, $P)) -> bool {
	data := log_encode(lg)
	defer delete(data)
	return write_file(path, data)
}

log_read :: proc(path: string, $I: typeid, $P: int) -> (lg: Input_Log(I, P), ok: bool) {
	data := read_file(path) or_return
	defer delete(data)
	return log_decode(data, I, P)
}

Log_Header :: struct {
	seed:       u64,
	content:    u64,
	slots:      int,
	input_size: int,
	ticks:      int,
}

write_log_header :: proc(w: ^wire.Writer, h: Log_Header) {
	wire.w_bytes(w, transmute([]u8)string(LOG_MAGIC))
	wire.w_u16(w, LOG_VERSION)
	wire.w_u64(w, h.seed)
	wire.w_u64(w, h.content)
	wire.w_u8(w, u8(h.slots))
	wire.w_u16(w, u16(h.input_size))
	wire.w_u32(w, u32(h.ticks))
}

// The header and the tick bytes (a view into data).
decode_log :: proc(data: []u8) -> (h: Log_Header, body: []u8, ok: bool) {
	r := wire.reader_make(data)
	magic := wire.r_bytes(&r, 4)
	version := wire.r_u16(&r)
	h.seed = wire.r_u64(&r)
	h.content = wire.r_u64(&r)
	h.slots = int(wire.r_u8(&r))
	h.input_size = int(wire.r_u16(&r))
	h.ticks = int(wire.r_u32(&r))
	if !r.ok || string(magic) != LOG_MAGIC || version != LOG_VERSION {
		return
	}
	return h, data[r.pos:], true
}

write_file :: proc(path: string, data: []u8) -> bool {
	return os.write_entire_file(path, data) == nil
}

read_file :: proc(path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	d, err := os.read_entire_file(path, allocator)
	return d, err == nil
}
