// EOS (src/eos/SPEC.md) as the headless binary's online transport: `eos-host` / `eos-client` through
// unified:headless/modes's online modes. Two processes on one machine need two Product User IDs: run one
// of them with UNIFIED_EOS_FRESH_DEVICE=1. Each run deletes its device ID at exit: on macOS the
// keychain entry belongs to the binary that made it, and a rebuilt binary could not read or replace
// it without a dialog.
package main

import "core:fmt"

import "unified:eos"
import "unified:headless/modes"
import "unified:netcode"

// Lobbies only match within a bucket; --bucket survivor/3 meets the game's own builds.
EOS_BUCKET :: "unified-headless/6"
#assert(netcode.PROTOCOL_VERSION == 8, "netcode protocol changed: bump EOS_BUCKET (and the game's bucket) with it")

EOS_ONLINE := modes.Online {
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
	poll = proc() -> modes.Online_Status {
		eos.poll()
		status := eos.status()
		return {
			ready = status.stage == .Ready,
			failed = status.stage == .Failed,
			detail = status.detail,
			code = status.code,
			local = status.local,
			host = status.host,
			network = fmt.tprint(status.network),
			peers = status.peers,
		}
	},
}

@(private)
eos_start :: proc(args: ^modes.Args) -> bool {
	relay_control := eos.Relay_Control.Allow_Relays
	switch modes.opt_str(args, "relays", "allow") {
	case "allow":
	case "force":
		relay_control = .Force_Relays
	case "none":
		relay_control = .No_Relays
	case:
		modes.die("%s: --relays must be allow, force or none", args.mode)
	}
	if !eos.init(
		{
			product_name = "unified-headless",
			product_version = "1",
			relay_control = relay_control,
			no_keychain_prompts = true,
		},
	) {
		fmt.eprintfln("%s: EOS unavailable: %s", args.mode, eos.status().detail)
		return false
	}
	return true
}
