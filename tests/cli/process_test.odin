// Captured runs (src/cli/process.odin): what they leave behind, and that every process start goes through cli.spawn.
package test_cli

import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "unified:cli"

// Children started together, each captured, the last still running when the others are collected: on Windows a child
// started while its siblings' capture files are open would hold them (every inheritable handle is inherited), and
// their removal at collection would fail. Every capture file is removed. (Counted at removal, not by listing the
// capture directory: other tests' runs in flight share it.)
@(test)
captured_runs_leave_nothing_behind :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI's own strings and results
	quick := []string{"true"} when ODIN_OS != .Windows else []string{"cmd", "/c", "exit 0"}
	slow := []string{"sleep", "1"} when ODIN_OS != .Windows else []string{"ping", "-n", "2", "127.0.0.1"}
	runs := []cli.Run {
		{cmd = quick, capture = true, quiet = true},
		{cmd = quick, capture = true, quiet = true},
		{cmd = quick, capture = true, quiet = true},
		{cmd = slow, capture = true, quiet = true}, // started last: it would inherit the three before it
	}
	leaks := sync.atomic_load(&cli.capture_leaks)
	for ran in cli.run_all(runs) do testing.expect(t, ran.ok, "every run ends well")
	testing.expect_value(t, sync.atomic_load(&cli.capture_leaks) - leaks, 0)
}

// Every process start in the repo's Odin code goes through cli.spawn: a start of core:os's own (os.process_start,
// os.process_exec) anywhere in a binary that holds the CLI, a test's included, would inherit the capture files a start
// there makes inheritable for an instant (Windows) and keep them past their removal. Only start_process, spawn's own
// (src/cli/spawn_*.odin), calls core:os.
@(test)
no_process_starts_outside_spawn :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := #directory + "/../.."
	calls := []string{"os." + "process_start(", "os." + "process_exec("} // split: this file holds neither
	walk :: proc(t: ^testing.T, dir: string, calls: []string) {
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for entry in entries {
			if entry.type == .Directory {
				if !strings.has_prefix(entry.name, ".") && entry.name != "unified" do walk(t, entry.fullpath, calls)
				continue
			}
			if !strings.has_suffix(entry.name, ".odin") || strings.has_prefix(entry.name, "spawn_") do continue
			text, _ := os.read_entire_file(entry.fullpath, context.temp_allocator)
			for call in calls {
				testing.expectf(
					t,
					!strings.contains(string(text), call),
					"%s calls %s: start processes with cli.run_proc or cli.start (cli.spawn)",
					entry.fullpath,
					call,
				)
			}
		}
	}
	for dir in ([]string{"src", "tests", "tools", "examples"}) do walk(t, cli.join(root, dir), calls)
}

// `drive stop` kills only the game it started: a recorded pid now held by another process (the game ended; the OS
// reused its pid) is not the instance, so it is never killed. A process is the one whose command line holds the
// marker its start gave it (the instance's --control port file).
@(test)
a_reused_pid_is_not_the_instance :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	pid := os.get_pid()
	testing.expect(t, !cli.process_runs(0, os.args[0]), "no pid")
	testing.expect(t, cli.process_runs(pid, ""), "this process runs, though it isn't its own child")
	// The marker checks need arguments the OS gives back: Linux leaves argv[0] out, so a test binary run with none
	// has nothing to match (process_runs then goes by the pid alone, as for any process whose arguments are unknown).
	info, err := os.process_info_by_pid(pid, {.Command_Args}, context.temp_allocator)
	if err != nil || .Command_Args not_in info.fields || len(info.command_args) == 0 {
		log.infof("no arguments of this process to match (%v): the marker checks are skipped", err)
		return
	}
	testing.expect(t, !cli.process_runs(pid, "/elsewhere/.out/drive/1.port"), "another instance's port file")
	testing.expect(t, cli.process_runs(pid, info.command_args[len(info.command_args) - 1]), "its own arguments")
}

// Two uni processes that would unpack or build the same thing take turns through a lock file; one left by a process
// that is gone, or one that never got its pid, is taken over; released, a lock another took over stays theirs, and a
// failing exit releases what it holds. A fresh copy renamed into place where another process already put one gives
// way to it.
@(test)
locks_and_renames_into_place :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, _ := os.make_directory_temp("", "unified-cli-test-*", context.allocator)
	defer os.remove_all(dir)
	path := cli.join(dir, "work.lock")
	lock := cli.lock_acquire(path, "test")
	testing.expect(t, os.is_file(path), "held")
	cli.lock_release(lock)
	testing.expect(t, !os.exists(path), "released")
	testing.expect(t, cli.write_file(path, transmute([]byte)string("999999999\n")), "a lock whose process is gone")
	lock = cli.lock_acquire(path, "test")
	held, _ := os.read_entire_file(path, context.allocator)
	testing.expect_value(t, strings.trim_space(string(held)), cli.aprintf("%d", os.get_pid()))
	cli.lock_release(lock)
	// a lock that never got its pid (its process killed in between): taken over once it is LOCK_UNWRITTEN old, also
	// past a takeover guard a killed waiter left
	long_ago := time.time_add(time.now(), -2 * cli.LOCK_UNWRITTEN)
	testing.expect(t, cli.write_file(path, nil))
	testing.expect(t, cli.write_file(cli.aprintf("%s.takeover", path), nil))
	testing.expect(t, os.change_times(path, long_ago, long_ago) == nil)
	testing.expect(t, os.change_times(cli.aprintf("%s.takeover", path), long_ago, long_ago) == nil)
	lock = cli.lock_acquire(path, "test")
	held, _ = os.read_entire_file(path, context.allocator)
	testing.expect_value(t, strings.trim_space(string(held)), cli.aprintf("%d", os.get_pid()))
	testing.expect(t, !os.exists(cli.aprintf("%s.takeover", path)), "the guard is gone")
	// taken over meanwhile (this one judged stale): released, it stays theirs
	testing.expect(t, cli.write_file(path, transmute([]byte)string("1\n")))
	cli.lock_release(lock)
	testing.expect(t, os.is_file(path), "another's lock stays")
	os.remove(path)
	// a failing exit runs no defer: unwind (fatal's, usage's) releases what is still held (lock_release_all; unwind
	// itself would also run the undos other tests register)
	lock = cli.lock_acquire(path, "test")
	cli.lock_release_all()
	testing.expect(t, !os.exists(path), "released by lock_release_all")
	placed, tmp := cli.join(dir, "placed"), cli.join(dir, "placed.1.tmp")
	testing.expect(t, cli.write_file(cli.join(placed, "ready"), transmute([]byte)string("theirs")))
	testing.expect(t, cli.write_file(cli.join(tmp, "ready"), transmute([]byte)string("ours")))
	// a rename onto a directory that holds files fails on every OS: theirs stays, ours goes
	cli.rename_into_place(tmp, placed, cli.join(placed, "ready"))
	testing.expect(t, !os.exists(tmp), "our copy is removed")
	theirs, _ := os.read_entire_file(cli.join(placed, "ready"), context.allocator)
	testing.expect_value(t, string(theirs), "theirs")
}
