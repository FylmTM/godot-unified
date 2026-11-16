// Online play through EOS for a Godot game: unified:eos as a godot.Transport, so a game's extension wires it in one
// line (src/godot_eos/SPEC.md). A package of its own: unified:eos never imports unified:godot (the headless binary
// uses it), and unified:godot never imports a transport (a game without online play carries no EOS).
package godot_eos

import "unified:eos"
import "unified:godot"
import "unified:netcode"

// The EOS transport for `game`: its name is the EOS product name and the lobby bucket; the version a joiner on
// another build is shown is the project's stamped version (godot.app_version). Set it before godot.entry:
//   godot.set_transport(godot_eos.transport("survivor"))
// EOS is one per process, so is this transport.
transport :: proc(game: string) -> ^godot.Transport {
	g_game = game
	return &TRANSPORT
}

@(private)
g_game: string

@(private)
TRANSPORT := godot.Transport {
	name = "EOS",
	open_host = open_host,
	open_join = open_join,
	pump = pump,
	close = proc(_: rawptr) {eos.close()},
	// EOS's HTTP completes through the macOS main run loop, which headless Godot doesn't pump.
	main_frame = proc(_: rawptr) {eos.pump_main_run_loop()},
	// EOS left initialized at exit crashed in its own threads during process teardown (macOS, ~1 in 2 exits).
	shutdown = proc(_: rawptr) {eos.shutdown()},
	// The host player's product user id (UnifiedSession.get_player_platform_id).
	account = proc(_: rawptr) -> (netcode.Account, bool) {return eos.local_account()},
}

// Initializes EOS on first use (once per process); a failure ends the session with its reason.
@(private)
init :: proc(events: ^godot.Transport_Events) -> bool {
	if eos.init({product_name = g_game, product_version = godot.app_version}) do return true
	events.fail(events.ctx, eos.status().detail)
	return false
}

@(private)
build :: proc(compat: u64) -> eos.Build {
	return {game = g_game, compat = compat, version = godot.app_version}
}

@(private)
open_host :: proc(_: rawptr, compat: u64, events: ^godot.Transport_Events) -> (link: netcode.Link, ok: bool) {
	if !init(events) do return
	link, ok = eos.open_host(build(compat))
	if !ok do events.fail(events.ctx, eos.status().detail)
	return
}

@(private)
open_join :: proc(
	_: rawptr,
	code: string,
	compat: u64,
	events: ^godot.Transport_Events,
) -> (
	link: netcode.Link,
	ok: bool,
) {
	if !init(events) do return
	link, ok = eos.open_join(build(compat), code)
	if !ok do events.fail(events.ctx, eos.status().detail)
	return
}

@(private)
pump :: proc(_: rawptr, events: ^godot.Transport_Events) {
	result := eos.pump()
	if result.code != "" do events.code(events.ctx, result.code)
	if result.failed != "" do events.fail(events.ctx, result.failed)
}
