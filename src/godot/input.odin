// The action helpers Glue.sample_input fills a local player's Input with (main thread, once a frame per local player;
// they read Godot's Input singleton, or the device of the local player being sampled), and the host's newest sample of
// each local player the session thread takes. The rules a game's input follows (state, never a one-shot; input values
// and input_wanted; when game input is off; local players and their devices): src/godot/README.md, Input.
package godot

import "base:intrinsics"
import "core:fmt"
import "core:sync"
import gd "unified:gdext"
import "unified:netcode"

@(private)
MAX_INPUT_BYTES :: 256

// The most local players one client has (netcode.LOCAL_MAX): UnifiedSession.add_local_player.
LOCAL_MAX :: netcode.LOCAL_MAX
// A local player's device: every device, Godot's Input singleton (local player 0's default, and today's behaviour).
DEVICE_ANY :: -1
// A local player's device: the keyboard and the mouse.
DEVICE_KEYBOARD :: -2

@(private)
input_sample: struct {
	mu:       sync.Mutex, // guards each local player's bytes and seq
	locals:   [LOCAL_MAX]struct {
		bytes: [MAX_INPUT_BYTES]u8, // the newest sample
		seq:   u64, // the newest stored sample's number (guarded)
		taken: u64, // the newest sample a tick took (atomic)
		shown: u32, // `shown` when it was sampled (guarded)
	},
	// The tick of the frame on screen + 1 (0: none yet; main thread): api.front sets it, each sample keeps it, the
	// session thread stamps the input's sim.Seen from it.
	shown:    u32,
	sampling: u64, // the sample the main thread is making (main thread only)
	current:  int, // the local player sample_input is filling (main thread)
	active:   [LOCAL_MAX]bool, // the local players sample_input fills (main thread; local player 0 always)
	devices:  [LOCAL_MAX]int, // each local player's device (DEVICE_ANY, DEVICE_KEYBOARD, a joypad's id; main thread)
	blocked:  bool, // game input is off (the dev UI's keyboard, game_input false): the actions read nothing
	off:      bool, // UnifiedSession.game_input is false (main thread)
	focused:  bool, // the window had the focus last frame
	latches:  [dynamic]Latch,
	tracked:  [dynamic]Tracked_Action, // the actions read for a local player on a device, their state from events
}

@(private)
Latch :: struct {
	action:    string,
	local:     int, // whose (each local player latches its own taps)
	name:      ^gd.StringName,
	latched:   bool, // tapped since a tick last took the input
	seq:       u64, // the sample it was latched in
	swallowed: bool, // held when game input came back: not down until released
}

// An action read for a local player on a device (not DEVICE_ANY): Godot's Input singleton keeps no action state per
// device, so the session tracks it from the device's events (input_event).
@(private)
Tracked_Action :: struct {
	action:   string,
	name:     ^gd.StringName,
	strength: [LOCAL_MAX]f32, // each local player's, 0..1
	pressed:  [LOCAL_MAX]bool,
}

// Main thread, every frame, before sample_input: latches a tick has taken are cleared; game input is on unless the
// dev UI has the keyboard or the game turned it off. Turning off drops the latches; coming back (or the window
// getting the focus back) swallows what is still held. Losing the focus releases the keyboard players' actions (Godot
// drops held keys without events).
@(private)
input_sample_begin :: proc(dev_keyboard: bool) {
	for &latch in input_sample.latches {
		taken := sync.atomic_load(&input_sample.locals[latch.local].taken)
		if latch.latched && latch.seq <= taken do latch.latched = false
	}
	focused := gd.DisplayServer_window_is_focused(gd.DisplayServer_singleton())
	blocked := dev_keyboard || input_sample.off
	back := (input_sample.blocked && !blocked) || (focused && !input_sample.focused)
	if !focused && input_sample.focused {
		for &tracked in input_sample.tracked {
			for device, local in input_sample.devices {
				if device == DEVICE_KEYBOARD do tracked.strength[local], tracked.pressed[local] = 0, false
			}
		}
	}
	for &latch in input_sample.latches {
		held := action_held(latch.local, latch.action, latch.name)
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

// Main thread, an input event (the session node's _input): the state of each tracked action for each local player on
// the event's device: a joypad's event for the local players on that pad, a key's or the mouse's for those on the
// keyboard. A press latches (a tap shorter than a frame still reaches the sim).
@(private)
input_event :: proc(event: gd.InputEvent) {
	keyboard :=
		gd.Object_is_class(event, "InputEventKey") ||
		gd.Object_is_class(event, "InputEventMouseButton") ||
		gd.Object_is_class(event, "InputEventMouseMotion")
	joypad :=
		gd.Object_is_class(event, "InputEventJoypadButton") || gd.Object_is_class(event, "InputEventJoypadMotion")
	if !keyboard && !joypad do return
	pad := gd.InputEvent_get_device(event)
	for device, local in input_sample.devices {
		if device == DEVICE_ANY || (keyboard ? device != DEVICE_KEYBOARD : device != pad) do continue
		for &tracked in input_sample.tracked {
			if !gd.InputEvent_is_action(event, tracked.name, false) do continue
			strength := f32(gd.InputEvent_get_action_strength(event, tracked.name, false))
			pressed := gd.InputEvent_is_action_pressed(event, tracked.name, false, false)
			if pressed && !tracked.pressed[local] && !input_sample.blocked {
				latch := latch_of(tracked.action, local)
				latch.latched, latch.seq = true, input_sample.sampling
			}
			tracked.strength[local], tracked.pressed[local] = strength, pressed
		}
	}
}

@(private)
input_sample_store :: proc(local: int, bytes: []u8) {
	sync.guard(&input_sample.mu)
	copy(input_sample.locals[local].bytes[:], bytes)
	input_sample.locals[local].seq = input_sample.sampling
	input_sample.locals[local].shown = input_sample.shown
}

// Session thread: local player `local`'s newest sample's bytes (every tick that samples gets it, also when several take
// one), marking it taken (its latches are then cleared), and the tick of the frame on screen when it was sampled
// (`shown` false: none yet).
@(private)
input_sample_take :: proc(local: int, out: []u8) -> (shown_tick: u32, shown: bool) {
	sync.guard(&input_sample.mu)
	copy(out, input_sample.locals[local].bytes[:len(out)])
	sync.atomic_store(&input_sample.locals[local].taken, input_sample.locals[local].seq)
	stored := input_sample.locals[local].shown
	return stored - 1, stored != 0
}

// A new session: nothing sampled for it yet.
@(private)
input_sample_reset :: proc() {
	sync.guard(&input_sample.mu)
	for &local in input_sample.locals {
		local.bytes = {}
		local.shown = 0
		sync.atomic_store(&local.taken, local.seq)
	}
	input_sample.shown = 0
	for &latch in input_sample.latches do latch.latched = false
}

@(private)
action_name :: proc(action: string) -> ^gd.StringName {
	return gd.sn(action)
}

// The device of the local player being sampled.
@(private)
sampled_device :: #force_inline proc() -> int {
	return input_sample.devices[input_sample.current]
}

// The tracked state of `action` (main thread), created the first time a helper reads it for a local player on a
// device: from then on its events are followed.
@(private)
tracked_of :: proc(action: string) -> ^Tracked_Action {
	for &known in input_sample.tracked do if known.action == action do return &known
	append(&input_sample.tracked, Tracked_Action{action = fmt.aprint(action), name = action_name(action)})
	return &input_sample.tracked[len(input_sample.tracked) - 1]
}

@(private)
latch_of :: proc(action: string, local: int) -> ^Latch {
	for &known in input_sample.latches do if known.action == action && known.local == local do return &known
	append(&input_sample.latches, Latch{action = fmt.aprint(action), local = local, name = action_name(action)})
	return &input_sample.latches[len(input_sample.latches) - 1]
}

// Whether `local`'s action is held now: Godot's Input singleton for DEVICE_ANY, else its device's tracked state.
@(private)
action_held :: proc(local: int, action: string, name: ^gd.StringName) -> bool {
	if input_sample.devices[local] == DEVICE_ANY {
		return gd.Input_is_action_pressed(gd.Input_singleton(), name, false)
	}
	for &tracked in input_sample.tracked do if tracked.action == action do return tracked.pressed[local]
	return false
}

// Main thread (sample_input): the action's strength now, 0..1 (an analog trigger or stick direction), on the sampled
// local player's device.
action_strength :: proc(action: string) -> f32 {
	if input_sample.blocked do return 0
	if sampled_device() != DEVICE_ANY do return tracked_of(action).strength[input_sample.current]
	return f32(gd.Input_get_action_strength(gd.Input_singleton(), action_name(action), false))
}

// Main thread (sample_input): Input.get_vector over four actions: x right, y "back" (2D: down; 3D: toward +Z), on the
// sampled local player's device (clamped to length 1).
action_vector :: proc(negative_x, positive_x, negative_y, positive_y: string) -> [2]f32 {
	if input_sample.blocked do return {}
	if sampled_device() != DEVICE_ANY {
		vector := [2]f32 {
			action_strength(positive_x) - action_strength(negative_x),
			action_strength(positive_y) - action_strength(negative_y),
		}
		if length := vector.x * vector.x + vector.y * vector.y; length > 1 {
			vector /= f32_sqrt(length)
		}
		return vector
	}
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

@(private)
f32_sqrt :: proc(x: f32) -> f32 {
	return intrinsics.sqrt(x)
}

// Every local player starts on DEVICE_ANY (Godot's Input singleton, as one player plays).
@(init, private)
input_init :: proc "contextless" () {
	for &device in input_sample.devices do device = DEVICE_ANY
	input_sample.active[0] = true
}

// Main thread (sample_input): a button's state for the sampled local player: held now, or tapped since a tick last
// took the input (so a tap shorter than a frame still reaches the sim). False while game input is off, and for an
// action held when it came back until it is released. The sim sees a press as the button down this tick and not the
// tick before (sim.input_before).
action_down :: proc(action: string) -> bool {
	local := input_sample.current
	latch := latch_of(action, local)
	if sampled_device() != DEVICE_ANY do _ = tracked_of(action)
	if input_sample.blocked || latch.swallowed do return false
	if sampled_device() == DEVICE_ANY && gd.Input_is_action_just_pressed(gd.Input_singleton(), latch.name, false) {
		latch.latched, latch.seq = true, input_sample.sampling
	}
	return latch.latched || action_held(local, latch.action, latch.name)
}

// Main thread (sample_input): an Input's `buttons` bit_set, each button from its action (action_down; "": never
// down). The sim reads it with sim.buttons (down, pressed, released).
//
//   input.buttons = godot.buttons(Buttons, {.Jump = "jump", .Grab = "grab", .Throw = "throw"})
buttons :: proc($Set: typeid/bit_set[$E;$U], actions: [E]string) -> (set: Set) {
	for action, button in actions do if action != "" && action_down(action) do set += {button}
	return
}

// Main thread (sample_input): the device of local player `local` (DEVICE_ANY, DEVICE_KEYBOARD, or a joypad's id), for
// a game that reads one itself.
local_device :: proc(local: int) -> int {
	return input_sample.devices[local] if local >= 0 && local < LOCAL_MAX else DEVICE_ANY
}

// UnifiedSession.game_input (main thread): off, the action helpers read nothing (a pause menu, a chat field);
// Unified.input still flows.
@(private)
set_game_input :: proc(on: bool) {
	input_sample.off = !on
}

// Main thread (sample_input): the values scripts set for the sampled local player, as the Glue's input values type `T`:
// Unified.input for local player 0, Unified.local_input(local) for the others.
//
//   values := godot.input_values(Input_Values)
//   input.look = dmath.dir3(values.look)
input_values :: proc($T: typeid, loc := #caller_location) -> ^T {
	if api.input_values.type == nil || api.input_values.type.id != T {
		panic(fmt.tprintf("input_values: %v is not the Glue's input_values", typeid_of(T)), loc)
	}
	@(static) none: T // before the classes exist (a failed registration): zero
	instance := local_input_instance(input_sample.current)
	if instance == nil do return &none
	return (^T)(raw_data(instance.bytes))
}

@(private)
input_clear :: proc() {
	for latch in input_sample.latches do delete(latch.action)
	delete(input_sample.latches)
	input_sample.latches = nil
	for tracked in input_sample.tracked do delete(tracked.action)
	delete(input_sample.tracked)
	input_sample.tracked = nil
}
