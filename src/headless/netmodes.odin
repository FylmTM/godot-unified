package headless

import "core:fmt"
import cnet "core:net"
import "core:strconv"
import "core:strings"

import "unified:netcode"
import "unified:sim"

profile_opt :: proc(a: ^Args) -> netcode.Profile {
	name := opt_str(a, "profile", "ideal")
	p, ok := netcode.profile_by_name(name)
	if !ok {
		die("%s: unknown profile %q (ideal, wan, bad)", a.mode, name)
	}
	return p
}

mode_session :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "clients", "transport", "profile", "ticks", "late-join", "log", "seed")
	cfg := Session_Config {
		clients     = opt_int(a, "clients", required = true, lo = 1, hi = P),
		transport   = opt_str(a, "transport", "loopback"),
		profile     = profile_opt(a),
		ticks       = u32(opt_int(a, "ticks", required = true, lo = 1, hi = 1_000_000)),
		seed        = seed_opt(a),
		late_player = -1,
	}
	if cfg.transport != "loopback" && cfg.transport != "udp" {
		die("session: --transport must be loopback or udp")
	}
	if lj := opt_str(a, "late-join"); lj != "" {
		parts := strings.split(lj, "@", context.temp_allocator)
		p, t: int
		pok, tok: bool
		if len(parts) == 2 {
			p, pok = strconv.parse_int(parts[0])
			t, tok = strconv.parse_int(parts[1])
		}
		if !pok || !tok || p < 1 || p >= cfg.clients || t < 2 || u32(t) > cfg.ticks {
			die("session: --late-join must be P@T with 1 <= P < clients and 2 <= T <= ticks")
		}
		cfg.late_player = p
		cfg.late_tick = u32(t)
	}
	res := session_run(h, cfg)
	defer sim.log_destroy(&res.log)
	defer delete(res.clients)
	ok := res.ok && res.desyncs == 0
	if path := opt_str(a, "log"); path != "" {
		ok &&= sim.log_write(path, &res.log)
	}
	fmt.printfln(
		`{{"mode":"session","clients":[%s],"desyncs":%d,"replaced_inputs":%d,"profile":"%s","transport":"%s","ticks":%d,"relay_net":%s,"ok":%v}}`,
		strings.join(res.clients[:], ",", context.temp_allocator),
		res.desyncs,
		res.replaced,
		cfg.profile.name,
		cfg.transport,
		cfg.ticks,
		res.relay_net,
		ok,
	)
	return ok
}

mode_relay :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "port", "players", "ticks", "log")
	port := opt_int(a, "port", required = true, lo = 1, hi = 65535)
	players := opt_int(a, "players", required = true, lo = 1, hi = P)
	ticks := u32(opt_int(a, "ticks", required = true, lo = 1, hi = 1_000_000))
	link, lok := netcode.udp_listen(port)
	if !lok {
		die("relay: cannot bind UDP port %d", port)
	}
	cfg := netcode.Relay_Config {
		tick_hz       = h.game.tick_hz,
		seed          = 1,
		ticks         = ticks,
		start_players = players,
		name          = "relay",
	}
	r := netcode.relay_create(cfg, I, P)
	defer netcode.relay_destroy(r)
	netcode.relay_add_link(r, link)
	deadline := netcode.now_us() + i64((session_timeout_s(ticks, h.game.tick_hz) + 60) * 1e6)
	ok := run_relay(r, deadline)
	if path := opt_str(a, "log"); path != "" {
		ok &&= sim.log_write(path, &r.log)
	}
	fmt.printfln(
		`{{"mode":"relay","desyncs":%d,"replaced_inputs":%d,"finalized":%d,"net":%s,"ok":%v}}`,
		r.desyncs,
		r.replaced,
		r.finalized,
		netcode.channel_stats_json(r.ch),
		ok,
	)
	return ok && r.desyncs == 0
}

mode_client :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "connect", "player", "ticks", "profile")
	addr := opt_str(a, "connect", required = true)
	ep, eok := cnet.parse_endpoint(addr)
	if !eok || ep.port == 0 {
		die("client: --connect must be HOST:PORT (numeric address), got %q", addr)
	}
	player := opt_int(a, "player", required = true, lo = 0, hi = P - 1)
	ticks := u32(opt_int(a, "ticks", required = true, lo = 1, hi = 1_000_000))
	link, lok := netcode.udp_connect(ep)
	if !lok {
		die("client: cannot open a UDP socket")
	}
	link = netcode.netsim_wrap(link, profile_opt(a), u32(player) * 104729 + 17)
	cfg := netcode.Client_Config {
		slot = player,
		name = fmt.tprintf("client%d", player),
	}
	user := Script_User(S, I, W, P){h, 1}
	c := netcode.client_create(h.game, cfg, link, script_hooks(&user))
	defer netcode.client_destroy(c)
	task := Client_Task(S, I, W, P) {
		c,
		netcode.now_us() + i64((session_timeout_s(ticks, h.game.tick_hz) + 60) * 1e6),
		false,
	}
	run_client(&task)
	ok := task.ok
	if c.ticks != 0 && c.ticks != ticks {
		fmt.eprintfln("client: the relay runs %d ticks, --ticks says %d", c.ticks, ticks)
		ok = false
	}
	fmt.println(netcode.client_json(c))
	return ok
}
