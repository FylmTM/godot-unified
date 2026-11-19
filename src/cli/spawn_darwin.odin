// Starting a process on macOS: posix_spawn, not fork and exec.
//
// core:os starts a process with fork(), then runs code in the child (dup2, chdir) before execve. On macOS a child
// forked while another thread of the parent is loading system frameworks (CoreGraphics for the screen list,
// Foundation for a session's power activity) is sometimes killed with SIGKILL before it execs: the run ends at once,
// "exit 9", with no output. The test binaries run such tests beside the ones that start processes. posix_spawn
// creates the child in the kernel, with no code of ours between the fork and the exec, so it can't be caught midway.
#+private
package cli

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	posix_spawn_file_actions_init :: proc(actions: ^rawptr) -> posix.Errno ---
	posix_spawn_file_actions_destroy :: proc(actions: ^rawptr) -> posix.Errno ---
	posix_spawn_file_actions_adddup2 :: proc(actions: ^rawptr, fd, new_fd: posix.FD) -> posix.Errno ---
	posix_spawn_file_actions_addinherit_np :: proc(actions: ^rawptr, fd: posix.FD) -> posix.Errno ---
	posix_spawn_file_actions_addopen :: proc(actions: ^rawptr, fd: posix.FD, path: cstring, flags: c.int, mode: u16) -> posix.Errno ---
	posix_spawn_file_actions_addchdir_np :: proc(actions: ^rawptr, path: cstring) -> posix.Errno ---
	posix_spawnattr_init :: proc(attributes: ^rawptr) -> posix.Errno ---
	posix_spawnattr_destroy :: proc(attributes: ^rawptr) -> posix.Errno ---
	posix_spawnattr_setflags :: proc(attributes: ^rawptr, flags: c.short) -> posix.Errno ---
	posix_spawn :: proc(pid: ^posix.pid_t, path: cstring, actions: ^rawptr, attributes: ^rawptr, argv: [^]cstring, envp: [^]cstring) -> posix.Errno ---
}

POSIX_SPAWN_CLOEXEC_DEFAULT :: 0x4000 // Apple's: the child inherits only the descriptors the file actions name
O_RDWR :: 0x0002

// os.process_start's contract, through posix_spawn: the executable found the same way (a bare name on PATH, else in
// the working directory), the child's stdio from the description (nil: /dev/null) and no other descriptor.
start_process :: proc(desc: os.Process_Desc) -> (process: os.Process, err: os.Error) {
	if len(desc.command) == 0 {
		return {}, .Invalid_Path
	}
	exe := find_executable(desc.command[0], desc.working_dir) or_return

	argv := make([]cstring, len(desc.command) + 1, context.temp_allocator)
	for arg, i in desc.command {
		argv[i] = strings.clone_to_cstring(arg, context.temp_allocator)
	}
	envp := posix.environ
	if desc.env != nil {
		env := make([]cstring, len(desc.env) + 1, context.temp_allocator)
		for entry, i in desc.env {
			env[i] = strings.clone_to_cstring(entry, context.temp_allocator)
		}
		envp = raw_data(env)
	}

	actions, attributes: rawptr
	posix_spawn_file_actions_init(&actions)
	defer posix_spawn_file_actions_destroy(&actions)
	posix_spawnattr_init(&attributes)
	defer posix_spawnattr_destroy(&attributes)
	posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT)
	stdio := [3]^os.File{desc.stdin, desc.stdout, desc.stderr}
	for file, target in stdio {
		target := posix.FD(target)
		if file == nil {
			posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_RDWR, 0)
		} else if fd := posix.FD(os.fd(file)); fd == target {
			posix_spawn_file_actions_addinherit_np(&actions, fd) // dup2 onto itself would leave it close-on-exec
		} else {
			posix_spawn_file_actions_adddup2(&actions, fd, target)
		}
	}
	if desc.working_dir != "" {
		posix_spawn_file_actions_addchdir_np(
			&actions,
			strings.clone_to_cstring(desc.working_dir, context.temp_allocator),
		)
	}

	pid: posix.pid_t
	if spawn_err := posix_spawn(&pid, exe, &actions, &attributes, raw_data(argv), envp); spawn_err != .NONE {
		return {}, spawn_err
	}
	return os.process_open(int(pid))
}

// The executable a command names, found as os.process_start finds it: a path as given (a relative one from the
// working directory, where the child starts), a bare name in a PATH directory, else in the working directory.
@(private = "file")
find_executable :: proc(name, working_dir: string) -> (cstring, os.Error) {
	executable :: proc(path: string) -> bool {
		fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.CLOEXEC, .EXEC})
		if fd == -1 {
			return false
		}
		posix.close(fd)
		return true
	}
	if strings.index_byte(name, '/') >= 0 {
		return strings.clone_to_cstring(name, context.temp_allocator), nil
	}
	path_list := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path_list, ":", context.temp_allocator) {
		path := strings.concatenate({dir, "/", name}, context.temp_allocator)
		if dir != "" && executable(path) {
			return strings.clone_to_cstring(path, context.temp_allocator), nil
		}
	}
	if executable(strings.concatenate({working_dir == "" ? "." : working_dir, "/", name}, context.temp_allocator)) {
		return strings.clone_to_cstring(
				strings.concatenate({"./", name}, context.temp_allocator),
				context.temp_allocator,
			),
			nil
	}
	return nil, .Not_Exist
}
