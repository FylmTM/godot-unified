package cli

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

// A child process to run. Its stdout and stderr go to our stderr (progress), or with `capture` into `Ran.stdout`
// and `Ran.stderr`. Its stdin is closed unless `interactive`: a Godot waiting at its debugger prompt must end, not
// hang.
Run :: struct {
	cmd:         []string,
	dir:         string, // working directory ("": ours)
	timeout:     time.Duration, // 0: none; a run that exceeds it is killed
	capture:     bool,
	interactive: bool, // our stdin, stdout and stderr
	quiet:       bool, // don't echo the command line
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
start :: proc(r: Run) -> Proc {
	p := Proc {
		run = r,
	}
	if !r.quiet {
		log("+ %s", strings.join(redact(r.cmd), " ", context.temp_allocator))
	}
	desc := os.Process_Desc {
		command     = r.cmd,
		working_dir = r.dir,
		env         = r.env,
	}
	if r.interactive {
		desc.stdin, desc.stdout, desc.stderr = os.stdin, os.stdout, os.stderr
	} else if r.capture {
		base := r.log_to
		if base == "" {
			n := sync.atomic_add(&tmp_counter, 1)
			base = join(state.project.out, "tmp", tprint("%d-%d", os.get_pid(), n))
		}
		make_dirs(os.dir(base))
		p.out_path = tprint("%s.stdout", base)
		p.err_path = tprint("%s.stderr", base)
		// Inheritable: on Windows a child gets only the handles opened so
		flags := os.File_Flags{.Write, .Create, .Trunc, .Inheritable}
		out, e1 := os.open(p.out_path, flags)
		err, e2 := os.open(p.err_path, flags)
		if e1 != nil || e2 != nil {
			fatal("cannot create %s", p.out_path)
		}
		p.files = {out, err}
		desc.stdout, desc.stderr = out, err
	} else {
		desc.stdout, desc.stderr = os.stderr, os.stderr
	}
	p.start = time.tick_now()
	process, err := os.process_start(desc)
	if err != nil {
		fatal("cannot start %s: %v", r.cmd[0], err)
	}
	p.process = process
	return p
}

// Waits for a started process (killing it at its timeout) and collects its output.
wait :: proc(p: ^Proc) -> Ran {
	timeout := p.run.timeout > 0 ? p.run.timeout - time.tick_since(p.start) : os.TIMEOUT_INFINITE
	if p.run.timeout > 0 && timeout < time.Millisecond {
		timeout = time.Millisecond
	}
	st: os.Process_State
	err: os.Error
	if r, ok := p.reaped.?; ok {
		st = r
	} else {
		st, err = os.process_wait(p.process, timeout)
	}
	ran: Ran
	if err != nil || !st.exited {
		_ = os.process_kill(p.process)
		st, _ = os.process_wait(p.process)
		ran.timed_out = err == nil || err == .Timeout
	}
	ran.exit_code = st.exit_code
	ran.ok = st.exited && st.exit_code == 0 && !ran.timed_out
	ran.seconds = time.duration_seconds(time.tick_since(p.start))
	return collect(p, ran)
}

// Whether a started process has ended (without blocking).
done :: proc(p: ^Proc) -> bool {
	if _, ok := p.reaped.?; ok {
		return true
	}
	st, err := os.process_wait(p.process, 0)
	if err == nil && st.exited {
		p.reaped = st
		return true
	}
	return false
}

@(private)
collect :: proc(p: ^Proc, ran: Ran) -> Ran {
	ran := ran
	if p.run.capture {
		os.close(p.files[0])
		os.close(p.files[1])
		ran.stdout, _ = read_text(p.out_path)
		ran.stderr, _ = read_text(p.err_path)
		if p.run.log_to == "" {
			os.remove(p.out_path)
			os.remove(p.err_path)
		}
	}
	return ran
}

// Runs a process to the end.
run_proc :: proc(r: Run) -> Ran {
	p := start(r)
	return wait(&p)
}

// Runs a process; a failure stops the command with its output.
must_run :: proc(r: Run, what: string) -> Ran {
	ran := run_proc(r)
	if !ran.ok {
		if r.capture {
			log("%s", tail(strings.concatenate({ran.stdout, ran.stderr}, context.temp_allocator), 4000))
		}
		if ran.timed_out {
			fatal("%s timed out after %.0fs", what, time.duration_seconds(r.timeout))
		}
		fatal("%s failed (exit %d)", what, ran.exit_code)
	}
	return ran
}

// Runs every process, at most `parallel` at a time (0: all at once), and returns their results in order.
run_all :: proc(runs: []Run, parallel := 0) -> []Ran {
	results := make([]Ran, len(runs))
	limit := parallel > 0 ? parallel : len(runs)
	running: [dynamic]struct {
		i: int,
		p: Proc,
	}
	next := 0
	for next < len(runs) || len(running) > 0 {
		for next < len(runs) && len(running) < limit {
			append(&running, struct {
				i: int,
				p: Proc,
			}{next, start(runs[next])})
			next += 1
		}
		progressed := false
		for k := 0; k < len(running); {
			if done(&running[k].p) {
				results[running[k].i] = wait(&running[k].p)
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
		cand := join(dir, name)
		when ODIN_OS == .Windows {
			if !strings.has_suffix(name, ".exe") {
				cand = tprint("%s.exe", cand)
			}
		}
		if os.is_file(cand) {
			return cand
		}
	}
	return ""
}

// The last `n` bytes of a text, for error output.
tail :: proc(text: string, n: int) -> string {
	return len(text) > n ? text[len(text) - n:] : text
}

// A command line for logs, with the values of -define:UNIFIED_EOS_* (credentials) replaced.
redact :: proc(cmd: []string) -> []string {
	out := make([]string, len(cmd), context.temp_allocator)
	for a, i in cmd {
		out[i] = a
		if strings.has_prefix(a, "-define:UNIFIED_EOS_") {
			if eq := strings.index_byte(a, '='); eq >= 0 {
				out[i] = tprint("%s=***", a[:eq])
			}
		}
	}
	return out
}

sort_strings :: proc(s: []string) {
	slice.sort(s)
}

// Lines of a text that contain any of the needles.
lines_with :: proc(text: string, needles: ..string) -> []string {
	out: [dynamic]string
	text := text
	for line in strings.split_lines_iterator(&text) {
		for n in needles {
			if strings.contains(line, n) {
				append(&out, line)
				break
			}
		}
	}
	return out[:]
}
