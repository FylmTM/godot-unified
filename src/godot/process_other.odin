#+build !windows
package godot

import "core:sys/posix"

// Whether a process with this id runs (any process, not only a child: Godot's OS.is_process_running reports an
// error for those on Linux). kill with signal 0 only checks; EPERM means it runs under another user.
process_alive :: proc(pid: int) -> bool {
	return pid > 0 && (posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK || posix.errno() == .EPERM)
}
