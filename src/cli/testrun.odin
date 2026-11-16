package cli

import "core:os"
import "core:strings"
import "core:time"

// Odin's test runner stops a crashed test by freezing its thread: a lock that test held (a mutex shared between
// tests, the heap) stays held, every test that waits for it waits forever, and the runner never ends. So a test
// binary never runs bare: uni builds it (-build-mode:test, TEST_RUN_FLAGS) and runs it under a watchdog that kills
// it CRASH_GRACE after a crash or at its timeout, and names the test that crashed and the tests still running.

// The runner logs each test's state changes; the watchdog reads them (and doesn't echo them).
TEST_RUN_FLAGS :: []string{"-build-mode:test", "-define:ODIN_TEST_LOG_STATE_CHANGES=true"}

// How long a test binary may run on after a test crashed: the other tests normally end within it.
CRASH_GRACE :: 3 * time.Second

// What the runner's output says about the tests.
Test_Watch :: struct {
	running: [dynamic]string, // package.test, in start order
	crashed: [dynamic]string,
}

// Takes one line of the runner's output; true when it is a state change (the log has it, the terminal doesn't).
test_watch_line :: proc(watch: ^Test_Watch, line: string) -> (state_change: bool) {
	CHANGE :: " changed state to "
	CRASH :: "Caught signal to stop test #"
	if i := strings.index(line, "] Test #"); i >= 0 {
		rest := line[i + len("] Test #"):]
		j := strings.index(rest, CHANGE)
		space := strings.index_byte(rest, ' ')
		if j < 0 || space < 0 || space >= j {
			return false
		}
		name := rest[space + 1:j]
		if strings.trim_right(rest[j + len(CHANGE):], ".\r\n") == "Running" {
			append(&watch.running, strings.clone(name))
		} else {
			test_watch_drop(watch, name)
		}
		return true
	}
	if i := strings.index(line, CRASH); i >= 0 {
		rest := line[i + len(CRASH):]
		space := strings.index_byte(rest, ' ')
		j := strings.index(rest, " for: ")
		if space >= 0 && j > space {
			name := rest[space + 1:j]
			append(&watch.crashed, strings.clone(name))
			test_watch_drop(watch, name)
		}
	}
	return false
}

@(private)
test_watch_drop :: proc(watch: ^Test_Watch, name: string) {
	for running_name, k in watch.running {
		if running_name == name {
			ordered_remove(&watch.running, k)
			return
		}
	}
}

// Runs a test binary to the end under the watchdog, its output kept whole in <exe>.log. A passing run prints only the
// runner's warnings (a leak, a test's log.warn: test_output_warnings) and its last line, "Finished N tests"; a
// failing one prints the whole output (state changes aside), and --verbose echoes it as it comes. A run killed after
// a crash or at its timeout also says which tests crashed and which were still running.
run_test_binary :: proc(exe: string, timeout: time.Duration) -> bool {
	log_path := tprint("%s.log", exe)
	log_file, err := os.open(log_path, {.Write, .Create, .Trunc, .Inheritable})
	if err != nil {
		fatal("cannot create %s", log_path)
	}
	if state.verbose do log("+ %s", exe)
	start := time.tick_now()
	process, start_err := os.process_start({
		command = strs(exe),
		stdout  = log_file,
		stderr  = log_file,
	})
	if start_err != nil {
		fatal("cannot start %s: %v", exe, start_err)
	}
	reader, open_err := os.open(log_path)
	if open_err != nil {
		fatal("cannot read %s", log_path)
	}
	watch: Test_Watch
	output: [dynamic]u8 // what the terminal gets: every line but the state changes
	pending: [dynamic]u8
	buf: [16 * 1024]u8
	crash_at: Maybe(time.Tick)
	exited: Maybe(os.Process_State)
	killed := ""
	for {
		if exit_state, wait_err := os.process_wait(process, 0); wait_err == nil && exit_state.exited {
			exited = exit_state
		}
		// Drain what the binary wrote (all of it once it has exited).
		for {
			count, _ := os.read(reader, buf[:])
			if count <= 0 {
				break
			}
			append(&pending, ..buf[:count])
			for {
				newline := -1
				for byte, k in pending {
					if byte == '\n' {
						newline = k
						break
					}
				}
				if newline < 0 {
					break
				}
				line := string(pending[:newline + 1])
				had := len(watch.crashed)
				if !test_watch_line(&watch, line) {
					append(&output, ..transmute([]u8)line)
					if state.verbose {
						os.write_string(os.stderr, line)
					}
				}
				if len(watch.crashed) > had && crash_at == nil {
					crash_at = time.tick_now()
				}
				remove_range(&pending, 0, newline + 1)
			}
		}
		if exited != nil {
			break
		}
		if crashed_at, ok := crash_at.?; ok && time.tick_since(crashed_at) > CRASH_GRACE {
			killed = tprint("it did not end within %.0fs of the crash", time.duration_seconds(CRASH_GRACE))
		} else if timeout > 0 && time.tick_since(start) > timeout {
			killed = tprint("it ran past its timeout, %.0fs", time.duration_seconds(timeout))
		}
		if killed != "" {
			_ = os.process_kill(process)
			exit_state, _ := os.process_wait(process)
			exited = exit_state
			// one more pass collects what it wrote before it died
			continue
		}
		time.sleep(10 * time.Millisecond)
	}
	if len(pending) > 0 {
		append(&output, ..pending[:])
		append(&output, '\n')
		if state.verbose {
			os.write_string(os.stderr, string(pending[:]))
			os.write_string(os.stderr, "\n")
		}
	}
	os.close(reader)
	os.close(log_file)
	exit_state := exited.?
	seconds := time.duration_seconds(time.tick_since(start))
	passed := killed == "" && exit_state.exited && exit_state.exit_code == 0
	if !state.verbose {
		if passed {
			for line in test_output_warnings(string(output[:])) {
				log("%s", line)
			}
		} else {
			os.write_string(os.stderr, string(output[:]))
		}
	}
	if killed != "" {
		log("uni: %s killed after %.1fs: %s", os.base(exe), seconds, killed)
		if len(watch.crashed) > 0 {
			log("  crashed: %s", strings.join(watch.crashed[:], ", "))
			log("  (a crashed test can leave a lock held that other tests wait for)")
		}
		if len(watch.running) > 0 {
			log("  still running: %s", strings.join(watch.running[:], ", "))
		}
		log("  the whole output: %s", rel(log_path))
		return false
	}
	return passed
}

// The lines of a passing test run worth showing: each warning or error the runner logged ("[WARN ]", "[ERROR]": a
// leak report, a test's log.warn) with the indented lines under it, and the runner's "Finished N tests" line.
// Everything else (the tests' own prints, a fuzz test's expected rejections, the runner's [INFO] lines) stays in the
// log.
test_output_warnings :: proc(output: string) -> []string {
	out: [dynamic]string
	in_warning := false
	for line in strings.split_lines(output, context.temp_allocator) {
		if strings.has_prefix(line, "[WARN") || strings.has_prefix(line, "[ERROR") {
			in_warning = true
		} else if in_warning && (strings.has_prefix(line, " ") || strings.has_prefix(line, "\t")) {
			// the warning's own lines (the leaks it lists)
		} else {
			in_warning = false
			if !strings.has_prefix(line, "Finished ") {
				continue
			}
		}
		append(&out, line)
	}
	return out[:]
}

// A suite's budget for a warm run (`--long`: its long budget; `--box3d-debug`: plus BOX3D_DEBUG_EXTRA_BUDGET).
suite_budget :: proc(suite: ^Suite, opts: Test_Options) -> f64 {
	budget := opts.long && suite.long_budget > 0 ? suite.long_budget : suite.budget
	if suite.name == "odin" && opts.box3d_debug {
		budget += BOX3D_DEBUG_EXTRA_BUDGET
	}
	return budget
}

// What CI allows the named suite (its budget, CI_BUDGET_SCALE times): a test binary still running then has hung.
suite_timeout :: proc(name: string, opts: Test_Options) -> time.Duration {
	for &suite in state.suites {
		if suite.name == name {
			return time.Duration(suite_budget(&suite, opts) * CI_BUDGET_SCALE * f64(time.Second))
		}
	}
	return 0
}
