// Online modes over EOS (spec/eos.md), the game topology end to end without Godot: `eos-host`
// runs a host (relay + the host's own player in slot 0) whose relay also serves an EOS P2P link,
// publishes a lobby and prints its code; `eos-client` joins by code and plays a remote slot (a late
// join: the host's clock is already running). Inputs are the game's script. Two processes on one
// machine need two Product User IDs: run one of them with UNIFIED_EOS_FRESH_DEVICE=1. Each run
// deletes its device ID at exit: on macOS the keychain entry belongs to the binary that made it,
// and a rebuilt binary could not read or replace it without a dialog.
package headless

import "core:fmt"
import "core:os"
import "core:time"

import "../eos"
import "../netcode"
import "../sim"

EOS_BUCKET :: "unified-headless/1"

@(private)
eos_start :: proc(a: ^Args, product: string) -> bool {
	rc := eos.Relay_Control.Allow_Relays
	switch opt_str(a, "relays", "allow") {
	case "allow":
	case "force":
		rc = .Force_Relays
	case "none":
		rc = .No_Relays
	case:
		die("%s: --relays must be allow, force or none", a.mode)
	}
	if !eos.init({product_name = product, product_version = "1", relay_control = rc, no_keychain_prompts = true}) {
		fmt.eprintfln("%s: EOS unavailable: %s", a.mode, eos.status().detail)
		return false
	}
	return true
}

// Pumps EOS until the session is Ready (or failed, or `timeout_s` passed).
@(private)
eos_wait_ready :: proc(timeout_s: f64) -> (st: eos.Status, ok: bool) {
	sw := time.tick_now()
	for {
		eos.poll()
		st = eos.status(context.allocator)
		if st.stage == .Ready {
			return st, true
		}
		if st.stage == .Failed || time.duration_seconds(time.tick_since(sw)) > timeout_s {
			return st, false
		}
		time.sleep(5 * time.Millisecond)
	}
}

mode_eos_host :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "ticks", "relays", "code-file", "log", "players")
	ticks := u32(opt_int(a, "ticks", required = true, lo = 1, hi = 1_000_000))
	want := opt_int(a, "players", 2, lo = 1, hi = P) // the session counts as played once this many joined
	if !eos_start(a, "unified-headless") {
		return false
	}
	defer eos.shutdown()
	defer eos.forget_device() // test runs leave no keychain entry for the next build to trip on
	t0 := time.tick_now()
	link, lok := eos.open_host(EOS_BUCKET)
	if !lok {
		fmt.eprintfln("eos-host: %s", eos.status().detail)
		return false
	}
	st, ok := eos_wait_ready(30)
	if !ok {
		fmt.eprintfln("eos-host: %s", st.detail)
		return false
	}
	ready_ms := time.duration_milliseconds(time.tick_since(t0))
	fmt.eprintfln("eos-host: game code %s (as %s, lobby ready in %.0f ms)", st.code, st.local, ready_ms)
	if path := opt_str(a, "code-file"); path != "" {
		_ = os.write_entire_file(path, st.code)
	}
	user := Script_User(S, I, W, P){h, 1}
	host := netcode.host_create(
		h.game,
		netcode.Host_Config{seed = 1, ticks = ticks, name = "host"},
		script_hooks(&user),
	)
	defer netcode.host_destroy(host)
	netcode.host_add_link(host, link)
	deadline := netcode.now_us() + i64((session_timeout_s(ticks, h.game.tick_hz) + 60) * 1e6)
	for !netcode.host_finished(host) {
		now := netcode.now_us()
		wake := netcode.host_step(host, now)
		if now > deadline {
			fmt.eprintln("eos-host: timeout")
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
		`{{"mode":"eos-host","code":"%s","lobby_ready_ms":%.0f,"players":%d,"desyncs":%d,"finalized":%d,"net":%s,"ok":%v}}`,
		st.code,
		ready_ms,
		joined,
		r.desyncs,
		r.finalized,
		netcode.channel_stats_json(r.ch),
		ok,
	)
	return ok && r.desyncs == 0
}

mode_eos_client :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "code", "ticks", "relays")
	code := opt_str(a, "code", required = true)
	ticks := u32(opt_int(a, "ticks", required = true, lo = 1, hi = 1_000_000))
	if !eos_start(a, "unified-headless") {
		return false
	}
	defer eos.shutdown()
	defer eos.forget_device() // test runs leave no keychain entry for the next build to trip on
	t0 := time.tick_now()
	link, lok := eos.open_join(EOS_BUCKET, code)
	if !lok {
		fmt.eprintfln("eos-client: %s", eos.status().detail)
		return false
	}
	st, ok := eos_wait_ready(30)
	if !ok {
		fmt.eprintfln("eos-client: %s", st.detail)
		return false
	}
	join_ms := time.duration_milliseconds(time.tick_since(t0))
	fmt.eprintfln("eos-client: joined %s as %s, host %s (%.0f ms)", st.code, st.local, st.host, join_ms)
	user := Script_User(S, I, W, P){h, 1}
	c := netcode.client_create(h.game, netcode.Client_Config{slot = -1, name = "client"}, link, script_hooks(&user))
	defer netcode.client_destroy(c)
	task := Client_Task(S, I, W, P) {
		c,
		netcode.now_us() + i64((session_timeout_s(ticks, h.game.tick_hz) + 60) * 1e6),
		false,
	}
	run_client(&task)
	ok = task.ok
	if c.ticks != 0 && c.ticks != ticks {
		fmt.eprintfln("eos-client: the host runs %d ticks, --ticks says %d", c.ticks, ticks)
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
