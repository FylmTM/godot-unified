// Input: the game's Glue.sample_input fills the local player's Input on the main thread every frame, through the
// action helpers below (they read Godot's Input singleton); the host keeps the newest sample and the session
// thread takes it when a tick samples the local player. A press is latched until a tick has taken a sample holding
// it, so a tap shorter than a tick is never lost; a second tick taking the same sample gets it without its presses
// (sample_input runs twice: with presses, and with action_pressed false), so a press reaches the sim once.
package godot

import "core:fmt"
import "core:sync"
import gd "unified:gdext"

MAX_INPUT_BYTES :: 256

@(private)
input_sample: struct {
	mu:       sync.Mutex, // guards bytes and seq
	bytes:    [MAX_INPUT_BYTES]u8, // the newest sample
	held:     [MAX_INPUT_BYTES]u8, // the same, without presses
	sampling: u64, // the sample the main thread is making (main thread only)
	seq:      u64, // the newest stored sample's number (guarded)
	taken:    u64, // the newest sample a tick took (atomic)
	blocked:  bool, // a dev UI text field has the keyboard: the helpers read nothing
	no_press: bool, // sampling the press-free copy: action_pressed is false
	latches:  [dynamic]Latch,
	values:   map[string][3]f32, // set_input_value (main thread only)
}

@(private)
Latch :: struct {
	action:  string,
	name:    ^gd.StringName,
	latched: bool,
	seq:     u64, // the sample it was latched in
}

// Main thread, every frame: the game fills a fresh Input (sample_input) and the host keeps it.
@(private)
input_sample_begin :: proc(blocked: bool) {
	taken := sync.atomic_load(&input_sample.taken)
	for &latch in input_sample.latches do if latch.latched && latch.seq <= taken do latch.latched = false
	input_sample.blocked = blocked
	input_sample.sampling += 1
}

@(private)
input_sample_store :: proc(bytes, held: []u8) {
	sync.guard(&input_sample.mu)
	copy(input_sample.bytes[:], bytes)
	copy(input_sample.held[:], held)
	input_sample.seq = input_sample.sampling
}

// Session thread: the newest sample's bytes, marking it taken (its latched presses are then cleared); a sample
// already taken comes without its presses.
@(private)
input_sample_take :: proc(out: []u8) {
	sync.guard(&input_sample.mu)
	if input_sample.seq > sync.atomic_load(&input_sample.taken) {
		copy(out, input_sample.bytes[:len(out)])
		sync.atomic_store(&input_sample.taken, input_sample.seq)
	} else {
		copy(out, input_sample.held[:len(out)])
	}
}

// A new session: nothing sampled for it yet.
@(private)
input_sample_reset :: proc() {
	sync.guard(&input_sample.mu)
	input_sample.bytes, input_sample.held = {}, {}
	sync.atomic_store(&input_sample.taken, input_sample.seq)
	for &latch in input_sample.latches do latch.latched = false
}

@(private)
action_name :: proc(action: string) -> ^gd.StringName {
	return gd.sn(action)
}

// Main thread (sample_input): the action is held now.
action_held :: proc(action: string) -> bool {
	if input_sample.blocked do return false
	return gd.Input_is_action_pressed(gd.Input_singleton(), action_name(action), false)
}

// Main thread (sample_input): the action's strength now, 0..1 (an analog trigger or stick direction).
action_strength :: proc(action: string) -> f32 {
	if input_sample.blocked do return 0
	return f32(gd.Input_get_action_strength(gd.Input_singleton(), action_name(action), false))
}

// Main thread (sample_input): Input.get_vector over four actions: x right, y "back" (2D: down; 3D: toward +Z).
action_vector :: proc(negative_x, positive_x, negative_y, positive_y: string) -> [2]f32 {
	if input_sample.blocked do return {}
	vector := gd.Input_get_vector(
		gd.Input_singleton(),
		action_name(negative_x),
		action_name(positive_x),
		action_name(negative_y),
		action_name(positive_y),
		-1,
	)
	return {vector.x, vector.y}
}

// Main thread (sample_input): true for every press of the action since a tick last took the input, so a tap
// shorter than a tick still reaches the sim once.
action_pressed :: proc(action: string) -> bool {
	if input_sample.no_press do return false
	latch: ^Latch
	for &known in input_sample.latches do if known.action == action do latch = &known
	if latch == nil {
		append(&input_sample.latches, Latch{action = fmt.aprint(action), name = action_name(action)})
		latch = &input_sample.latches[len(input_sample.latches) - 1]
	}
	if !input_sample.blocked && gd.Input_is_action_just_pressed(gd.Input_singleton(), latch.name, false) {
		latch.latched, latch.seq = true, input_sample.sampling
	}
	return latch.latched
}

// Main thread (sample_input): the latest value a script set with UnifiedSession.set_input_value(name, value): a
// Vector3, a Vector2 (z = 0), or a float or bool in x; zero until set.
input_value :: proc(name: string) -> [3]f32 {
	return input_sample.values[name]
}

// −1..1 to an axis of −127..127.
axis_i8 :: proc(x: f32) -> i8 {
	return i8(clamp(x, -1, 1) * 127)
}

// UnifiedSession.set_input_value (main thread).
@(private)
set_input_value :: proc(name: string, value: [3]f32) {
	if name in input_sample.values {
		input_sample.values[name] = value
	} else {
		input_sample.values[fmt.aprint(name)] = value
	}
}

@(private)
input_clear :: proc() {
	for latch in input_sample.latches do delete(latch.action)
	delete(input_sample.latches)
	for name in input_sample.values do delete(name)
	delete(input_sample.values)
	input_sample.latches, input_sample.values = nil, nil
}
