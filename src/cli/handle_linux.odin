package cli

import "core:os"
import "core:sys/linux"

// Closes the pidfd os.process_open gave: os.process_wait closes it only when the process ended or the wait failed, so
// a wait that timed out (a process still running) leaves it open. Kernels without pidfds leave the handle unset.
@(private)
process_handle_close :: proc(process: os.Process) {
	if process.handle != 0 && process.handle != ~uintptr(0) do linux.close(linux.Fd(process.handle))
}
