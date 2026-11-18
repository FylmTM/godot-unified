// L1 tests for Durations, the client's step-time distribution: percentiles within a bucket's width, merging.
package test_netcode

import "core:testing"

import "unified:netcode"

// Exact under 16 µs; above, the reported percentile is never below the true one and at most 12.5% over it, never
// above the maximum.
@(test)
durations_percentiles_are_within_a_bucket :: proc(t: ^testing.T) {
	for top in ([]i64{10, 100, 1_000, 37_777, 2_000_000}) {
		durations: netcode.Durations
		for us in i64(1) ..= top {
			netcode.durations_add(&durations, us)
		}
		testing.expect_value(t, durations.count, int(top))
		testing.expect_value(t, durations.max_us, top)
		testing.expect_value(t, netcode.durations_percentile(durations, 100), top)
		for percent in ([]f64{50, 90, 99}) {
			want := i64(percent / 100 * f64(top) + 0.999999)
			got := netcode.durations_percentile(durations, percent)
			testing.expectf(
				t,
				got >= want && f64(got) <= f64(want) * 1.125 + 1,
				"1..%d µs: p%.0f is %d, want %d",
				top,
				percent,
				got,
				want,
			)
		}
	}
	empty: netcode.Durations
	testing.expect_value(t, netcode.durations_percentile(empty, 99), 0)
	huge: netcode.Durations
	netcode.durations_add(&huge, 1 << 40) // past the last bucket: counted there, the maximum kept
	testing.expect_value(t, netcode.durations_percentile(huge, 99), 1 << 40)
}

@(test)
durations_merge_adds_up :: proc(t: ^testing.T) {
	a, b: netcode.Durations
	for _ in 0 ..< 99 do netcode.durations_add(&a, 20)
	netcode.durations_add(&b, 5_000)
	netcode.durations_merge(&a, b)
	testing.expect_value(t, a.count, 100)
	testing.expect_value(t, a.max_us, 5_000)
	testing.expect(t, netcode.durations_percentile(a, 99) < 23)
	testing.expect_value(t, netcode.durations_percentile(a, 100), 5_000)
}
