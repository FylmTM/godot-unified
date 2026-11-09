// Input: the main thread samples the game's InputMap actions every frame into atomics; the session thread
// takes them when the netcode asks for the local player's input. Button presses accumulate until taken, so a
// tap shorter than a tick is never lost.
package godot_host

import "core:sync"
import gd "unified:gdext"

@(private)
input_state: struct {
	move:    u64, // two f32 bit patterns
	held:    u32,
	pressed: u32, // edges since the last take
}

// The actions as interned StringNames (main thread, built on the first sample): no per-frame conversions.
@(private)
action_sn: struct {
	ready:   bool,
	move:    [4]^gd.StringName,
	buttons: [32]^gd.StringName,
	n:       int,
}

// Main thread: sample the actions (no-op before install).
sample_input :: proc(block: bool) {
	if !api.installed do return
	inp := gd.Input_singleton()
	a := &api.actions
	sn := &action_sn
	if !sn.ready {
		sn.ready = true
		if a.move[0] != "" do for m, i in a.move do sn.move[i] = gd.sn(m)
		sn.n = min(len(a.buttons), 32)
		for i in 0 ..< sn.n do sn.buttons[i] = gd.sn(a.buttons[i])
	}
	move: [2]f32
	held: u32
	if !block {
		if sn.move[0] != nil {
			v := gd.Input_get_vector(inp, sn.move[0], sn.move[1], sn.move[2], sn.move[3], -1)
			move = {v.x, v.y}
		}
		for i in 0 ..< sn.n {
			if gd.Input_is_action_pressed(inp, sn.buttons[i], false) do held |= 1 << u32(i)
		}
	}
	sync.atomic_store(&input_state.move, transmute(u64)move)
	old := sync.atomic_exchange(&input_state.held, held)
	if edges := held & ~old; edges != 0 do sync.atomic_or(&input_state.pressed, edges)
}

// Main thread: press a button from code (a UI button doing what a key does).
press_button :: proc(i: int) {
	if i < 0 || i >= 32 do return
	sync.atomic_or(&input_state.pressed, 1 << u32(i))
}

// Session thread: the current actions, consuming the accumulated presses.
take_actions :: proc() -> Actions {
	return {
		move = transmute([2]f32)sync.atomic_load(&input_state.move),
		held = sync.atomic_load(&input_state.held),
		pressed = sync.atomic_exchange(&input_state.pressed, 0),
	}
}

button_index :: proc(name: string) -> int {
	for b, i in api.actions.buttons do if b == name do return i
	return -1
}
