// Odin's test runner stops a crashed test by freezing its thread: a lock that test held (a mutex shared between
// tests, the heap) stays held, every test that waits for it waits forever, and the runner never ends. So a test
// binary never runs bare: uni builds it (-build-mode:test, TEST_RUN_FLAGS) and runs it under a watchdog that kills
// it CRASH_GRACE after a crash or at its timeout, and names the test that crashed and the tests still running.
package cli

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// The runner logs each test's state changes; the watchdog reads them (and doesn't echo them).
TEST_RUN_FLAGS :: []string{"-build-mode:test", "-define:ODIN_TEST_LOG_STATE_CHANGES=true"}

// How long a test binary may run on after a test crashed: the other tests normally end within it.
CRASH_GRACE :: 3 * time.Second

// What the runner's output says about the tests.
Test_Watch :: struct {
	running: [dynamic]string, // package.test, in start order
	crashed: [dynamic]string,
	failed:  [dynamic]string,
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
		switch strings.trim_right(rest[j + len(CHANGE):], ".\r\n") {
		case "Running":
			append(&watch.running, strings.clone(name))
		case "Failed":
			append(&watch.failed, strings.clone(name))
			test_watch_drop(watch, name)
		case:
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

// One test binary run_test_binaries runs: its process, its log, and what the watchdog read from it.
@(private)
Test_Run :: struct {
	exe:      string,
	log_path: string,
	log_file: ^os.File,
	reader:   ^os.File,
	process:  os.Process,
	watch:    Test_Watch,
	output:   [dynamic]u8, // what the terminal gets: every line but the state changes
	pending:  [dynamic]u8, // the start of a line not ended yet
	crash_at: Maybe(time.Tick),
	exited:   Maybe(os.Process_State),
	done:     bool, // exited, and everything it wrote read
	killed:   string, // why the watchdog killed it ("": it ended by itself)
	passed:   bool,
	seconds:  f64,
}

// Runs test binaries to the end, all at once, each under the watchdog, its output kept whole in <exe>.log. A passing
// run prints only the runners' warnings (a leak, a test's log.warn: test_output_warnings) and one last line,
// "Finished N tests" (with several binaries, their tests added up); a failing binary prints its whole output (state
// changes aside), and --verbose echoes every binary's as it comes. A binary killed after a crash or at the timeout
// also says which tests crashed and which were still running.
run_test_binaries :: proc(exes: []string, timeout: time.Duration) -> bool {
	runs := make([]Test_Run, len(exes))
	start := time.tick_now()
	for exe, i in exes {
		run := &runs[i]
		run.exe = exe
		run.log_path = aprintf("%s.log", exe)
		log_file, err := os.open(run.log_path, {.Write, .Create, .Trunc})
		if err != nil {
			fatal("cannot create %s", run.log_path)
		}
		run.log_file = log_file
		if state.verbose do log("+ %s", exe)
		process, start_err := spawn({command = strs(exe), stdout = log_file, stderr = log_file}, log_file)
		if start_err != nil {
			fatal("cannot start %s: %v", exe, start_err)
		}
		run.process = process
		reader, open_err := os.open(run.log_path)
		if open_err != nil {
			fatal("cannot read %s", run.log_path)
		}
		run.reader = reader
	}
	buf: [16 * 1024]u8
	for {
		running := 0
		for &run in runs {
			if run.done do continue
			if run.exited == nil {
				if exit_state, wait_err := os.process_wait(run.process, 0); wait_err == nil && exit_state.exited {
					run.exited = exit_state
				}
			}
			test_run_drain(&run, buf[:])
			if run.exited != nil {
				run.done = true
				run.seconds = time.duration_seconds(time.tick_since(start))
				continue
			}
			running += 1
			if crashed_at, ok := run.crash_at.?; ok && time.tick_since(crashed_at) > CRASH_GRACE {
				run.killed = aprintf("it did not end within %.0fs of the crash", time.duration_seconds(CRASH_GRACE))
			} else if timeout > 0 && time.tick_since(start) > timeout {
				run.killed = aprintf("it ran past its timeout, %.0fs", time.duration_seconds(timeout))
			}
			if run.killed != "" {
				_ = os.process_kill(run.process)
				exit_state, _ := os.process_wait(run.process)
				run.exited = exit_state // the next pass collects what it wrote before it died
			}
		}
		if running == 0 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	passed := true
	finished := 0 // the tests the binaries ran, when they all passed
	seconds: f64
	for &run in runs {
		if len(run.pending) > 0 {
			append(&run.output, ..run.pending[:])
			append(&run.output, '\n')
			if state.verbose {
				os.write_string(os.stderr, string(run.pending[:]))
				os.write_string(os.stderr, "\n")
			}
		}
		os.close(run.reader)
		os.close(run.log_file)
		exit_state := run.exited.?
		run.passed = run.killed == "" && exit_state.exited && exit_state.exit_code == 0
		passed = passed && run.passed
		finished += test_output_finished(string(run.output[:]))
		seconds = max(seconds, run.seconds)
	}
	several := len(runs) > 1
	if !state.verbose {
		for run in runs {
			if !run.passed {
				os.write_string(os.stderr, test_run_terminal_output(runs, run))
				continue
			}
			for line in test_output_warnings(string(run.output[:])) {
				if several && strings.has_prefix(line, "Finished ") do continue // added up below
				log("%s", line)
			}
		}
		if several && passed {
			log(
				"Finished %d test%s in %v. All tests were successful.",
				finished,
				finished == 1 ? "" : "s",
				time.Duration(seconds * f64(time.Second)),
			)
		}
	}
	for run in runs {
		if run.killed == "" do continue
		log("uni: %s killed after %.1fs: %s", os.base(run.exe), run.seconds, run.killed)
		if len(run.watch.crashed) > 0 {
			log("  crashed: %s", strings.join(run.watch.crashed[:], ", "))
			log("  (a crashed test can leave a lock held that other tests wait for)")
		}
		if len(run.watch.running) > 0 {
			log("  still running: %s", strings.join(run.watch.running[:], ", "))
		}
		log("  the whole output: %s", rel(run.log_path))
	}
	return passed
}

// Reads what a test binary wrote since the last call, a whole line at a time: the watchdog reads each, the terminal
// output keeps all but the state changes (--verbose echoes them as they come).
@(private)
test_run_drain :: proc(run: ^Test_Run, buf: []u8) {
	for {
		count, _ := os.read(run.reader, buf)
		if count <= 0 {
			return
		}
		append(&run.pending, ..buf[:count])
		for {
			newline := -1
			for byte, k in run.pending {
				if byte == '\n' {
					newline = k
					break
				}
			}
			if newline < 0 {
				break
			}
			line := string(run.pending[:newline + 1])
			had := len(run.watch.crashed)
			if !test_watch_line(&run.watch, line) {
				append(&run.output, ..transmute([]u8)line)
				if state.verbose {
					os.write_string(os.stderr, line)
				}
			}
			if len(run.watch.crashed) > had && run.crash_at == nil {
				run.crash_at = time.tick_now()
			}
			remove_range(&run.pending, 0, newline + 1)
		}
	}
}

// A failing binary's output for the terminal, without the leak lists of the tests that failed or crashed
// (test_output_without_leaks). With several binaries, a test `--only` names that another binary has is no failure of
// this one: its "No test found" line is dropped unless no binary has the test.
@(private)
test_run_terminal_output :: proc(runs: []Test_Run, run: Test_Run) -> string {
	failed := make([dynamic]string, context.temp_allocator)
	append(&failed, ..run.watch.failed[:])
	append(&failed, ..run.watch.crashed[:])
	trimmed := test_output_without_leaks(string(run.output[:]), failed[:], rel(run.log_path))
	if len(runs) == 1 {
		return trimmed
	}
	builder := strings.builder_make()
	text := trimmed
	for line in strings.split_lines_after_iterator(&text) {
		if strings.has_prefix(line, "No test found for the name: ") {
			everywhere := true
			for other in runs {
				everywhere = everywhere && strings.contains(string(other.output[:]), strings.trim_right(line, "\r\n"))
			}
			if !everywhere do continue
		}
		strings.write_string(&builder, line)
	}
	return strings.to_string(builder)
}

// A runner's output with the memory report of each test in `failed` cut to its first line and a count: a test that
// failed or panicked leaks what it held, and the list (one line per allocation) buries why it failed. `log`: where
// the whole output is.
test_output_without_leaks :: proc(output: string, failed: []string, log: string) -> string {
	builder := strings.builder_make()
	cut := 0 // leak lines left out of the current report
	cutting := false
	end_cut :: proc(builder: ^strings.Builder, cut: ^int, log: string) {
		if cut^ > 0 do fmt.sbprintf(builder, "        (%d leak lines of a failed test left out: %s)\n", cut^, log)
		cut^ = 0
	}
	text := output
	for line in strings.split_lines_after_iterator(&text) {
		if cutting && strings.has_prefix(strings.trim_left_space(line), "+++ ") {
			cut += 1
			continue
		}
		end_cut(&builder, &cut, log)
		cutting = false
		if strings.has_prefix(line, "[WARN") || strings.has_prefix(line, "[ERROR") {
			_, _, name := strings.partition(strings.trim_right_space(line), ") :: ")
			cutting = name != "" && slice.contains(failed, name)
		}
		strings.write_string(&builder, line)
	}
	end_cut(&builder, &cut, log)
	return strings.to_string(builder)
}

// The number of tests a runner's output says it ran ("Finished N tests"; 0 when it ran none).
test_output_finished :: proc(output: string) -> int {
	text := output
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "Finished ") do continue
		words := strings.fields(line[len("Finished "):], context.temp_allocator)
		if len(words) > 0 {
			count, _ := strconv.parse_int(words[0])
			return count
		}
	}
	return 0
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

// A suite's budget for a warm run (`--long`: its long budget).
suite_budget :: proc(suite: ^Suite, opts: Test_Options) -> f64 {
	return opts.long && suite.long_budget > 0 ? suite.long_budget : suite.budget
}

// What CI allows a suite (ci_allowance): CI_BUDGET_SCALE times its budget (`--long`: its long budget), or its CI
// budget when that is more.
suite_ci_budget :: proc(suite: ^Suite, opts: Test_Options) -> f64 {
	return ci_allowance(suite_budget(suite, opts), suite.ci_budget)
}

// What CI allows the named suite (suite_ci_budget), anywhere: a test binary still running then has hung.
suite_timeout :: proc(name: string, opts: Test_Options) -> time.Duration {
	for &suite in state.suites {
		if suite.name == name {
			return time.Duration(suite_ci_budget(&suite, opts) * f64(time.Second))
		}
	}
	return 0
}
