// The online modes (<name>-host, <name>-client) on the toy over an in-process transport: a hub whose
// endpoint 0 is the host's lobby link and endpoint 1 the joiner's. Real time, two threads, as two processes
// over EOS would run them.
package test_headless

import "base:runtime"
import "core:sync"
import "core:testing"
import "core:thread"

import "unified:headless/modes"
import "unified:netcode"

@(private = "file")
g_hub: ^netcode.Hub

@(private = "file")
g_opened: [2]struct {
	game:   string,
	compat: u64,
} // what the host [0] and the joiner [1] opened the transport with

@(private = "file")
LOOP_ONLINE := modes.Online {
	name = "loop",
	start = proc(args: ^modes.Args) -> bool {return true},
	stop = proc() {},
	open_host = proc(game: string, compat: u64) -> (netcode.Link, bool) {
		g_opened[0] = {game, compat}
		return netcode.loopback_link(g_hub, 0), true
	},
	open_join = proc(game: string, compat: u64, code: string) -> (netcode.Link, bool) {
		g_opened[1] = {game, compat}
		return netcode.loopback_link(g_hub, 1), true
	},
	poll = proc() -> modes.Online_Status {
		// A remote peer counts as connected once a datagram from it waits at the host's endpoint.
		inbox := &g_hub.inboxes[0]
		sync.guard(&inbox.mu)
		return {
			ready = true,
			code  = "loop",
			local = "me",
			host  = "host",
			peers = len(inbox.queue) > 0 ? 1 : 0,
		}
	},
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
		task.ok = modes.mode_online_host(&headless, &LOOP_ONLINE, &task.args)
	} else {
		task.ok = modes.mode_online_client(&headless, &LOOP_ONLINE, &task.args)
	}
}

// `<name>-host --wait-s` waits for a joiner, whose Hello is already queued when the host starts: the host's
// own player still gets player 0 and the joiner joins as player 1; both play to the end (#143). Both open the
// transport with the game's name and the same build id (#304).
@(test)
online_host_waits_for_a_joiner :: proc(t: ^testing.T) {
	g_hub = netcode.hub_create(2)
	defer netcode.hub_destroy(g_hub)
	host := Mode_Task {
		args = {mode = "loop-host"},
		host = true,
		allocator = context.allocator,
	}
	host.args.opts["ticks"] = "64"
	host.args.opts["wait-s"] = "20"
	defer delete(host.args.opts)
	joiner := Mode_Task {
		args = {mode = "loop-client"},
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
}
