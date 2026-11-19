// Captured runs (src/cli/process.odin): what they leave behind.
package test_cli

import "core:os"
import "core:testing"
import "unified:cli"

// Children started together, each captured, the last still running when the others are collected: on Windows a child
// started while its siblings' capture files are open would hold them (every inheritable handle is inherited), and
// their removal at collection would fail. Nothing stays in .out/tmp.
@(test)
captured_runs_leave_nothing_behind :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI's own strings and results
	dir, temp_err := os.make_directory_temp("", "unified-cli-capture-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(dir)
	saved := cli.state.project.out
	cli.state.project.out = dir
	defer cli.state.project.out = saved

	quick := []string{"true"} when ODIN_OS != .Windows else []string{"cmd", "/c", "exit 0"}
	slow := []string{"sleep", "1"} when ODIN_OS != .Windows else []string{"ping", "-n", "2", "127.0.0.1"}
	runs := []cli.Run {
		{cmd = quick, capture = true, quiet = true},
		{cmd = quick, capture = true, quiet = true},
		{cmd = quick, capture = true, quiet = true},
		{cmd = slow, capture = true, quiet = true}, // started last: it would inherit the three before it
	}
	for ran in cli.run_all(runs) do testing.expect(t, ran.ok, "every run ends well")

	entries, _ := os.read_all_directory_by_path(cli.join(dir, "tmp"), context.temp_allocator)
	testing.expectf(t, len(entries) == 0, "%d files left in .out/tmp", len(entries))
}
