// Input: the main thread samples the game's InputMap actions every frame into atomics; the session thread
// takes them when the netcode asks for the local player's input. Button presses accumulate until taken, so a
// tap shorter than a tick is never lost.
package godot

import "core:sync"
import gd "unified:gdext"

@(private)
input_state: struct {
	move:    u64, // two f32 bit patterns
	held:    u32,
	pressed: u32, // edges since the last take
	mu:      sync.Mutex, // guards vectors
	vectors: [INPUT_VECTORS][3]f32,
}

// The actions as interned StringNames (main thread, built on the first sample): no per-frame conversions.
@(private)
action_sn: struct {
	ready:   bool,
	move:    [4]^gd.StringName,
	buttons: [32]^gd.StringName,
	count:   int, // of buttons
}

// Main thread: sample the actions (no-op before install).
sample_input :: proc(block: bool) {
	if !api.installed do return
	input := gd.Input_singleton()
	actions := &api.actions
	names := &action_sn
	if !names.ready {
		names.ready = true
		if actions.move[0] != "" do for action, i in actions.move do names.move[i] = gd.sn(action)
		names.count = min(len(actions.buttons), 32)
		for i in 0 ..< names.count do names.buttons[i] = gd.sn(actions.buttons[i])
	}
	move: [2]f32
	held: u32
	if !block {
		if names.move[0] != nil {
			vector := gd.Input_get_vector(input, names.move[0], names.move[1], names.move[2], names.move[3], -1)
			move = {vector.x, vector.y}
		}
		for i in 0 ..< names.count {
			if gd.Input_is_action_pressed(input, names.buttons[i], false) do held |= 1 << u32(i)
		}
	}
	sync.atomic_store(&input_state.move, transmute(u64)move)
	old := sync.atomic_exchange(&input_state.held, held)
	if edges := held & ~old; edges != 0 do sync.atomic_or(&input_state.pressed, edges)
}

// Main thread: press a button from code (a UI button doing what a key does).
press_button :: proc(button: int) {
	if button < 0 || button >= 32 do return
	sync.atomic_or(&input_state.pressed, 1 << u32(button))
}

// Main thread: a view-dependent input vector (Actions.vectors[i]).
set_input_vector :: proc(index: int, vector: [3]f32) {
	if index < 0 || index >= INPUT_VECTORS do return
	sync.guard(&input_state.mu)
	input_state.vectors[index] = vector
}

// Session thread: the current actions, consuming the accumulated presses.
take_actions :: proc() -> Actions {
	actions := Actions {
		move    = transmute([2]f32)sync.atomic_load(&input_state.move),
		held    = sync.atomic_load(&input_state.held),
		pressed = sync.atomic_exchange(&input_state.pressed, 0),
	}
	sync.guard(&input_state.mu)
	actions.vectors = input_state.vectors
	return actions
}

button_index :: proc(name: string) -> int {
	for button, i in api.actions.buttons do if button == name do return i
	return -1
}
