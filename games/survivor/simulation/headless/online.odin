// EOS (src/eos/SPEC.md) as the headless binary's online transport: `eos-host` / `eos-client` through
// unified:headless/cli's online modes. Two processes on one machine need two Product User IDs: run one
// of them with UNIFIED_EOS_FRESH_DEVICE=1. Each run deletes its device ID at exit: on macOS the
// keychain entry belongs to the binary that made it, and a rebuilt binary could not read or replace
// it without a dialog.
package main

import "core:fmt"

import "unified:eos"
import "unified:headless/cli"
import "unified:netcode"

// Lobbies only match within a bucket; --bucket survivor/3 meets the game's own builds.
EOS_BUCKET :: "unified-headless/4"
#assert(netcode.PROTOCOL_VERSION == 6, "netcode protocol changed: bump EOS_BUCKET (and the game's bucket) with it")

EOS_ONLINE := cli.Online {
	name = "eos",
	bucket = EOS_BUCKET,
	options = {"relays"},
	start = eos_start,
	stop = proc() {
		eos.forget_device() // test runs leave no keychain entry for the next build to trip on
		eos.shutdown()
	},
	open_host = eos.open_host,
	open_join = eos.open_join,
	poll = proc() -> (st: cli.Online_Status) {
		eos.poll()
		s := eos.status()
		return {
			ready = s.stage == .Ready,
			failed = s.stage == .Failed,
			detail = s.detail,
			code = s.code,
			local = s.local,
			host = s.host,
			network = fmt.tprint(s.network),
			peers = s.peers,
		}
	},
}

@(private)
eos_start :: proc(a: ^cli.Args) -> bool {
	rc := eos.Relay_Control.Allow_Relays
	switch cli.opt_str(a, "relays", "allow") {
	case "allow":
	case "force":
		rc = .Force_Relays
	case "none":
		rc = .No_Relays
	case:
		cli.die("%s: --relays must be allow, force or none", a.mode)
	}
	if !eos.init(
		{product_name = "unified-headless", product_version = "1", relay_control = rc, no_keychain_prompts = true},
	) {
		fmt.eprintfln("%s: EOS unavailable: %s", a.mode, eos.status().detail)
		return false
	}
	return true
}
