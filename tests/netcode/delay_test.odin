package test_netcode

import "core:math"
import "core:testing"

import "unified:netcode"

// netcode.want_delay computes the ceiling by hand (netcode stays off core:math); it must equal the
// formula of spec/netcode.md everywhere. The test itself may use core:math: it is not simulation code.
@(test)
want_delay_matches_formula :: proc(t: ^testing.T) {
	for hz in ([]int{32, 60, 64, 128}) {
		tm := netcode.timing_of(hz)
		tick_ms := 1000 / f64(hz)
		max_delay := u32(math.ceil(100 / tick_ms))
		testing.expect_value(t, tm.max_delay, max_delay)
		for i in 0 ..= 100_000 {
			rtt_us := f64(i) * 10 // 0 .. 1 s in 10 µs steps
			want := u32(clamp(math.ceil((rtt_us / 1000 / 2 + 8) / tick_ms), 1, f64(max_delay)))
			if got := netcode.want_delay(rtt_us, tm); got != want {
				testing.expectf(t, false, "%d Hz, rtt %v us: want_delay %d, formula %d", hz, rtt_us, got, want)
				return
			}
		}
	}
	tm := netcode.timing_of(64)
	testing.expect_value(t, tm.tolerance, 7) // 100 ms at 15.625 ms per tick
	testing.expect(t, tm.prediction_cap >= 10 && tm.prediction_cap <= 14)
}
