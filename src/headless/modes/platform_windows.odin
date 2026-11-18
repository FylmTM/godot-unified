package modes

import win "core:sys/windows"

// Sleep(1) on Windows waits a whole scheduler tick (~15.6 ms) unless the timer resolution is
// raised; the relay and client loops sleep in 1 ms steps.
@(private)
platform_init :: proc() {
	win.timeBeginPeriod(1)
}
