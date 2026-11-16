// What `uni help` and each -h show against what the commands accept (cli.usage_problems; `uni vet` runs it over every
// command, this project's own too), and what a passing test run prints.
package test_cli

import "core:strings"
import "core:testing"
import "unified:cli"

// Every public command's usage line names exactly the options it parses, with a value where one is taken.
@(test)
public_commands_help_matches_their_options :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	for command in cli.public_commands() {
		for problem in cli.usage_problems(command) {
			testing.expect(t, false, problem)
		}
		help := cli.command_help(command)
		testing.expectf(
			t,
			strings.count(help, "usage: ") == 1,
			"uni %s -h has %d usage lines",
			command.name,
			strings.count(help, "usage: "),
		)
	}
}

Drift_Opts :: struct {
	game:  string `args:"pos=0" usage:"the game"`,
	mode:  string `usage:"dev or release"`,
	check: bool `usage:"report only"`,
	cold:  bool `usage:"start cold"`,
	quiet: bool,
}

// Each way a usage line can drift from its options is caught.
@(test)
usage_problems_catch_drift :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	command := cli.Command {
		name    = "drift",
		// --mode shows no value, --check shows one, --cold and --quiet are left out, --gone is no option, no <game>
		usage   = "[--mode] [--check now] [--gone]",
		options = cli.option_types(Drift_Opts),
	}
	problems := strings.join(cli.usage_problems(command), "\n")
	for want in ([]string {
			"names --gone, which is no option",
			"shows no value for --mode",
			"shows a value for the switch --check",
			"leaves out --cold",
			"leaves out --quiet",
			"quiet has no usage text",
			"doesn't name the positional game",
		}) {
		testing.expectf(t, strings.contains(problems, want), "not caught: %s\n%s", want, problems)
	}
	command.usage = "[game] [--mode m] [--check] [--cold] [--quiet]"
	testing.expect_value(t, len(cli.usage_problems(command)), 1) // quiet's missing usage text
	testing.expect(t, len(cli.usage_problems(cli.Command{name = "bare"})) > 0, "a command must name its options")
}

@(test)
usage_value_and_flags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	usage := "[game] [--mode dev|release|debug] [--window [--mute] [--screen s]] [--no-eos] [--no-eosx X] | --hook"
	testing.expect_value(t, cli.usage_value(usage, "mode"), "dev|release|debug")
	testing.expect_value(t, cli.usage_value(usage, "window"), "")
	testing.expect_value(t, cli.usage_value(usage, "screen"), "s")
	testing.expect_value(t, cli.usage_value(usage, "no-eos"), "")
	testing.expect_value(t, cli.usage_value(usage, "no-eosx"), "X")
	testing.expect_value(t, cli.usage_value(usage, "hook"), "")
	flags := cli.usage_flags(usage)
	testing.expect_value(t, strings.join(flags, " "), "mode window mute screen no-eos no-eosx hook")
	testing.expect_value(t, len(cli.usage_flags("<dir> -- args")), 0)
}

// A passing test run shows the runner's warnings with the lines under them, and its last line; nothing else.
@(test)
passing_run_shows_warnings_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	output := `[INFO ] --- Starting test runner with 28 threads.
b3DeserializeIntoShell: bad magic/version
host: Disconnected (session ended)
[WARN ] --- <573B/14MiB> :: test_netcode.a_leaky_test
        +++ leak        79B @ 0x1 [link.odin:163:loop_send()]
        +++ leak        75B @ 0x2 [link.odin:163:loop_send()]
{"mode":"loop-host","players":2}
[INFO ] --- [image_fuzz_test.odin:112] images loaded
[ERROR] --- [a_test.odin:7:a_test()] a test logged an error
Finished 274 tests in 1.4s. All tests were successful.
`
	shown := cli.test_output_warnings(output)
	testing.expect_value(t, len(shown), 5)
	if len(shown) == 5 {
		testing.expect(t, strings.has_prefix(shown[0], "[WARN ]"))
		testing.expect(t, strings.contains(shown[2], "75B"))
		testing.expect(t, strings.has_prefix(shown[3], "[ERROR]"))
		testing.expect(t, strings.has_prefix(shown[4], "Finished 274 tests"))
	}
}
