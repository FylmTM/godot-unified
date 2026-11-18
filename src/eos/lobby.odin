// EOS as a netcode.Lobby: the one way a game reaches online play, the Godot host (godot.init) and a game's headless
// binary (modes.run) alike (src/eos/SPEC.md).
package eos

import "unified:netcode"

Lobby_Config :: struct {
	lib_dirs:            []string, // where to look for the SDK library; empty = default_lib_dirs()
	relay_control:       Maybe(Relay_Control), // default Allow_Relays ($UNIFIED_EOS_RELAYS overrides it)
	no_keychain_prompts: bool, // Init_Options.no_keychain_prompts (headless tools)
	// At shutdown, delete this machine's device ID (test tools: on macOS the keychain entry belongs to the binary that
	// made it, so a rebuilt one could not read it without a dialog).
	forget_device:       bool,
}

// The EOS lobby service. EOS starts on the first open_host or open_join, named after the game (Lobby_Build.game) with
// the build's version; one per process, so is this lobby.
lobby :: proc "contextless" (config: Lobby_Config) -> ^netcode.Lobby {
	lobby_config = config
	return &LOBBY
}

@(private)
lobby_config: Lobby_Config

@(private)
LOBBY := netcode.Lobby {
	name = "eos",
	open_host = proc(build: Build) -> (link: netcode.Link, ok: bool) {
		lobby_start(build) or_return
		return open_host(build)
	},
	open_join = proc(build: Build, code: string) -> (link: netcode.Link, ok: bool) {
		lobby_start(build) or_return
		return open_join(build, code)
	},
	pump = pump,
	close = close,
	// The SDK finishes its HTTP through the macOS main run loop, which headless Godot doesn't pump.
	main_frame = pump_main_run_loop,
	// EOS left initialized at exit crashed in its own threads during process teardown (macOS, ~1 in 2 exits).
	shutdown = proc() {
		if lobby_config.forget_device do forget_device()
		shutdown()
	},
	account = local_account,
}

// Starts EOS for the game on first use (false: unavailable, status says why).
@(private)
lobby_start :: proc(build: Build) -> bool {
	if status().stage != .Off {
		return true
	}
	return init({
		lib_dirs            = lobby_config.lib_dirs,
		product_name        = build.game,
		product_version     = build.version,
		relay_control       = lobby_config.relay_control,
		no_keychain_prompts = lobby_config.no_keychain_prompts,
	})
}
