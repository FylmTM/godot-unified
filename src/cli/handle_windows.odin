package cli

import "core:os"
import win32 "core:sys/windows"

// Closes a handle os.process_open gave: os.process_wait closes it only when the process ended or the wait failed, so
// a wait that timed out (a process still running) leaves it open.
@(private)
process_handle_close :: proc(process: os.Process) {
	win32.CloseHandle(win32.HANDLE(process.handle))
}
