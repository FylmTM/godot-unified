// Online modes over EOS (spec/eos.md): the relay hosts a lobby and prints its code, clients join by
// code. Same relay/client as the UDP modes, only the link differs. Two processes on one machine
// need two Product User IDs: run one of them with UNIFIED_EOS_FRESH_DEVICE=1.
package main

import "core:fmt"
import "core:os"
import "core:time"

import "../eos"
import "../netcode"
import "../sim"

EOS_BUCKET :: "unified-cli/1"

eos_start :: proc(a: ^Args) -> bool {
	rc := eos.Relay_Control.Allow_Relays
	switch opt_str(a, "relays", "allow") {
	case "allow":
	case "force":
		rc = .Force_Relays
	case "none":
		rc = .No_Relays
	case:
		die("unified %s: --relays must be allow, force or none", a.mode)
	}
	eos.disable_keychain_prompts()
	if !eos.init({product_name = "unified-cli", product_version = "1", relay_control = rc}) {
		st := eos.status()
		fmt.eprintfln("unified %s: EOS unavailable: %s", a.mode, st.detail)
		return false
	}
	return true
}

// Polls EOS until the session is Ready (or failed, or `timeout_s` passed).
eos_wait_ready :: proc(timeout_s: f64) -> (st: eos.Status, ok: bool) {
	sw := time.tick_now()
	for {
		eos.poll()
		st = eos.status()
		if st.stage == .Ready {
			return st, true
		}
		if st.stage == .Failed || time.duration_seconds(time.tick_since(sw)) > timeout_s {
			return st, false
		}
		time.sleep(5 * time.Millisecond)
	}
}

mode_eos_relay :: proc(a: ^Args) -> bool {
	check_known(a, "players", "ticks", "relays", "code-file", "log")
	players := opt_int(a, "players", required = true, lo = 1, hi = 4)
	ticks := u32(opt_int(a, "ticks", required = true, lo = 1, hi = 1_000_000))
	if !eos_start(a) {
		return false
	}
	defer eos.shutdown()
	t0 := time.tick_now()
	eos.host(EOS_BUCKET)
	st, ok := eos_wait_ready(30)
	if !ok {
		fmt.eprintfln("unified eos-relay: %s", st.detail)
		return false
	}
	st = eos.status(context.allocator) // outlives the netcode's temp-allocator resets
	ready_ms := time.duration_milliseconds(time.tick_since(t0))
	fmt.eprintfln("unified eos-relay: game code %s (as %s, lobby ready in %.0f ms)", st.code, st.local, ready_ms)
	if path := opt_str(a, "code-file"); path != "" {
		_ = os.write_entire_file(path, st.code)
	}
	link, _ := eos.link()
	cfg := netcode.Relay_Config {
		ticks         = ticks,
		seed          = 1,
		start_players = players,
		timeout_s     = f64(ticks) / 60 * 3 + 120,
		name          = "relay",
	}
	r := netcode.relay_create(cfg, link)
	defer netcode.relay_destroy(r)
	ok = netcode.relay_run(r)
	if path := opt_str(a, "log"); path != "" {
		ok &&= sim.log_write(path, &r.log)
	}
	fmt.printfln(
		`{{"mode":"eos-relay","code":"%s","lobby_ready_ms":%.0f,"desyncs":%d,"finalized":%d,"net":%s,"ok":%v}}`,
		st.code,
		ready_ms,
		r.desyncs,
		r.finalized,
		netcode.channel_stats_json(r.ch),
		ok,
	)
	return ok && r.desyncs == 0
}

mode_eos_client :: proc(a: ^Args) -> bool {
	check_known(a, "code", "player", "ticks", "relays")
	code := opt_str(a, "code", required = true)
	player := opt_int(a, "player", required = true, lo = 0, hi = 3)
	ticks := u32(opt_int(a, "ticks", required = true, lo = 1, hi = 1_000_000))
	if !eos_start(a) {
		return false
	}
	defer eos.shutdown()
	t0 := time.tick_now()
	eos.join(EOS_BUCKET, code)
	st, ok := eos_wait_ready(30)
	if !ok {
		fmt.eprintfln("unified eos-client: %s", st.detail)
		return false
	}
	st = eos.status(context.allocator)
	join_ms := time.duration_milliseconds(time.tick_since(t0))
	fmt.eprintfln("unified eos-client: joined %s as %s, host %s (%.0f ms)", st.code, st.local, st.host, join_ms)
	link, _ := eos.link()
	cfg := netcode.Client_Config {
		player    = player,
		timeout_s = f64(ticks) / 60 * 3 + 120,
		name      = fmt.tprintf("client%d", player),
	}
	c := netcode.client_create(cfg, link)
	defer netcode.client_destroy(c)
	ok = netcode.client_run(c)
	if c.ticks != 0 && c.ticks != ticks {
		fmt.eprintfln("eos-client: the relay runs %d ticks, --ticks says %d", c.ticks, ticks)
		ok = false
	}
	st = eos.status(context.allocator)
	fmt.printfln(
		`{{"mode":"eos-client","join_ms":%.0f,"network":"%v","client":%s,"ok":%v}}`,
		join_ms,
		st.network,
		netcode.client_json(c),
		ok,
	)
	return ok
}
