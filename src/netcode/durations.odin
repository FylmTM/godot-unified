// Durations: a distribution of times in µs, in fixed buckets (no allocation, merged by adding), for the client's
// step times (Client_Stats.client_steps).
package netcode

import "base:intrinsics"

// Under 16 µs one bucket per µs; above, 8 buckets per power of two (each 12.5% wide), up to 2^24 µs (16 s; longer
// counts in the last).
DURATION_EXACT :: 16
DURATION_BUCKETS :: DURATION_EXACT + (24 - 4) * 8

Durations :: struct {
	count:   int,
	max_us:  i64,
	buckets: [DURATION_BUCKETS]u32,
}

@(private)
duration_bucket :: proc(us: i64) -> int {
	if us < DURATION_EXACT {
		return int(max(us, 0))
	}
	exponent := 63 - int(intrinsics.count_leading_zeros(u64(us))) // >= 4
	sub := int(us >> uint(exponent - 3)) & 7
	return min(DURATION_EXACT + (exponent - 4) * 8 + sub, DURATION_BUCKETS - 1)
}

// The largest time bucket `bucket` holds.
@(private)
duration_bucket_top :: proc(bucket: int) -> i64 {
	if bucket < DURATION_EXACT {
		return i64(bucket)
	}
	exponent := (bucket - DURATION_EXACT) / 8 + 4
	sub := (bucket - DURATION_EXACT) % 8
	return (i64(8 + sub) << uint(exponent - 3)) + (i64(1) << uint(exponent - 3)) - 1
}

durations_add :: proc(durations: ^Durations, us: i64) {
	durations.count += 1
	durations.max_us = max(durations.max_us, us)
	durations.buckets[duration_bucket(us)] += 1
}

durations_merge :: proc(into: ^Durations, from: Durations) {
	into.count += from.count
	into.max_us = max(into.max_us, from.max_us)
	for count, bucket in from.buckets {
		into.buckets[bucket] += count
	}
}

// The `percent`th percentile (nearest rank), as the top of its bucket (at most 12.5% over), never above the maximum;
// 0 with no samples.
durations_percentile :: proc(durations: Durations, percent: f64) -> i64 {
	if durations.count == 0 {
		return 0
	}
	rank := max(int(percent / 100 * f64(durations.count) + 0.999999), 1)
	seen := 0
	for count, bucket in durations.buckets {
		seen += int(count)
		if seen >= rank {
			// the last bucket holds everything longer: its top is the maximum
			return(
				bucket == DURATION_BUCKETS - 1 ? durations.max_us : min(duration_bucket_top(bucket), durations.max_us) \
			)
		}
	}
	return durations.max_us
}
