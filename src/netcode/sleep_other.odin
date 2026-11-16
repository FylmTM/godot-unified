#+build !windows
package netcode

import "core:time"

// nanosleep: microsecond resolution.
@(private)
sleep_us :: proc(wait_us: i64) {
	time.sleep(time.Duration(wait_us) * time.Microsecond)
}
