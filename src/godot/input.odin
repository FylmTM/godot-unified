// Input: the game's Glue.sample_input fills the local player's Input on the main thread once a frame, through the
// action helpers below (they read Godot's Input singleton); the host keeps the newest sample and the session
// thread takes it for every tick that samples the local player (several ticks may take one sample). Buttons are
// state: `action_down` is held, or tapped since a tick last took the input (latched, so a tap shorter than a
// frame is never lost); the sim derives presses from the tick before (sim.buttons). Game input is off while a dev
// UI text field has the keyboard and while UnifiedSession.game_input is false; when it comes back, and when the
// window gets the focus back, an action still held counts only once it is released (the key that closed a menu, the
// click that focused the window never fire). An unfocused window still reads input (Godot releases what was held
// when it lost the focus; tool runs drive windows that never take it).
package godot

import "core:fmt"
import "core:sync"
import gd "unified:gdext"

MAX_INPUT_BYTES :: 256

@(private)
input_sample: struct {
	mu:       sync.Mutex, // guards bytes and seq
	bytes:    [MAX_INPUT_BYTES]u8, // the newest sample
	sampling: u64, // the sample the main thread is making (main thread only)
	seq:      u64, // the newest stored sample's number (guarded)
	taken:    u64, // the newest sample a tick took (atomic)
	blocked:  bool, // game input is off (the dev UI's keyboard, game_input false): the actions read nothing
	off:      bool, // UnifiedSession.game_input is false (main thread)
	focused:  bool, // the window had the focus last frame
	latches:  [dynamic]Latch,
}

@(private)
Latch :: struct {
	action:    string,
	name:      ^gd.StringName,
	latched:   bool, // tapped since a tick last took the input
	seq:       u64, // the sample it was latched in
	swallowed: bool, // held when game input came back: not down until released
}

// Main thread, every frame, before sample_input: latches a tick has taken are cleared; game input is on unless the
// dev UI has the keyboard or the game turned it off. Turning off drops the latches; coming back (or the window
// getting the focus back) swallows what is still held.
@(private)
input_sample_begin :: proc(dev_keyboard: bool) {
	taken := sync.atomic_load(&input_sample.taken)
	for &latch in input_sample.latches do if latch.latched && latch.seq <= taken do latch.latched = false
	focused := gd.DisplayServer_window_is_focused(gd.DisplayServer_singleton())
	blocked := dev_keyboard || input_sample.off
	back := (input_sample.blocked && !blocked) || (focused && !input_sample.focused)
	godot_input := gd.Input_singleton()
	for &latch in input_sample.latches {
		held := gd.Input_is_action_pressed(godot_input, latch.name, false)
		if blocked {
			latch.latched = false
		} else if back && held {
			latch.swallowed = true
		}
		if !held do latch.swallowed = false
	}
	input_sample.blocked, input_sample.focused = blocked, focused
	input_sample.sampling += 1
}

@(private)
input_sample_store :: proc(bytes: []u8) {
	sync.guard(&input_sample.mu)
	copy(input_sample.bytes[:], bytes)
	input_sample.seq = input_sample.sampling
}

// Session thread: the newest sample's bytes (every tick that samples gets it, also when several take one), marking
// it taken (its latches are then cleared).
@(private)
input_sample_take :: proc(out: []u8) {
	sync.guard(&input_sample.mu)
	copy(out, input_sample.bytes[:len(out)])
	sync.atomic_store(&input_sample.taken, input_sample.seq)
}

// A new session: nothing sampled for it yet.
@(private)
input_sample_reset :: proc() {
	sync.guard(&input_sample.mu)
	input_sample.bytes = {}
	sync.atomic_store(&input_sample.taken, input_sample.seq)
	for &latch in input_sample.latches do latch.latched = false
}

@(private)
action_name :: proc(action: string) -> ^gd.StringName {
	return gd.sn(action)
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

// Main thread (sample_input): a button's state: held now, or tapped since a tick last took the input (so a tap
// shorter than a frame still reaches the sim). False while game input is off, and for an action held when it came
// back until it is released. The sim sees a press as the button down this tick and not the tick before
// (sim.input_before).
action_down :: proc(action: string) -> bool {
	latch: ^Latch
	for &known in input_sample.latches do if known.action == action do latch = &known
	if latch == nil {
		append(&input_sample.latches, Latch{action = fmt.aprint(action), name = action_name(action)})
		latch = &input_sample.latches[len(input_sample.latches) - 1]
	}
	if input_sample.blocked || latch.swallowed do return false
	godot_input := gd.Input_singleton()
	if gd.Input_is_action_just_pressed(godot_input, latch.name, false) {
		latch.latched, latch.seq = true, input_sample.sampling
	}
	return latch.latched || gd.Input_is_action_pressed(godot_input, latch.name, false)
}

// Main thread (sample_input): an Input's `buttons` bit_set, each button from its action (action_down; "": never
// down). The sim reads it with sim.buttons (down, pressed, released).
//
//   input.buttons = godot.buttons(Buttons, {.Jump = "jump", .Grab = "grab", .Throw = "throw"})
buttons :: proc($Set: typeid/bit_set[$E;$U], actions: [E]string) -> (set: Set) {
	for action, button in actions do if action != "" && action_down(action) do set += {button}
	return
}

// UnifiedSession.game_input (main thread): off, the action helpers read nothing (a pause menu, a chat field);
// Unified.input still flows.
@(private)
set_game_input :: proc(on: bool) {
	input_sample.off = !on
}

// Main thread (sample_input): the values scripts set on Unified.input, as the Glue's input values type `T`.
//
//   values := godot.input_values(Input_Values)
//   input.look = dmath.dir3(values.look)
input_values :: proc($T: typeid, loc := #caller_location) -> ^T {
	if api.input_values.type == nil || api.input_values.type.id != T {
		panic(fmt.tprintf("input_values: %v is not the Glue's input_values", typeid_of(T)), loc)
	}
	@(static) none: T // before the classes exist (a failed registration): zero
	if D.input == nil || D.input.instance == nil do return &none
	return (^T)(raw_data(D.input.instance.bytes))
}


@(private)
input_clear :: proc() {
	for latch in input_sample.latches do delete(latch.action)
	delete(input_sample.latches)
	input_sample.latches = nil
}
