// Online modes, the game topology end to end without Godot, over a transport the game's binary
// plugs in (modes.run's `online`; e.g. EOS lobbies + P2P), so this package never imports a platform SDK.
// `<name>-host` runs a host (relay + the host's own player 0) whose relay also serves the
// transport's link, opens a lobby and prints its code; `<name>-client` joins by code and plays a
// remote player (a late join: the host's clock is already running). Inputs are the game's script.
package modes

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import uheadless "unified:headless"
import "unified:netcode"


// An online transport (lobby codes + datagrams), as a game's headless binary supplies it.
Online :: struct {
	name:      string, // the modes are <name>-host and <name>-client
	bucket:    string, // the default lobby bucket (lobbies match only within one; --bucket overrides)
	options:   []string, // extra --options `start` reads (with opt_str / opt_int)
	// Starts the transport; false (after printing why) when it is unavailable.
	start:     proc(args: ^Args) -> bool,
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
online_wait_ready :: proc(online: ^Online, timeout_s: f64) -> (status: Online_Status, ok: bool) {
	started := time.tick_now()
	for {
		status = online.poll()
		if status.ready {
			return status, true
		}
		if status.failed || time.duration_seconds(time.tick_since(started)) > timeout_s {
			return status, false
		}
		time.sleep(5 * time.Millisecond)
	}
}

@(private)
online_known :: proc(args: ^Args, online: ^Online, own: ..string) {
	known := make([dynamic]string, context.temp_allocator)
	append(&known, ..own)
	append(&known, ..online.options)
	check_known(args, ..known[:])
}

mode_online_host :: proc(
	headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS),
	online: ^Online,
	args: ^Args,
) -> bool {
	online_known(args, online, "ticks", "code-file", "log", "players", "wait-s", "bucket")
	ticks := u32(opt_int(args, "ticks", required = true, low = 1, high = 1_000_000))
	// --wait-s N: keep the lobby open up to N s until a remote player connects, then start the clock
	// (a joiner far away, e.g. a CI runner that still has to build, plays the whole session).
	wait_s := opt_int(args, "wait-s", 0, low = 0, high = 3600)
	want := opt_int(args, "players", 2, low = 1, high = PLAYERS) // the session counts as played once this many joined
	if !online.start(args) {
		return false
	}
	defer online.stop()
	started := time.tick_now()
	link, link_ok := online.open_host(opt_str(args, "bucket", online.bucket))
	if !link_ok {
		fmt.eprintfln("%s: %s", args.mode, online.poll().detail)
		return false
	}
	status, ok := online_wait_ready(online, 30)
	if !ok {
		fmt.eprintfln("%s: %s", args.mode, status.detail)
		return false
	}
	code := strings.clone(status.code)
	defer delete(code)
	ready_ms := time.duration_milliseconds(time.tick_since(started))
	fmt.eprintfln("%s: game code %s (as %s, lobby ready in %.0f ms)", args.mode, code, status.local, ready_ms)
	if path := opt_str(args, "code-file"); path != "" {
		_ = os.write_entire_file(path, code)
	}
	if wait_s > 0 {
		waiting := time.tick_now()
		for online.poll().peers == 0 {
			if time.duration_seconds(time.tick_since(waiting)) > f64(wait_s) {
				fmt.eprintfln("%s: nobody joined in %d s", args.mode, wait_s)
				return false
			}
			time.sleep(5 * time.Millisecond)
		}
		fmt.eprintfln(
			"%s: a player connected after %.1f s, starting",
			args.mode,
			time.duration_seconds(time.tick_since(waiting)),
		)
	}
	scripted := uheadless.Scripted_User(State, Input, World, PLAYERS){headless, 1}
	host := netcode.host_create(headless.game, netcode.Host_Config {
			seed      = 1,
			ticks     = ticks,
			name      = "host",
			content   = headless.content,
			recording = log_opt(args),
		}, uheadless.scripted_hooks(&scripted))
	defer netcode.host_destroy(host)
	netcode.host_add_link(host, link)
	deadline := netcode.now_us() + i64((uheadless.session_timeout_s(ticks, headless.game.tick_hz) + 60) * 1e6)
	for !netcode.host_finished(host) {
		now := netcode.now_us()
		wake := netcode.host_step(host, now)
		if now > deadline {
			fmt.eprintfln("%s: timeout", args.mode)
			return false
		}
		netcode.sleep_until(wake)
	}
	relay := host.relay
	joined := 0
	for from in relay.active_from {
		if from != 0 {
			joined += 1
		}
	}
	ok = host.client.verified == ticks && joined >= want
	ok &&= netcode.relay_end_recording(relay)
	fmt.printfln(
		`{{"mode":"%s","code":"%s","lobby_ready_ms":%.0f,"players":%d,"desyncs":%d,"finalized":%d,"net":%s,"client":%s,"ok":%v}}`,
		args.mode,
		code,
		ready_ms,
		joined,
		relay.desyncs,
		relay.finalized,
		netcode.channel_stats_json(relay.ch.stats),
		netcode.client_json(netcode.client_result(host.client, context.temp_allocator)),
		ok,
	)
	return ok && relay.desyncs == 0
}

mode_online_client :: proc(
	headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS),
	online: ^Online,
	args: ^Args,
) -> bool {
	online_known(args, online, "code", "ticks", "bucket")
	code := opt_str(args, "code", required = true)
	ticks := u32(opt_int(args, "ticks", required = true, low = 1, high = 1_000_000))
	if !online.start(args) {
		return false
	}
	defer online.stop()
	started := time.tick_now()
	link, link_ok := online.open_join(opt_str(args, "bucket", online.bucket), code)
	if !link_ok {
		fmt.eprintfln("%s: %s", args.mode, online.poll().detail)
		return false
	}
	status, ok := online_wait_ready(online, 30)
	if !ok {
		fmt.eprintfln("%s: %s", args.mode, status.detail)
		return false
	}
	join_ms := time.duration_milliseconds(time.tick_since(started))
	fmt.eprintfln("%s: joined %s as %s, host %s (%.0f ms)", args.mode, status.code, status.local, status.host, join_ms)
	scripted := uheadless.Scripted_User(State, Input, World, PLAYERS){headless, 1}
	client := netcode.client_create(headless.game, netcode.Client_Config {
			player  = -1,
			name    = "client",
			content = headless.content,
		}, link, uheadless.scripted_hooks(&scripted))
	defer netcode.client_destroy(client)
	task := uheadless.Client_Task(State, Input, World, PLAYERS) {
		client,
		netcode.now_us() + i64((uheadless.session_timeout_s(ticks, headless.game.tick_hz) + 60) * 1e6),
		false,
	}
	uheadless.run_client(&task)
	ok = task.ok
	if client.ticks != 0 && client.ticks != ticks {
		fmt.eprintfln("%s: the host runs %d ticks, --ticks says %d", args.mode, client.ticks, ticks)
		ok = false
	}
	status = online.poll()
	fmt.printfln(
		`{{"mode":"%s","join_ms":%.0f,"network":"%s","client":%s,"ok":%v}}`,
		args.mode,
		join_ms,
		status.network,
		netcode.client_json(netcode.client_result(client, context.temp_allocator)),
		ok,
	)
	return ok
}
