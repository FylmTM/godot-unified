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

// A `--profile` option's network profile (ideal, wan, bad; "": `fallback`); exits through die on an unknown name.
@(private)
check_profile :: proc(args: ^Args, name: string, fallback: netcode.Network) -> netcode.Profile {
	profile, ok := netcode.profile_by_name(name if name != "" else netcode.PROFILES[fallback].name)
	if !ok {
		die("%s: unknown profile %q (ideal, wan, bad)", args.mode, name)
	}
	return profile
}

// A `--log F` option: the relay's recording, streamed to F as ticks are finalized (none without the option).
@(private)
log_sink :: proc(args: ^Args, path: string) -> sim.Log_Sink {
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

@(private)
Session_Options :: struct {
	clients:   int,
	ticks:     int `hint:"T"`,
	profile:   string `hint:"ideal|wan|bad"`,
	latency:   int `hint:"MS"`, // a profile of its own: one way, with --jitter (ms) and --loss (per mille)
	jitter:    int `hint:"MS"`,
	loss:      int `hint:"PERMILLE"`,
	late_join: string `hint:"P@T|last@T"`, // slot P (last: the last client; none with one client) joins at tick T
	script:    string `hint:"steady|churn"`,
	log:       string `hint:"F"`,
	seed:      int `hint:"S"`,
	checksums: bool, // each client's checksums in its result (otherwise left out: thousands for a long run)
}

// The `session` mode: an in-process relay and `--clients` scripted clients on the virtual clock (session_run): the
// netcode's cost (wall time is the clients' and the relay's CPU time), rollbacks, stalls, step times, bytes per
// second, a late joiner's join; fails on a desync. `uni bench` runs it under `bad` and under `wan` with a late joiner.
@(private)
mode_session :: proc(game: ^$G, args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	options := Session_Options {
		clients = min(PLAYERS, 4),
		ticks   = 1200,
		latency = -1,
		script  = "steady",
		seed    = 1,
	}
	parse(args, &options)
	in_range(args, "clients", options.clients, 1, PLAYERS)
	in_range(args, "ticks", options.ticks, 64, 1_000_000)
	cfg := uheadless.Session_Config {
		clients = options.clients,
		profile = check_profile(args, options.profile, .Wan),
		ticks   = u32(options.ticks),
		seed    = check_seed(args, options.seed),
		dev     = true, // zones per client step in each client's JSON
	}
	if options.latency >= 0 {
		in_range(args, "latency", options.latency, 0, 2000)
		in_range(args, "jitter", options.jitter, 0, 1000)
		in_range(args, "loss", options.loss, 0, 1000)
		cfg.profile = {
			name    = "custom",
			latency = i64(options.latency) * 1000,
			jitter  = i64(options.jitter) * 1000,
			loss    = u32(options.loss),
		}
	}
	switch script := options.script; script {
	case "steady":
	case "churn":
		cfg.churn = true
	case:
		die("session: --script must be steady or churn, got %q", script)
	}
	if late_join := options.late_join; late_join != "" {
		parts := strings.split(late_join, "@", context.temp_allocator)
		slot, tick: int
		slot_ok, tick_ok: bool
		if len(parts) == 2 {
			if parts[0] == "last" {
				slot, slot_ok = cfg.clients - 1, true
			} else {
				slot, slot_ok = strconv.parse_int(parts[0])
			}
			tick, tick_ok = strconv.parse_int(parts[1])
		}
		last_alone := slot_ok && parts[0] == "last" && cfg.clients == 1 // one client: nobody to join late
		if !last_alone {
			if !slot_ok || !tick_ok || slot < 1 || slot >= cfg.clients || tick < 2 || u32(tick) > cfg.ticks {
				die("session: --late-join must be P@T or last@T with 1 <= P < clients and 2 <= T <= ticks")
			}
			cfg.late_slot = slot
			cfg.late_tick = u32(tick)
			cfg.late_as_player = true // the join row times what a player waits
		}
	}
	start := time.tick_now()
	result := uheadless.session_run(game, cfg)
	defer uheadless.session_result_destroy(&result)
	wall_ms := time.duration_milliseconds(time.tick_since(start))
	ok := result.ok
	if path := options.log; path != "" {
		ok &&= uheadless.log_write(path, &result.log)
	}
	seconds := f64(cfg.ticks) / f64(game.tick_hz)
	rollbacks, depth_sum, resim_ticks, stall_ticks, resends, client_bytes: int
	steps: [netcode.Step_Kind]int
	step_us: [netcode.Step_Kind]i64
	client_steps: netcode.Durations // every client's, merged
	delays := make([dynamic]string, context.temp_allocator)
	clients := make([dynamic]string, context.temp_allocator)
	for client in result.clients {
		append(&delays, fmt.tprintf("%d", client.delay))
		shown := client
		if !options.checksums do shown.checksums = nil
		append(&clients, netcode.client_json(shown))
		rollbacks += client.rollbacks
		depth_sum += client.depth_sum
		resim_ticks += client.resim_ticks
		stall_ticks += client.stall_ticks
		client_bytes += client.net.bytes_sent
		resends += client.net.resends
		netcode.durations_merge(&client_steps, client.client_steps)
		for kind in netcode.Step_Kind {
			steps[kind] += client.steps[kind]
			step_us[kind] += client.step_us[kind]
		}
	}
	resends += result.relay_net.resends
	joiner: netcode.Client_Result // the late joiner's (zero: none)
	if cfg.late_tick != 0 do joiner = result.clients[cfg.late_slot]
	fmt.printfln(
		`{{"mode":"session","ok":%v,"desyncs":%d,"join_ms":%.1f,"clients":%d,"profile":"%s","script":"%s","latency_ms":%d,"jitter_ms":%d,"ticks":%d,"tick_hz":%d,"wall_ms":%.1f,"delay":[%s],"rollbacks":%d,"rollback_depth_avg":%.2f,"resim_ticks":%d,"stall_ticks":%d,"replaced_inputs":%d,"steps":{{"verified":%d,"resim":%d,"predicted":%d}},"step_us":{{"verified":%d,"resim":%d,"predicted":%d}},"relay_bytes_per_s":%.0f,"client_bytes_per_s":%.0f,"relay_datagrams_per_s":%.1f,"resends":%d,"client_step_us":{{"p99":%d,"max":%d}},"late_join":%d,"join_bytes":%d,"join_snapshot_bytes":%d,"join_snapshot_sent":%d,"join_transfer_ms":%.1f,"join_step_max_us":%d,"relay_net":%s,"results":[%s]}}`,
		ok,
		result.desyncs,
		f64(result.join_us) / 1000,
		cfg.clients,
		cfg.profile.name,
		cfg.churn ? "churn" : "steady",
		cfg.profile.latency / 1000,
		cfg.profile.jitter / 1000,
		cfg.ticks,
		game.tick_hz,
		wall_ms,
		strings.join(delays[:], ",", context.temp_allocator),
		rollbacks,
		rollbacks > 0 ? f64(depth_sum) / f64(rollbacks) : 0,
		resim_ticks,
		stall_ticks,
		result.replaced,
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
		netcode.durations_percentile(client_steps, 99),
		client_steps.max_us,
		joiner.join_tick,
		result.join_bytes,
		joiner.snapshot_bytes,
		joiner.snapshot_sent,
		f64(joiner.snapshot_us) / 1000,
		joiner.client_steps.max_us,
		netcode.channel_stats_json(result.relay_net),
		strings.join(clients[:], ",", context.temp_allocator),
	)
	return ok
}

@(private)
Relay_Options :: struct {
	port:    int `args:"required" hint:"P"`,
	players: int `args:"required"`,
	ticks:   int `args:"required" hint:"T"`,
	log:     string `hint:"F"`,
}

// The `relay` mode: a relay alone on a local UDP port, run until its session ends, for the multi-process test
// (`uni test --suite net`) with `client` processes; fails on a desync.
@(private)
mode_relay :: proc(game: ^$G, args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	context.logger = console_logger("relay")
	defer log.destroy_console_logger(context.logger)
	options: Relay_Options
	parse(args, &options)
	in_range(args, "port", options.port, 1, 65535)
	in_range(args, "players", options.players, 1, PLAYERS)
	in_range(args, "ticks", options.ticks, 1, 1_000_000)
	port, players, ticks := options.port, options.players, u32(options.ticks)
	link, link_ok := netcode.udp_listen(port, .Local)
	if !link_ok {
		die("relay: cannot bind UDP port %d", port)
	}
	relay := netcode.relay_create(
		game,
		{seed = 1, ticks = ticks, start_players = players, recording = log_sink(args, options.log)},
	)
	defer netcode.relay_destroy(relay)
	netcode.relay_add_link(relay, link)
	ok := uheadless.run_relay(relay, uheadless.session_timeout_s(ticks, game.tick_hz))
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

@(private)
Client_Options :: struct {
	connect: string `args:"required" hint:"HOST:PORT"`,
	slot:    int `args:"required" hint:"I"`,
	ticks:   int `args:"required" hint:"T"`,
	profile: string `hint:"ideal|wan|bad"`,
}

// The `client` mode: one scripted client connecting to a `relay` process over UDP, behind a netsim profile;
// prints its result as the JSON line.
@(private)
mode_client :: proc(game: ^$G, args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	options: Client_Options
	parse(args, &options)
	address := options.connect
	endpoint, endpoint_ok := cnet.parse_endpoint(address)
	if !endpoint_ok || endpoint.port == 0 {
		die("client: --connect must be HOST:PORT (numeric address), got %q", address)
	}
	in_range(args, "slot", options.slot, 0, PLAYERS - 1)
	in_range(args, "ticks", options.ticks, 1, 1_000_000)
	slot, ticks := options.slot, u32(options.ticks)
	context.logger = console_logger(fmt.tprintf("client%d", slot))
	defer log.destroy_console_logger(context.logger)
	link, link_ok := netcode.udp_connect(endpoint)
	if !link_ok {
		die("client: cannot open a UDP socket")
	}
	link = netcode.netsim_wrap(link, check_profile(args, options.profile, .Ideal), u32(slot) * 104729 + 17)
	scripted := uheadless.Scripted_User(G) {
		game = game,
		seed = 1,
	}
	client := netcode.client_create(game, {slot = slot}, link, uheadless.scripted_hooks(&scripted))
	defer netcode.client_destroy(client)
	ok := uheadless.run_client(client, uheadless.session_timeout_s(ticks, game.tick_hz))
	if client.ticks != 0 && client.ticks != ticks {
		fmt.eprintfln("client: the relay runs %d ticks, --ticks says %d", client.ticks, ticks)
		ok = false
	}
	fmt.println(netcode.client_json(netcode.client_result(client, context.temp_allocator)))
	return ok
}

// The build a lobby mode opens its lobby with: the game's name (or `bucket`), its build id and player count.
@(private)
lobby_build :: proc(game: ^$G, bucket: string) -> netcode.Lobby_Build {
	return {
		game    = bucket if bucket != "" else game.name,
		compat  = sim.compat_of(game),
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

// A `<name>-host` mode's options. `--wait-s N`: keep the lobby open up to N s until a remote player connects, then
// start the clock (a joiner far away, e.g. a CI runner that still has to build, plays the whole session).
// `--players N`: the session counts as played once this many joined.
@(private)
Lobby_Host_Options :: struct {
	ticks:     int `args:"required" hint:"T"`,
	wait_s:    int,
	players:   int,
	bucket:    string `hint:"B"`,
	code_file: string `hint:"F"`,
	log:       string `hint:"F"`,
}

// The `<name>-host` mode: opens a lobby on the game's lobby service, prints its code and hosts a scripted session
// over it; ok once the host verified every tick, `--players` joined and nobody desynced.
mode_lobby_host :: proc(game: ^$G, args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	lobby := args.lobby
	context.logger = console_logger("host")
	defer log.destroy_console_logger(context.logger)
	options := Lobby_Host_Options {
		players = 2,
	}
	parse(args, &options)
	in_range(args, "ticks", options.ticks, 1, 1_000_000)
	in_range(args, "wait-s", options.wait_s, 0, 3600)
	in_range(args, "players", options.players, 1, PLAYERS)
	ticks, wait_s, want := u32(options.ticks), options.wait_s, options.players
	defer if lobby.shutdown != nil do lobby.shutdown()
	started := time.tick_now()
	link, link_ok := lobby.open_host(lobby_build(game, options.bucket))
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
	if path := options.code_file; path != "" {
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
	scripted := uheadless.Scripted_User(G) {
		game = game,
		seed = 1,
	}
	host := netcode.host_create(
		game,
		{seed = 1, ticks = ticks, recording = log_sink(args, options.log)},
		uheadless.scripted_hooks(&scripted),
	)
	defer netcode.host_destroy(host)
	netcode.host_add_link(host, link)
	link_ours = false
	deadline := netcode.now_us() + i64(uheadless.session_timeout_s(ticks, game.tick_hz) * 1e6)
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

// A `<name>-client` mode's options.
@(private)
Lobby_Client_Options :: struct {
	code:   string `args:"required" hint:"CODE"`,
	ticks:  int `args:"required" hint:"T"`,
	bucket: string `hint:"B"`,
}

// The `<name>-client` mode: joins a `<name>-host` lobby by `--code` and plays a scripted remote player to the end of
// the host's session.
mode_lobby_client :: proc(game: ^$G, args: ^Args) -> bool {
	lobby := args.lobby
	context.logger = console_logger("client")
	defer log.destroy_console_logger(context.logger)
	options: Lobby_Client_Options
	parse(args, &options)
	in_range(args, "ticks", options.ticks, 1, 1_000_000)
	code, ticks := options.code, u32(options.ticks)
	defer if lobby.shutdown != nil do lobby.shutdown()
	started := time.tick_now()
	link, link_ok := lobby.open_join(lobby_build(game, options.bucket), code)
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
	scripted := uheadless.Scripted_User(G) {
		game = game,
		seed = 1,
	}
	client := netcode.client_create(game, {slot = -1}, link, uheadless.scripted_hooks(&scripted))
	link_ours = false
	defer netcode.client_destroy(client)
	ok = uheadless.run_client(client, uheadless.session_timeout_s(ticks, game.tick_hz))
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
