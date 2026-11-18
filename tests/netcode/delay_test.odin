package test_netcode

import "core:math"
import "core:testing"

import "unified:netcode"

// netcode.want_delay and stamp_ahead compute their ceilings by hand (netcode stays off core:math); they must
// equal the formulas of src/netcode/SPEC.md (Timing) everywhere, with the game's floor k_min. The test itself may
// use core:math: it is not simulation code.
@(test)
want_delay_matches_formula :: proc(t: ^testing.T) {
	for tick_hz in ([]int{32, 60, 64, 128}) {
		timing := netcode.timing_of(tick_hz)
		tick_ms := 1000 / f64(tick_hz)
		max_delay := u32(math.ceil(100 / tick_ms))
		testing.expect_value(t, timing.max_delay, max_delay)
		cap := f64(timing.prediction_cap)
		for k_min in ([]u32{1, 3}) {
			for i in 0 ..= 100_000 {
				rtt_us := f64(i) * 10 // 0 .. 1 s in 10 µs steps
				rtt_ms := rtt_us / 1000
				want := u32(clamp(math.ceil((rtt_ms + 8) / tick_ms) + 1 - cap, f64(k_min), f64(max_delay)))
				stamp := u32(math.ceil((rtt_ms / 2 + 8) / tick_ms))
				got := netcode.want_delay(rtt_us, timing, k_min)
				got_stamp := netcode.stamp_ahead(rtt_us, timing)
				if got != want || got_stamp != stamp {
					testing.expectf(
						t,
						false,
						"%d Hz, k_min %d, rtt %v us: want_delay %d (formula %d), stamp_ahead %d (formula %d)",
						tick_hz,
						k_min,
						rtt_us,
						got,
						want,
						got_stamp,
						stamp,
					)
					return
				}
			}
		}
	}
	// At 64 Hz (cap 14): the floor up to ~200 ms, then one tick per tick of round trip, 7 (100 ms) from ~300 ms.
	timing64 := netcode.timing_of(64)
	testing.expect_value(t, netcode.want_delay(100_000, timing64), 1)
	testing.expect_value(t, netcode.want_delay(250_000, timing64), 4)
	testing.expect_value(t, netcode.want_delay(300_000, timing64), 7)
	testing.expect_value(t, netcode.want_delay(500_000, timing64), 7)
	timing := netcode.timing_of(64)
	testing.expect_value(t, timing.tolerance, 7) // 100 ms at 15.625 ms per tick
	testing.expect_value(t, timing.prediction_cap, 14) // the ring (16 at 64 Hz) less 2
	// the cap follows the ring at every tick rate (#161): ~250 ms of ring
	testing.expect_value(t, netcode.timing_of(32).prediction_cap, 8) // the ring's floor: 250 ms
	testing.expect_value(t, netcode.timing_of(128).prediction_cap, 30)
}
