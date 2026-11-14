package test_netcode

import "core:math"
import "core:testing"

import "unified:netcode"

// netcode.want_delay computes the ceiling by hand (netcode stays off core:math); it must equal the
// formula of src/netcode/SPEC.md everywhere. The test itself may use core:math: it is not simulation code.
@(test)
want_delay_matches_formula :: proc(t: ^testing.T) {
	for tick_hz in ([]int{32, 60, 64, 128}) {
		timing := netcode.timing_of(tick_hz)
		tick_ms := 1000 / f64(tick_hz)
		max_delay := u32(math.ceil(100 / tick_ms))
		testing.expect_value(t, timing.max_delay, max_delay)
		for i in 0 ..= 100_000 {
			rtt_us := f64(i) * 10 // 0 .. 1 s in 10 µs steps
			want := u32(clamp(math.ceil((rtt_us / 1000 / 2 + 8) / tick_ms), 1, f64(max_delay)))
			if got := netcode.want_delay(rtt_us, timing); got != want {
				testing.expectf(t, false, "%d Hz, rtt %v us: want_delay %d, formula %d", tick_hz, rtt_us, got, want)
				return
			}
		}
	}
	timing := netcode.timing_of(64)
	testing.expect_value(t, timing.tolerance, 7) // 100 ms at 15.625 ms per tick
	testing.expect_value(t, timing.prediction_cap, 14) // the ring (16 at 64 Hz) less 2
	// the cap follows the ring at every tick rate (#161): ~250 ms of ring
	testing.expect_value(t, netcode.timing_of(32).prediction_cap, 6)
	testing.expect_value(t, netcode.timing_of(128).prediction_cap, 30)
}
