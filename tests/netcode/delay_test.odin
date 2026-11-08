package test_netcode

import "core:math"
import "core:testing"

import "unified:netcode"

// netcode.want_delay computes the ceiling by hand (netcode stays off core:math); it must equal the
// formula of CORE.md §2 everywhere. The test itself may use core:math: it is not simulation code.
@(test)
want_delay_matches_formula :: proc(t: ^testing.T) {
	for i in 0 ..= 400_000 {
		rtt_us := f64(i) * 2.5 // 0 .. 1 s in 2.5 µs steps
		want := u32(clamp(math.ceil((rtt_us / 1000 / 2 + 8) / 16.667), 1, 6))
		if got := netcode.want_delay(rtt_us); got != want {
			testing.expectf(t, false, "rtt %v us: want_delay %d, formula %d", rtt_us, got, want)
			return
		}
	}
	testing.expect_value(t, netcode.want_delay(0), 1)
	testing.expect_value(t, netcode.want_delay(1e9), 6)
}
