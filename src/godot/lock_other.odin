#+build !windows
package godot

import "core:c"
import "core:strings"
import "core:sys/posix"

foreign import libc "system:c"

@(private, default_calling_convention = "c")
foreign libc {
	flock :: proc(fd: c.int, operation: c.int) -> c.int --- // BSD flock: Linux and macOS
}

// Opens `path` (made if missing) and takes an exclusive flock on it: no other open of the file, in this process or
// another, locks it until unlock_file or the process ends (a crash included). False when someone holds it.
@(private)
lock_file :: proc(path: string) -> (lock: Token_Lock, ok: bool) {
	LOCK_EX :: 2
	LOCK_NB :: 4
	fd := posix.open(
		strings.clone_to_cstring(path, context.temp_allocator),
		{.RDWR, .CREAT, .CLOEXEC},
		{.IRUSR, .IWUSR},
	)
	if fd < 0 do return 0, false
	if flock(c.int(fd), LOCK_EX | LOCK_NB) != 0 {
		posix.close(fd)
		return 0, false
	}
	return Token_Lock(uintptr(fd)) + 1, true // + 1: fd 0 is a file too, lock 0 is none
}

@(private)
unlock_file :: proc(lock: Token_Lock) {
	posix.close(posix.FD(uintptr(lock) - 1))
}
