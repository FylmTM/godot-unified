#+build windows
// Windows only: netcode.sleep_until's waitable timer, one per thread, closed by netcode.sleep_end.
package test_netcode

import win "core:sys/windows"
import "core:testing"
import "core:thread"

import "unified:netcode"

// A thread that slept and ends with netcode.sleep_end leaves no OS handle behind.
@(test)
a_thread_that_slept_leaves_no_handle :: proc(t: ^testing.T) {
	THREADS :: 64
	before := process_handles()
	for _ in 0 ..< THREADS {
		worker := thread.create_and_start(proc() {
			netcode.sleep_until(netcode.now_us() + 100)
			netcode.sleep_end()
		})
		thread.join(worker)
		thread.destroy(worker)
	}
	after := process_handles()
	testing.expectf(t, after < before + THREADS / 2, "%d handles before %d threads, %d after", before, THREADS, after)
}

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	GetProcessHandleCount :: proc(process: win.HANDLE, count: ^u32) -> win.BOOL ---
}

// How many handles this process holds.
process_handles :: proc() -> int {
	count: u32
	GetProcessHandleCount(win.GetCurrentProcess(), &count)
	return int(count)
}
