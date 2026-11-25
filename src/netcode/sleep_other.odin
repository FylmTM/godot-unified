#+build !windows
package netcode

import "core:time"

// nanosleep: microsecond resolution.
@(private)
sleep_us :: proc(wait_us: i64) {
	time.sleep(time.Duration(wait_us) * time.Microsecond)
}

// Releases what this thread's sleep_until holds before the thread ends: nothing here (Windows closes its timer).
sleep_end :: proc() {}
