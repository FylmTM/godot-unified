package modes

// Used only inside generic procs: @(require) keeps -vet from calling them unused in a program that
// instantiates only some modes (the tests run the online modes alone).
@(require) import "core:fmt"
@(require) import cnet "core:net"
@(require) import "core:strconv"
@(require) import "core:strings"

import uheadless "unified:headless"
import "unified:netcode"
@(require) import "unified:sim"


// The `--profile` option as a network profile (ideal, wan, bad); exits through die on an unknown name.
profile_opt :: proc(args: ^Args, fallback := "ideal") -> netcode.Profile {
	name := opt_str(args, "profile", fallback)
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

// The `session` mode: an in-process relay and `--clients` scripted clients over loopback or UDP (session_run),
// failing on a desync; prints each client's result and writes the relay's input log when asked.
mode_session :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	check_known(args, "clients", "transport", "profile", "ticks", "late-join", "log", "seed", "clock")
	cfg := uheadless.Session_Config {
		clients     = opt_int(args, "clients", required = true, low = 1, high = PLAYERS),
		transport   = opt_str(args, "transport", "loopback"),
		profile     = profile_opt(args),
		ticks       = u32(opt_int(args, "ticks", required = true, low = 1, high = 1_000_000)),
		seed        = seed_opt(args),
		late_player = -1,
	}
	if cfg.transport != "loopback" && cfg.transport != "udp" {
		die("session: --transport must be loopback or udp")
	}
	switch opt_str(args, "clock", "real") {
	case "real":
	case "virtual":
		cfg.virtual = true
		if cfg.transport != "loopback" {
			die("session: --clock virtual needs --transport loopback")
		}
	case:
		die("session: --clock must be real or virtual")
	}
	if late_join := opt_str(args, "late-join"); late_join != "" {
		parts := strings.split(late_join, "@", context.temp_allocator)
		player, tick: int
		player_ok, tick_ok: bool
		if len(parts) == 2 {
			player, player_ok = strconv.parse_int(parts[0])
			tick, tick_ok = strconv.parse_int(parts[1])
		}
		if !player_ok || !tick_ok || player < 1 || player >= cfg.clients || tick < 2 || u32(tick) > cfg.ticks {
			die("session: --late-join must be P@T with 1 <= P < clients and 2 <= T <= ticks")
		}
		cfg.late_player = player
		cfg.late_tick = u32(tick)
	}
	result := uheadless.session_run(headless, cfg)
	defer uheadless.session_result_destroy(&result)
	ok := result.ok
	if path := opt_str(args, "log"); path != "" {
		ok &&= uheadless.log_write(path, &result.log)
	}
	clients := make([]string, len(result.clients), context.temp_allocator)
	for client, i in result.clients {
		clients[i] = netcode.client_json(client)
	}
	fmt.printfln(
		`{{"mode":"session","clients":[%s],"desyncs":%d,"replaced_inputs":%d,"profile":"%s","transport":"%s","clock":"%s","ticks":%d,"relay_net":%s,"ok":%v}}`,
		strings.join(clients, ",", context.temp_allocator),
		result.desyncs,
		result.replaced,
		cfg.profile.name,
		cfg.transport,
		cfg.virtual ? "virtual" : "real",
		cfg.ticks,
		netcode.channel_stats_json(result.relay_net),
		ok,
	)
	return ok
}

// The `relay` mode: a relay alone on a UDP port, run until its session ends, for the multi-process test
// (`uni test --suite net`) with `client` processes; fails on a desync.
mode_relay :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	Input :: sim.part(G, sim.GAME_INPUT)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	check_known(args, "port", "players", "ticks", "log", "bind")
	port := opt_int(args, "port", required = true, low = 1, high = 65535)
	scope: netcode.Udp_Scope
	switch bind := opt_str(args, "bind", "local"); bind {
	case "local":
		scope = .Local
	case "lan":
		scope = .Lan
	case:
		die("relay: --bind must be local or lan, got %q", bind)
	}
	players := opt_int(args, "players", required = true, low = 1, high = PLAYERS)
	ticks := u32(opt_int(args, "ticks", required = true, low = 1, high = 1_000_000))
	link, link_ok := netcode.udp_listen(port, scope)
	if !link_ok {
		die("relay: cannot bind UDP port %d", port)
	}
	cfg := netcode.Relay_Config {
		tick_hz       = headless.game.tick_hz,
		seed          = 1,
		ticks         = ticks,
		start_players = players,
		compat        = sim.compat_of(headless.game, headless.content),
		content       = sim.content_hash(headless.content),
		name          = "relay",
		recording     = log_opt(args),
	}
	relay := netcode.relay_create(cfg, G)
	defer netcode.relay_destroy(relay)
	netcode.relay_add_link(relay, link)
	deadline := netcode.now_us() + i64((uheadless.session_timeout_s(ticks, headless.game.tick_hz) + 60) * 1e6)
	ok := uheadless.run_relay(relay, deadline)
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
	check_known(args, "connect", "slot", "ticks", "profile", "token")
	address := opt_str(args, "connect", required = true)
	endpoint, endpoint_ok := cnet.parse_endpoint(address)
	if !endpoint_ok || endpoint.port == 0 {
		die("client: --connect must be HOST:PORT (numeric address), got %q", address)
	}
	slot := opt_int(args, "slot", required = true, low = 0, high = PLAYERS - 1)
	ticks := u32(opt_int(args, "ticks", required = true, low = 1, high = 1_000_000))
	token, token_ok := token_of(opt_str(args, "token"))
	if !token_ok {
		die("client: --token must be 32 hex digits")
	}
	link, link_ok := netcode.udp_connect(endpoint)
	if !link_ok {
		die("client: cannot open a UDP socket")
	}
	link = netcode.netsim_wrap(link, profile_opt(args), u32(slot) * 104729 + 17)
	cfg := netcode.Client_Config {
		slot    = slot,
		content = headless.content,
		name    = fmt.tprintf("client%d", slot),
		token   = token,
	}
	scripted := uheadless.Scripted_User(G){headless, 1}
	client := netcode.client_create(headless.game, cfg, link, uheadless.scripted_hooks(&scripted))
	defer netcode.client_destroy(client)
	task := uheadless.Client_Task(G) {
		client,
		netcode.now_us() + i64((uheadless.session_timeout_s(ticks, headless.game.tick_hz) + 60) * 1e6),
		false,
	}
	uheadless.run_client(&task)
	ok := task.ok
	if client.ticks != 0 && client.ticks != ticks {
		fmt.eprintfln("client: the relay runs %d ticks, --ticks says %d", client.ticks, ticks)
		ok = false
	}
	fmt.println(netcode.client_json(netcode.client_result(client, context.temp_allocator)))
	return ok
}
