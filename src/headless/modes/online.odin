// Online modes, the game topology end to end without Godot, over a transport the game's binary
// plugs in (modes.run's `online`; e.g. EOS lobbies + P2P), so this package never imports a platform SDK.
// `<name>-host` runs a host (relay + the host's own player in slot 0) whose relay also serves the
// transport's link, opens a lobby and prints its code; `<name>-client` joins by code and plays a
// remote slot (a late join: the host's clock is already running). Inputs are the game's script.
package modes

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "unified:headless"
import "unified:netcode"
import "unified:sim"


// An online transport (lobby codes + datagrams), as a game's headless binary supplies it.
Online :: struct {
	name:      string, // the modes are <name>-host and <name>-client
	bucket:    string, // the default lobby bucket (lobbies match only within one; --bucket overrides)
	options:   []string, // extra --options `start` reads (with opt_str / opt_int)
	// Starts the transport; false (after printing why) when it is unavailable.
	start:     proc(a: ^Args) -> bool,
	// Ends it (the links are closed already).
	stop:      proc(),
	open_host: proc(bucket: string) -> (netcode.Link, bool),
	open_join: proc(bucket, code: string) -> (netcode.Link, bool),
	// Pumps the transport and reports where it stands (strings temp-allocated).
	poll:      proc() -> Online_Status,
}

Online_Status :: struct {
	ready:   bool, // the lobby is up (host) or joined and connected (client)
	failed:  bool,
	detail:  string, // why it failed, or what it is doing
	code:    string, // the lobby code, once known
	local:   string, // our id on the transport
	host:    string, // client: the host's id
	network: string, // client: how the connection to the host goes
	peers:   int, // connected remote peers
}

// Pumps the transport until it is ready (or failed, or `timeout_s` passed).
@(private)
online_wait_ready :: proc(o: ^Online, timeout_s: f64) -> (st: Online_Status, ok: bool) {
	sw := time.tick_now()
	for {
		st = o.poll()
		if st.ready {
			return st, true
		}
		if st.failed || time.duration_seconds(time.tick_since(sw)) > timeout_s {
			return st, false
		}
		time.sleep(5 * time.Millisecond)
	}
}

@(private)
online_known :: proc(a: ^Args, o: ^Online, own: ..string) {
	known := make([dynamic]string, context.temp_allocator)
	append(&known, ..own)
	append(&known, ..o.options)
	check_known(a, ..known[:])
}

mode_online_host :: proc(h: ^headless.Headless($S, $I, $W, $P), o: ^Online, a: ^Args) -> bool {
	online_known(a, o, "ticks", "code-file", "log", "players", "wait-s", "bucket")
	ticks := u32(opt_int(a, "ticks", required = true, lo = 1, hi = 1_000_000))
	// --wait-s N: keep the lobby open up to N s until a remote player connects, then start the clock
	// (a joiner far away, e.g. a CI runner that still has to build, plays the whole session).
	wait_s := opt_int(a, "wait-s", 0, lo = 0, hi = 3600)
	want := opt_int(a, "players", 2, lo = 1, hi = P) // the session counts as played once this many joined
	if !o.start(a) {
		return false
	}
	defer o.stop()
	t0 := time.tick_now()
	link, lok := o.open_host(opt_str(a, "bucket", o.bucket))
	if !lok {
		fmt.eprintfln("%s: %s", a.mode, o.poll().detail)
		return false
	}
	st, ok := online_wait_ready(o, 30)
	if !ok {
		fmt.eprintfln("%s: %s", a.mode, st.detail)
		return false
	}
	code := strings.clone(st.code)
	defer delete(code)
	ready_ms := time.duration_milliseconds(time.tick_since(t0))
	fmt.eprintfln("%s: game code %s (as %s, lobby ready in %.0f ms)", a.mode, code, st.local, ready_ms)
	if path := opt_str(a, "code-file"); path != "" {
		_ = os.write_entire_file(path, code)
	}
	if wait_s > 0 {
		sw := time.tick_now()
		for o.poll().peers == 0 {
			if time.duration_seconds(time.tick_since(sw)) > f64(wait_s) {
				fmt.eprintfln("%s: nobody joined in %d s", a.mode, wait_s)
				return false
			}
			time.sleep(5 * time.Millisecond)
		}
		fmt.eprintfln(
			"%s: a player connected after %.1f s, starting",
			a.mode,
			time.duration_seconds(time.tick_since(sw)),
		)
	}
	user := headless.Script_User(S, I, W, P){h, 1}
	host := netcode.host_create(
		h.game,
		netcode.Host_Config{seed = 1, ticks = ticks, name = "host", content = h.content},
		headless.script_hooks(&user),
	)
	defer netcode.host_destroy(host)
	netcode.host_add_link(host, link)
	deadline := netcode.now_us() + i64((headless.session_timeout_s(ticks, h.game.tick_hz) + 60) * 1e6)
	for !netcode.host_finished(host) {
		now := netcode.now_us()
		wake := netcode.host_step(host, now)
		if now > deadline {
			fmt.eprintfln("%s: timeout", a.mode)
			return false
		}
		netcode.sleep_until(wake)
	}
	r := host.relay
	joined := 0
	for from in r.active_from {
		if from != 0 {
			joined += 1
		}
	}
	ok = host.client.verified == ticks && joined >= want
	if path := opt_str(a, "log"); path != "" {
		ok &&= sim.log_write(path, &r.log)
	}
	fmt.printfln(
		`{{"mode":"%s","code":"%s","lobby_ready_ms":%.0f,"players":%d,"desyncs":%d,"finalized":%d,"net":%s,"client":%s,"ok":%v}}`,
		a.mode,
		code,
		ready_ms,
		joined,
		r.desyncs,
		r.finalized,
		netcode.channel_stats_json(r.ch.stats),
		netcode.client_json(netcode.client_result(host.client, context.temp_allocator)),
		ok,
	)
	return ok && r.desyncs == 0
}

mode_online_client :: proc(h: ^headless.Headless($S, $I, $W, $P), o: ^Online, a: ^Args) -> bool {
	online_known(a, o, "code", "ticks", "bucket")
	code := opt_str(a, "code", required = true)
	ticks := u32(opt_int(a, "ticks", required = true, lo = 1, hi = 1_000_000))
	if !o.start(a) {
		return false
	}
	defer o.stop()
	t0 := time.tick_now()
	link, lok := o.open_join(opt_str(a, "bucket", o.bucket), code)
	if !lok {
		fmt.eprintfln("%s: %s", a.mode, o.poll().detail)
		return false
	}
	st, ok := online_wait_ready(o, 30)
	if !ok {
		fmt.eprintfln("%s: %s", a.mode, st.detail)
		return false
	}
	join_ms := time.duration_milliseconds(time.tick_since(t0))
	fmt.eprintfln("%s: joined %s as %s, host %s (%.0f ms)", a.mode, st.code, st.local, st.host, join_ms)
	user := headless.Script_User(S, I, W, P){h, 1}
	c := netcode.client_create(
		h.game,
		netcode.Client_Config{slot = -1, name = "client", content = h.content},
		link,
		headless.script_hooks(&user),
	)
	defer netcode.client_destroy(c)
	task := headless.Client_Task(S, I, W, P) {
		c,
		netcode.now_us() + i64((headless.session_timeout_s(ticks, h.game.tick_hz) + 60) * 1e6),
		false,
	}
	headless.run_client(&task)
	ok = task.ok
	if c.ticks != 0 && c.ticks != ticks {
		fmt.eprintfln("%s: the host runs %d ticks, --ticks says %d", a.mode, c.ticks, ticks)
		ok = false
	}
	st = o.poll()
	fmt.printfln(
		`{{"mode":"%s","join_ms":%.0f,"network":"%s","client":%s,"ok":%v}}`,
		a.mode,
		join_ms,
		st.network,
		netcode.client_json(netcode.client_result(c, context.temp_allocator)),
		ok,
	)
	return ok
}
