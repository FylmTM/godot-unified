// sleep_until on Windows: Sleep takes whole milliseconds (core:time's sleep truncates, so a wait under 1 ms was
// Sleep(0), a yield, and a session thread spun up to each deadline). A high-resolution waitable timer per thread
// waits to the microsecond the scheduler allows (about 0.5 ms), with no timeBeginPeriod needed.
package netcode

import win "core:sys/windows"
import "core:time"

@(private, thread_local)
sleep_timer: win.HANDLE

@(private)
sleep_us :: proc(wait_us: i64) {
	if sleep_timer == nil {
		sleep_timer = win.CreateWaitableTimerExW(
			nil,
			nil,
			win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
			win.TIMER_ALL_ACCESS,
		)
		if sleep_timer == nil {
			// Before Windows 10 1803: whole milliseconds, rounded up so a wait never becomes a spin.
			time.sleep(time.Duration((wait_us + 999) / 1000) * time.Millisecond)
			return
		}
	}
	due := win.LARGE_INTEGER(-wait_us * 10) // relative, in 100 ns units
	if win.SetWaitableTimerEx(sleep_timer, &due, 0, nil, nil, nil, 0) {
		win.WaitForSingleObject(sleep_timer, win.INFINITE)
	}
}
