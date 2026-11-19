// Thread classes on Linux: plain sleeps (to be measured), nothing asked of the system for a session.
#+private
package godot

import "core:os"
import "core:strings"

set_realtime_thread :: proc(tick_hz: int) {}

session_power_begin :: proc() {}

session_power_end :: proc() {}

// Whether a debugger is attached (the watchdog stays quiet under one): /proc/self/status names a tracer.
debugger_attached :: proc() -> bool {
	data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
	if err != nil do return false
	at := strings.index(string(data), "TracerPid:")
	if at < 0 do return false
	rest := strings.trim_left_space(string(data)[at + len("TracerPid:"):])
	return len(rest) > 0 && rest[0] != '0'
}

// A freeze's dump of every thread: none on Linux (a core dump at the abort, where the system keeps them).
write_minidump :: proc(path: string) {}
