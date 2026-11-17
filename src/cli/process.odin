package cli

import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// A child process to run. Its stdout and stderr go to our stderr (progress), or with `capture` into `Ran.stdout`
// and `Ran.stderr`. Unless `interactive`, its stdin holds one line, `quit`, and then ends: a Godot run with -d that
// stops at its debugger prompt (a script or parse error) quits at once. A closed stdin is not enough: Godot on Windows
// never sees it end and waits at the prompt until the timeout.
Run :: struct {
	cmd:         []string,
	dir:         string, // working directory ("": ours)
	timeout:     time.Duration, // 0: none; a run that exceeds it is killed
	capture:     bool,
	interactive: bool, // our stdin, stdout and stderr
	quiet:       bool, // never echo the command line (else it is echoed with --verbose, or when it fails)
	env:         []string, // the whole environment (nil: ours, .env included)
	log_to:      string, // with capture: also keep both streams in <log_to>.stdout / .stderr
}

Ran :: struct {
	exit_code: int,
	ok:        bool, // exited 0 within the timeout
	timed_out: bool,
	stdout:    string,
	stderr:    string,
	seconds:   f64,
}

Proc :: struct {
	run:      Run,
	process:  os.Process,
	start:    time.Tick,
	out_path: string,
	err_path: string,
	files:    [2]^os.File,
	reaped:   Maybe(os.Process_State), // `done` saw it exit (a process is waited for once)
}

@(private)
tmp_counter: int

// Starts a process (see Run); `wait` collects it.
start :: proc(spec: Run) -> Proc {
	child := Proc {
		run = spec,
	}
	if !spec.quiet && state.verbose {
		log("+ %s", command_line(spec))
	}
	desc := os.Process_Desc {
		command     = spec.cmd,
		working_dir = spec.dir,
		env         = spec.env,
	}
	stdin_read: ^os.File
	if !spec.interactive {
		stdin_read = debugger_quit_stdin()
		desc.stdin = stdin_read
	}
	if spec.interactive {
		desc.stdin, desc.stdout, desc.stderr = os.stdin, os.stdout, os.stderr
	} else if spec.capture {
		base := spec.log_to
		if base == "" {
			index := sync.atomic_add(&tmp_counter, 1)
			base = join(state.project.out, "tmp", aprintf("%d-%d", os.get_pid(), index))
		}
		make_dirs(os.dir(base))
		child.out_path = aprintf("%s.stdout", base)
		child.err_path = aprintf("%s.stderr", base)
		// Inheritable: on Windows a child gets only the handles opened so
		flags := os.File_Flags{.Write, .Create, .Trunc, .Inheritable}
		out_file, out_error := os.open(child.out_path, flags)
		err_file, err_error := os.open(child.err_path, flags)
		if out_error != nil || err_error != nil {
			fatal("cannot create %s", child.out_path)
		}
		child.files = {out_file, err_file}
		desc.stdout, desc.stderr = out_file, err_file
	} else {
		desc.stdout, desc.stderr = os.stderr, os.stderr
	}
	child.start = time.tick_now()
	process, err_file := os.process_start(desc)
	if stdin_read != nil {
		os.close(stdin_read) // the child holds its own copy
	}
	if err_file != nil {
		fatal("cannot start %s: %v", spec.cmd[0], err_file)
	}
	child.process = process
	return child
}

// Waits for a started process (killing it at its timeout) and collects its output.
wait :: proc(child: ^Proc) -> Ran {
	timeout := child.run.timeout > 0 ? child.run.timeout - time.tick_since(child.start) : os.TIMEOUT_INFINITE
	if child.run.timeout > 0 && timeout < time.Millisecond {
		timeout = time.Millisecond
	}
	exit_state: os.Process_State
	err: os.Error
	if reaped, ok := child.reaped.?; ok {
		exit_state = reaped
	} else {
		exit_state, err = os.process_wait(child.process, timeout)
	}
	ran: Ran
	if err != nil || !exit_state.exited {
		kill_tree(child.process)
		exit_state, _ = os.process_wait(child.process)
		ran.timed_out = err == nil || err == .Timeout
	}
	ran.exit_code = exit_state.exit_code
	ran.ok = exit_state.exited && exit_state.exit_code == 0 && !ran.timed_out
	ran.seconds = time.duration_seconds(time.tick_since(child.start))
	// A failure names its command line, so it can be run again by hand (a captured run is a probe: its caller
	// decides what a failure means).
	if !ran.ok && !child.run.quiet && !child.run.capture && !state.verbose {
		log("+ %s (%s)", command_line(child.run), ran.timed_out ? "timed out" : aprintf("exit %d", ran.exit_code))
	}
	return collect(child, ran)
}

// Kills a process at its timeout, with what it started: on Windows Godot's console executable (what `godot()` runs)
// starts the real Godot as its child, which a kill of the wrapper alone would leave running (at a debugger prompt,
// say). taskkill /T ends the tree; the run is already over its time, so its cost doesn't matter.
@(private)
kill_tree :: proc(process: os.Process) {
	when ODIN_OS == .Windows {
		if null, null_err := os.open("NUL", {.Write, .Inheritable}); null_err == nil {
			taskkill, err := os.process_start(
			{
				command = strs("taskkill", "/T", "/F", "/PID", aprintf("%d", process.pid)),
				stdout  = null, // "SUCCESS: ..." would end up in the command's result
				stderr  = null,
			},
			)
			if err == nil {
				_, _ = os.process_wait(taskkill, 10 * time.Second)
			}
			os.close(null)
		}
	}
	_ = os.process_kill(process)
}

// Whether a started process has run past its timeout (none: never).
@(private)
past_timeout :: proc(child: ^Proc) -> bool {
	return child.run.timeout > 0 && time.tick_since(child.start) > child.run.timeout
}

@(private)
command_line :: proc(spec: Run) -> string {
	return strings.join(redact(spec.cmd), " ", context.temp_allocator)
}

// Whether a started process has ended (without blocking).
done :: proc(child: ^Proc) -> bool {
	if _, ok := child.reaped.?; ok {
		return true
	}
	exit_state, err := os.process_wait(child.process, 0)
	if err == nil && exit_state.exited {
		child.reaped = exit_state
		return true
	}
	return false
}

@(private)
collect :: proc(child: ^Proc, ran: Ran) -> Ran {
	ran := ran
	if child.run.capture {
		os.close(child.files[0])
		os.close(child.files[1])
		ran.stdout, _ = read_text(child.out_path)
		ran.stderr, _ = read_text(child.err_path)
		if child.run.log_to == "" {
			os.remove(child.out_path)
			os.remove(child.err_path)
		}
	}
	return ran
}

// Runs a process to the end.
run_proc :: proc(spec: Run) -> Ran {
	child := start(spec)
	return wait(&child)
}

// Runs a process; a failure stops the command with its output.
must_run :: proc(spec: Run, what: string) -> Ran {
	ran := run_proc(spec)
	if !ran.ok {
		if spec.capture {
			log("%s", tail(strings.concatenate({ran.stdout, ran.stderr}, context.temp_allocator), 4000))
		}
		if ran.timed_out {
			fatal("%s timed out after %.0fs", what, time.duration_seconds(spec.timeout))
		}
		fatal("%s failed (exit %d)", what, ran.exit_code)
	}
	return ran
}

// Runs every process, at most `parallel` at a time (0: all at once), and returns their results in order. A run past
// its timeout is killed (wait) and reported as timed out.
run_all :: proc(runs: []Run, parallel := 0) -> []Ran {
	results := make([]Ran, len(runs))
	limit := parallel > 0 ? parallel : len(runs)
	running: [dynamic]struct {
		index: int,
		child: Proc,
	}
	next := 0
	for next < len(runs) || len(running) > 0 {
		for next < len(runs) && len(running) < limit {
			append(&running, struct {
				index: int,
				child: Proc,
			}{next, start(runs[next])})
			next += 1
		}
		progressed := false
		for k := 0; k < len(running); {
			if done(&running[k].child) || past_timeout(&running[k].child) {
				results[running[k].index] = wait(&running[k].child)
				unordered_remove(&running, k)
				progressed = true
			} else {
				k += 1
			}
		}
		if !progressed {
			time.sleep(2 * time.Millisecond)
		}
	}
	return results
}

// An executable on PATH ("" when there is none).
which :: proc(name: string) -> string {
	path := os.get_env("PATH", context.temp_allocator)
	sep := ODIN_OS == .Windows ? ";" : ":"
	for dir in strings.split(path, sep, context.temp_allocator) {
		if dir == "" {
			continue
		}
		candidate := join(dir, name)
		when ODIN_OS == .Windows {
			if !strings.has_suffix(name, ".exe") {
				candidate = aprintf("%s.exe", candidate)
			}
		}
		if os.is_file(candidate) {
			return candidate
		}
	}
	return ""
}

// The last `n` bytes of a text, for error output.
tail :: proc(text: string, count: int) -> string {
	return len(text) > count ? text[len(text) - count:] : text
}

// A command line for logs, with the values of -define:UNIFIED_EOS_* (credentials) replaced.
redact :: proc(cmd: []string) -> []string {
	out := make([]string, len(cmd), context.temp_allocator)
	for arg, i in cmd {
		out[i] = arg
		if strings.has_prefix(arg, "-define:UNIFIED_EOS_") {
			if eq := strings.index_byte(arg, '='); eq >= 0 {
				out[i] = aprintf("%s=***", arg[:eq])
			}
		}
	}
	return out
}


// Lines of a text that contain any of the needles.
lines_with :: proc(text: string, needles: ..string) -> []string {
	out: [dynamic]string
	text := text
	for line in strings.split_lines_iterator(&text) {
		for needle in needles {
			if strings.contains(line, needle) {
				append(&out, line)
				break
			}
		}
	}
	return out[:]
}

// A pipe's read end holding `quit` and then its end (nil when no pipe can be made: the child's stdin is then closed).
@(private)
debugger_quit_stdin :: proc() -> ^os.File {
	read_end, write_end, err := os.pipe()
	if err != nil {
		return nil
	}
	os.write_string(write_end, "quit\n")
	os.close(write_end)
	return read_end
}
