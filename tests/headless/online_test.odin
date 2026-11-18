// The lobby modes (<name>-host, <name>-client) on the toy over an in-process lobby: a hub whose endpoint 0 is the
// host's lobby link and endpoint 1 the joiner's. Real time, two threads, as two processes over EOS would run them.
package test_headless

import "base:runtime"
import "core:testing"
import "core:thread"

import "unified:headless/modes"
import "unified:netcode"

@(private = "file")
g_hub: ^netcode.Hub

@(private = "file")
g_opened: [2]netcode.Lobby_Build // what the host [0] and the joiner [1] opened the lobby with

@(private = "file")
LOOP_LOBBY := netcode.Lobby {
	name = "loop",
	open_host = proc(build: netcode.Lobby_Build) -> (netcode.Link, bool) {
		g_opened[0] = build
		return netcode.loopback_link(g_hub, 0), true
	},
	open_join = proc(build: netcode.Lobby_Build, code: string) -> (netcode.Link, bool) {
		g_opened[1] = build
		return netcode.loopback_link(g_hub, 1), true
	},
	pump = proc() -> netcode.Lobby_Status {
		// A remote peer counts as connected once a datagram from it waits at the host's endpoint.
		return {
			stage = .Ready,
			code  = "loop",
			local = "me",
			host  = "host",
			peers = netcode.hub_queued(g_hub, 0) > 0 ? 1 : 0,
		}
	},
	close = proc() {},
}

@(private = "file")
Mode_Task :: struct {
	args:      modes.Args,
	host:      bool,
	allocator: runtime.Allocator, // the test's (thread-safe), so what the hub holds at the end is freed against it
	ok:        bool,
}

@(private = "file")
run_mode :: proc(task: ^Mode_Task) {
	context.allocator = task.allocator
	headless := HEADLESS
	if task.host {
		task.ok = modes.mode_lobby_host(&headless, &task.args)
	} else {
		task.ok = modes.mode_lobby_client(&headless, &task.args)
	}
}

// `<name>-host --wait-s` waits for a joiner, then both play to the end. Both open the lobby with the game's name, the
// same build id and its player count.
@(test)
lobby_host_waits_for_a_joiner :: proc(t: ^testing.T) {
	g_hub = netcode.hub_create(2)
	defer netcode.hub_destroy(g_hub)
	host := Mode_Task {
		args = {mode = "loop-host", lobby = &LOOP_LOBBY},
		host = true,
		allocator = context.allocator,
	}
	host.args.opts["ticks"] = "64"
	host.args.opts["wait-s"] = "20"
	defer delete(host.args.opts)
	joiner := Mode_Task {
		args = {mode = "loop-client", lobby = &LOOP_LOBBY},
		allocator = context.allocator,
	}
	joiner.args.opts["ticks"] = "64"
	joiner.args.opts["code"] = "loop"
	defer delete(joiner.args.opts)
	host_thread := thread.create_and_start_with_poly_data(&host, run_mode)
	joiner_thread := thread.create_and_start_with_poly_data(&joiner, run_mode)
	thread.join(host_thread)
	thread.join(joiner_thread)
	thread.destroy(host_thread)
	thread.destroy(joiner_thread)
	testing.expect(t, host.ok, "the host failed")
	testing.expect(t, joiner.ok, "the joiner failed")
	testing.expect_value(t, g_opened[0].game, HEADLESS.game.name)
	testing.expect_value(t, g_opened[1].game, HEADLESS.game.name)
	testing.expect(t, g_opened[0].compat != 0 && g_opened[0].compat == g_opened[1].compat, "the same build id")
	testing.expect_value(t, g_opened[0].players, 4)
}
