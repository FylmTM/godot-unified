// How late the session thread wakes from its sleeps: each sleep's lateness (how long after the time it asked for it
// ran again) goes into a histogram the session thread adds to and the main thread takes (`UnifiedSession`'s sync
// stats). `measure_wakes` runs the same sleeps apart from a session, on threads of the session thread's class:
// `uni bench`'s wake row. No Godot calls.
package godot

import "core:sync"
import "core:thread"
import "unified:netcode"

// The histogram's buckets: 1 µs wide below WAKE_FINE_US, then 1 ms wide to WAKE_COARSE_MS, then one for the rest.
@(private)
WAKE_FINE_US :: 2048
@(private)
WAKE_COARSE_MS :: 64
@(private)
WAKE_BUCKETS :: WAKE_FINE_US + WAKE_COARSE_MS - WAKE_FINE_US / 1000 + 1

// Sleeps' lateness, counted by bucket (atomic: the session thread adds, the main thread takes).
@(private)
Wake_Stats :: struct {
	buckets: [WAKE_BUCKETS]u32,
	max_us:  i64,
}

// A summary of sleeps' lateness: how many woke, the median, the 99th percentile and the latest (µs; a percentile is
// exact below 2 ms, then to the millisecond), and how many woke later than 1 ms and later than one tick (a tick
// stepped a whole tick late).
Wake_Summary :: struct {
	wakes:     int,
	p50_us:    f64,
	p99_us:    f64,
	max_us:    f64,
	over_ms:   int,
	over_tick: int,
}

@(private)
wake_bucket :: proc(late_us: i64) -> int {
	if late_us < WAKE_FINE_US do return int(max(late_us, 0))
	return min(WAKE_FINE_US + int(late_us / 1000) - WAKE_FINE_US / 1000, WAKE_BUCKETS - 1)
}

// The lowest lateness a bucket holds, µs.
@(private)
wake_bucket_us :: proc(bucket: int) -> i64 {
	if bucket < WAKE_FINE_US do return i64(bucket)
	return i64(bucket - WAKE_FINE_US + WAKE_FINE_US / 1000) * 1000
}

@(private)
wake_add :: proc(stats: ^Wake_Stats, late_us: i64) {
	sync.atomic_add(&stats.buckets[wake_bucket(late_us)], 1)
	for {
		seen := sync.atomic_load(&stats.max_us)
		if late_us <= seen do break
		if _, ok := sync.atomic_compare_exchange_weak(&stats.max_us, seen, late_us); ok do break
	}
}

// Sleeps until `wake_us` (netcode.sleep_until) and counts how late it woke; a wake already passed is no sleep.
@(private)
wake_sleep :: proc(stats: ^Wake_Stats, wake_us: i64) {
	if wake_us <= netcode.now_us() do return
	netcode.sleep_until(wake_us)
	wake_add(stats, netcode.now_us() - wake_us)
}

// Takes the counts so far (resetting them) and summarises them against a tick of `tick_us`.
@(private)
wake_take :: proc(stats: ^Wake_Stats, tick_us: i64) -> (summary: Wake_Summary) {
	counts: [WAKE_BUCKETS]u32
	for &count, bucket in counts do count = sync.atomic_exchange(&stats.buckets[bucket], 0)
	summary.max_us = f64(sync.atomic_exchange(&stats.max_us, 0))
	for count in counts do summary.wakes += int(count)
	if summary.wakes == 0 do return
	rank_50, rank_99 := (summary.wakes + 1) / 2, (99 * summary.wakes + 99) / 100
	seen := 0
	for count, bucket in counts {
		if count == 0 do continue
		low := wake_bucket_us(bucket)
		if seen < rank_50 && seen + int(count) >= rank_50 do summary.p50_us = f64(low)
		if seen < rank_99 && seen + int(count) >= rank_99 do summary.p99_us = f64(low)
		seen += int(count)
		if low >= 1000 do summary.over_ms += int(count)
		if low >= tick_us do summary.over_tick += int(count)
	}
	return
}

// Runs the session thread's sleeps apart from a session for `seconds`: a thread per tick rate in `tick_hz`, all at
// once, each of the session thread's class and power requests on this platform, sleeping to every tick's due time.
// Returns each rate's lateness, in `tick_hz`'s order (allocated). What `uni bench`'s wake row reports.
measure_wakes :: proc(tick_hz: []int, seconds: f64, allocator := context.allocator) -> []Wake_Summary {
	Measure :: struct {
		hz:      int,
		seconds: f64,
		stats:   Wake_Stats,
		summary: Wake_Summary,
	}
	measures := make([]Measure, len(tick_hz), context.temp_allocator)
	threads := make([]^thread.Thread, len(tick_hz), context.temp_allocator)
	session_power_begin()
	for &measure, i in measures {
		measure.hz, measure.seconds = max(tick_hz[i], 1), seconds
		threads[i] = thread.create_and_start_with_data(&measure, proc(data: rawptr) {
			measure := (^Measure)(data)
			set_realtime_thread(measure.hz)
			tick_us := i64(1_000_000 / measure.hz)
			start := netcode.now_us()
			for due := start + tick_us; due - start < i64(measure.seconds * 1_000_000); due += tick_us {
				wake_sleep(&measure.stats, due)
			}
			measure.summary = wake_take(&measure.stats, tick_us)
		})
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
	session_power_end()
	summaries := make([]Wake_Summary, len(tick_hz), allocator)
	for measure, i in measures do summaries[i] = measure.summary
	return summaries
}
