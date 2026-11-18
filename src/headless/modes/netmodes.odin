// The network modes: `session` (in process, on the virtual clock), `relay` and `client` (real UDP between processes),
// and the lobby modes (<name>-host, <name>-client) over a lobby service the game's binary opts into (modes.run's
// `lobbies`), so this package never imports a platform SDK.
package modes

// Used only inside generic procs: @(require) keeps -vet from calling them unused in a program that
// instantiates only some modes (the tests run the lobby modes alone).
@(require) import "core:fmt"
@(require) import "core:log"
@(require) import cnet "core:net"
@(require) import "core:os"
@(require) import "core:strconv"
@(require) import "core:strings"
@(require) import "core:time"

import uheadless "unified:headless"
import "unified:netcode"
@(require) import "unified:sim"

// The `--profile` option as a network profile (ideal, wan, bad); exits through die on an unknown name.
profile_opt :: proc(args: ^Args, fallback: netcode.Network) -> netcode.Profile {
	name := opt_str(args, "profile", netcode.PROFILES[fallback].name)
	profile, ok := netcode.profile_by_name(name)
	if !ok {
		die("%s: unknown profile %q (ideal, wan, bad)", args.mode, name)
	}
	return profile
}

// `--log F`: the relay's recording, streamed to F as ticks are finalized (none without the option).
log_opt :: proc(args: ^Args) -> sim.Log_Sink {
	path := opt_str(args, "log")
	if path == "" {
		return {}
	}
	sink, ok := uheadless.log_sink_file(path)
	if !ok {
		die("%s: cannot write --log %s", args.mode, path)
	}
	return sink
}

// The netcode's log lines on stderr, each led by `name` (the relay, a client): the real-clock modes' processes.
@(private)
console_logger :: proc(name: string) -> log.Logger {
	return log.create_console_logger(.Info, {.Level}, name)
}

// The `session` mode: an in-process relay and `--clients` scripted clients on the virtual clock (session_run): the
// netcode's cost (wall time is the clients' and the relay's CPU time), rollbacks, stalls, step times, bytes per
// second, a late joiner's join; fails on a desync. `uni bench` runs it under `bad` and under `wan` with a late joiner.
mode_session :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	cfg := uheadless.Session_Config {
		clients = opt_int(args, "clients", min(PLAYERS, 4), low = 1, high = PLAYERS),
		profile = profile_opt(args, .Wan),
		ticks   = u32(opt_int(args, "ticks", 1200, low = 64, high = 1_000_000)),
		seed    = seed_opt(args),
	}
	// A profile of its own: --latency and --jitter one way (ms), --loss per mille.
	if latency := opt_int(args, "latency", -1, low = -1, high = 2000); latency >= 0 {
		cfg.profile = {
			name    = "custom",
			latency = i64(latency) * 1000,
			jitter  = i64(opt_int(args, "jitter", 0, low = 0, high = 1000)) * 1000,
			loss    = u32(opt_int(args, "loss", 0, low = 0, high = 1000)),
		}
	}
	if late_join := opt_str(args, "late-join"); late_join != "" {
		parts := strings.split(late_join, "@", context.temp_allocator)
		slot, tick: int
		slot_ok, tick_ok: bool
		if len(parts) == 2 {
			slot, slot_ok = strconv.parse_int(parts[0])
			tick, tick_ok = strconv.parse_int(parts[1])
		}
		if !slot_ok || !tick_ok || slot < 1 || slot >= cfg.clients || tick < 2 || u32(tick) > cfg.ticks {
			die("session: --late-join must be P@T with 1 <= P < clients and 2 <= T <= ticks")
		}
		cfg.late_slot = slot
		cfg.late_tick = u32(tick)
	}
	start := time.tick_now()
	result := uheadless.session_run(headless, cfg)
	defer uheadless.session_result_destroy(&result)
	wall_ms := time.duration_milliseconds(time.tick_since(start))
	ok := result.ok
	if path := opt_str(args, "log"); path != "" {
		ok &&= uheadless.log_write(path, &result.log)
	}
	seconds := f64(cfg.ticks) / f64(headless.game.tick_hz)
	rollbacks, depth_sum, resim_ticks, stall_ticks, resends, client_bytes: int
	steps: [netcode.Step_Kind]int
	step_us: [netcode.Step_Kind]i64
	delays := make([dynamic]string, context.temp_allocator)
	clients := make([dynamic]string, context.temp_allocator)
	for client in result.clients {
		append(&delays, fmt.tprintf("%d", client.delay))
		append(&clients, netcode.client_json(client))
		rollbacks += client.rollbacks
		depth_sum += client.depth_sum
		resim_ticks += client.resim_ticks
		stall_ticks += client.stall_ticks
		client_bytes += client.net.bytes_sent
		resends += client.net.resends
		for kind in netcode.Step_Kind {
			steps[kind] += client.steps[kind]
			step_us[kind] += client.step_us[kind]
		}
	}
	resends += result.relay_net.resends
	fmt.printfln(
		`{{"mode":"session","clients":%d,"profile":"%s","latency_ms":%d,"jitter_ms":%d,"ticks":%d,"tick_hz":%d,"wall_ms":%.1f,"delay":[%s],"rollbacks":%d,"rollback_depth_avg":%.2f,"resim_ticks":%d,"stall_ticks":%d,"replaced_inputs":%d,"desyncs":%d,"steps":{{"verified":%d,"resim":%d,"predicted":%d}},"step_us":{{"verified":%d,"resim":%d,"predicted":%d}},"relay_bytes_per_s":%.0f,"client_bytes_per_s":%.0f,"relay_datagrams_per_s":%.1f,"resends":%d,"late_join":%d,"join_ms":%.1f,"join_bytes":%d,"relay_net":%s,"results":[%s],"ok":%v}}`,
		cfg.clients,
		cfg.profile.name,
		cfg.profile.latency / 1000,
		cfg.profile.jitter / 1000,
		cfg.ticks,
		headless.game.tick_hz,
		wall_ms,
		strings.join(delays[:], ",", context.temp_allocator),
		rollbacks,
		rollbacks > 0 ? f64(depth_sum) / f64(rollbacks) : 0,
		resim_ticks,
		stall_ticks,
		result.replaced,
		result.desyncs,
		steps[.Verified],
		steps[.Resim],
		steps[.Predicted],
		step_us[.Verified],
		step_us[.Resim],
		step_us[.Predicted],
		f64(result.relay_net.bytes_sent) / seconds,
		f64(client_bytes) / seconds / f64(cfg.clients),
		f64(result.relay_net.datagrams_sent) / seconds,
		resends,
		cfg.late_tick,
		f64(result.join_us) / 1000,
		result.join_bytes,
		netcode.channel_stats_json(result.relay_net),
		strings.join(clients[:], ",", context.temp_allocator),
		ok,
	)
	return ok
}

// The `relay` mode: a relay alone on a local UDP port, run until its session ends, for the multi-process test
// (`uni test --suite net`) with `client` processes; fails on a desync.
mode_relay :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	context.logger = console_logger("relay")
	defer log.destroy_console_logger(context.logger)
	port := opt_int(args, "port", required = true, low = 1, high = 65535)
	players := opt_int(args, "players", required = true, low = 1, high = PLAYERS)
	ticks := u32(opt_int(args, "ticks", required = true, low = 1, high = 1_000_000))
	link, link_ok := netcode.udp_listen(port, .Local)
	if !link_ok {
		die("relay: cannot bind UDP port %d", port)
	}
	relay := netcode.relay_create(
		headless.game,
		{seed = 1, ticks = ticks, start_players = players, content = headless.content, recording = log_opt(args)},
	)
	defer netcode.relay_destroy(relay)
	netcode.relay_add_link(relay, link)
	ok := uheadless.run_relay(relay, uheadless.session_timeout_s(ticks, headless.game.tick_hz))
	ok &&= netcode.relay_end_recording(relay)
	fmt.printfln(
		`{{"mode":"relay","desyncs":%d,"replaced_inputs":%d,"finalized":%d,"net":%s,"ok":%v}}`,
		relay.desyncs,
		relay.replaced,
		relay.finalized,
		netcode.channel_stats_json(relay.ch.stats),
		ok,
	)
	return ok && relay.desyncs == 0
}

// The `client` mode: one scripted client connecting to a `relay` process over UDP, behind a netsim profile;
// prints its result as the JSON line.
mode_client :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	address := opt_str(args, "connect", required = true)
	endpoint, endpoint_ok := cnet.parse_endpoint(address)
	if !endpoint_ok || endpoint.port == 0 {
		die("client: --connect must be HOST:PORT (numeric address), got %q", address)
	}
	slot := opt_int(args, "slot", required = true, low = 0, high = PLAYERS - 1)
	ticks := u32(opt_int(args, "ticks", required = true, low = 1, high = 1_000_000))
	context.logger = console_logger(fmt.tprintf("client%d", slot))
	defer log.destroy_console_logger(context.logger)
	link, link_ok := netcode.udp_connect(endpoint)
	if !link_ok {
		die("client: cannot open a UDP socket")
	}
	link = netcode.netsim_wrap(link, profile_opt(args, .Ideal), u32(slot) * 104729 + 17)
	scripted := uheadless.Scripted_User(G){headless, 1}
	client := netcode.client_create(
		headless.game,
		{slot = slot, content = headless.content},
		link,
		uheadless.scripted_hooks(&scripted),
	)
	defer netcode.client_destroy(client)
	ok := uheadless.run_client(client, uheadless.session_timeout_s(ticks, headless.game.tick_hz))
	if client.ticks != 0 && client.ticks != ticks {
		fmt.eprintfln("client: the relay runs %d ticks, --ticks says %d", client.ticks, ticks)
		ok = false
	}
	fmt.println(netcode.client_json(netcode.client_result(client, context.temp_allocator)))
	return ok
}

// The build a lobby mode opens its lobby with: the game's name (or --bucket), its build id and player count.
@(private)
lobby_build :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> netcode.Lobby_Build {
	return {
		game    = opt_str(args, "bucket", headless.game.name),
		compat  = sim.compat_of(headless.game, headless.content),
		version = "headless", // the readable version a joiner on another build is shown
		players = sim.part(G, sim.GAME_PLAYERS),
	}
}

// Pumps the lobby until it is ready (or failed, or `timeout_s` passed).
@(private)
lobby_wait_ready :: proc(lobby: ^netcode.Lobby, timeout_s: f64) -> (status: netcode.Lobby_Status, ok: bool) {
	started := time.tick_now()
	for {
		status = lobby.pump()
		if status.stage == .Ready {
			return status, true
		}
		if status.stage == .Failed || time.duration_seconds(time.tick_since(started)) > timeout_s {
			return status, false
		}
		time.sleep(5 * time.Millisecond)
	}
}

// The `<name>-host` mode: opens a lobby on the game's lobby service, prints its code and hosts a scripted session
// over it; ok once the host verified every tick, `--players` joined and nobody desynced.
mode_lobby_host :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	lobby := args.lobby
	context.logger = console_logger("host")
	defer log.destroy_console_logger(context.logger)
	ticks := u32(opt_int(args, "ticks", required = true, low = 1, high = 1_000_000))
	// --wait-s N: keep the lobby open up to N s until a remote player connects, then start the clock
	// (a joiner far away, e.g. a CI runner that still has to build, plays the whole session).
	wait_s := opt_int(args, "wait-s", 0, low = 0, high = 3600)
	want := opt_int(args, "players", 2, low = 1, high = PLAYERS) // the session counts as played once this many joined
	defer if lobby.shutdown != nil do lobby.shutdown()
	started := time.tick_now()
	link, link_ok := lobby.open_host(lobby_build(headless, args))
	if !link_ok {
		fmt.eprintfln("%s: %s", args.mode, lobby.pump().detail)
		return false
	}
	defer lobby.close()
	link_ours := true // until the host takes it: an early return closes it before the lobby
	defer if link_ours do netcode.link_close(&link)
	status, ok := lobby_wait_ready(lobby, 30)
	if !ok {
		fmt.eprintfln("%s: %s", args.mode, status.detail)
		return false
	}
	code := strings.clone(status.code, context.temp_allocator)
	ready_ms := time.duration_milliseconds(time.tick_since(started))
	fmt.eprintfln("%s: game code %s (as %s, lobby ready in %.0f ms)", args.mode, code, status.local, ready_ms)
	if path := opt_str(args, "code-file"); path != "" {
		_ = os.write_entire_file(path, code)
	}
	if wait_s > 0 {
		waiting := time.tick_now()
		for lobby.pump().peers == 0 {
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
	scripted := uheadless.Scripted_User(G){headless, 1}
	host := netcode.host_create(
		headless.game,
		{seed = 1, ticks = ticks, content = headless.content, recording = log_opt(args)},
		uheadless.scripted_hooks(&scripted),
	)
	defer netcode.host_destroy(host)
	netcode.host_add_link(host, link)
	link_ours = false
	deadline := netcode.now_us() + i64(uheadless.session_timeout_s(ticks, headless.game.tick_hz) * 1e6)
	for !netcode.host_finished(host) {
		now := netcode.now_us()
		wake := netcode.host_step(host, now) // the lobby's link drives the service when it finds nothing to read
		if now > deadline {
			fmt.eprintfln("%s: timeout", args.mode)
			return false
		}
		netcode.sleep_until(wake)
	}
	relay := host.relay
	joined := len(relay.members) // the people who played, the host's own player among them
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

// The `<name>-client` mode: joins a `<name>-host` lobby by `--code` and plays a scripted remote player to the end of
// the host's session.
mode_lobby_client :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	lobby := args.lobby
	context.logger = console_logger("client")
	defer log.destroy_console_logger(context.logger)
	code := opt_str(args, "code", required = true)
	ticks := u32(opt_int(args, "ticks", required = true, low = 1, high = 1_000_000))
	defer if lobby.shutdown != nil do lobby.shutdown()
	started := time.tick_now()
	link, link_ok := lobby.open_join(lobby_build(headless, args), code)
	if !link_ok {
		fmt.eprintfln("%s: %s", args.mode, lobby.pump().detail)
		return false
	}
	defer lobby.close()
	link_ours := true // until the client takes it: an early return closes it before the lobby
	defer if link_ours do netcode.link_close(&link)
	status, ok := lobby_wait_ready(lobby, 30)
	if !ok {
		fmt.eprintfln("%s: %s", args.mode, status.detail)
		return false
	}
	join_ms := time.duration_milliseconds(time.tick_since(started))
	fmt.eprintfln("%s: joined %s as %s, host %s (%.0f ms)", args.mode, status.code, status.local, status.host, join_ms)
	scripted := uheadless.Scripted_User(G){headless, 1}
	client := netcode.client_create(
		headless.game,
		{slot = -1, content = headless.content},
		link,
		uheadless.scripted_hooks(&scripted),
	)
	link_ours = false
	defer netcode.client_destroy(client)
	ok = uheadless.run_client(client, uheadless.session_timeout_s(ticks, headless.game.tick_hz))
	if client.ticks != 0 && client.ticks != ticks {
		fmt.eprintfln("%s: the host runs %d ticks, --ticks says %d", args.mode, client.ticks, ticks)
		ok = false
	}
	fmt.printfln(
		`{{"mode":"%s","join_ms":%.0f,"network":"%s","client":%s,"ok":%v}}`,
		args.mode,
		join_ms,
		lobby.pump().network,
		netcode.client_json(netcode.client_result(client, context.temp_allocator)),
		ok,
	)
	return ok
}
