// What `uni help` and each -h show, made from the commands' options structs (cli.command_usage, cli.command_help),
// and what a passing test run prints.
package test_cli

import "core:strings"
import "core:testing"
import "unified:cli"

// Every public command's help has one usage line, and every option says what it does.
@(test)
public_commands_help_is_complete :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	for command in cli.public_commands() {
		testing.expectf(t, len(command.options) > 0, "uni %s names no options type", command.name)
		for option in cli.command_options(command) {
			testing.expectf(t, option.usage != "", "uni %s: %s has no usage text", command.name, option.name)
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

Usage_Mode :: enum {
	dev,
	release,
}

Usage_Opts :: struct {
	game:     string `args:"pos=0" usage:"the game"`,
	mode:     Usage_Mode `usage:"the build"`,
	screen:   string `hint:"n|left" usage:"the screen"`,
	ref:      string `usage:"a ref"`,
	check:    bool `usage:"report only"`,
	box3d:    bool `args:"name=box3d-debug" usage:"renamed"`,
	internal: bool `args:"hidden" usage:"not shown"`,
	overflow: [dynamic]string `hint:"[-- args]" usage:"the rest"`,
}

Usage_Set_Opts :: struct {
	issue: string `args:"pos=0,required" usage:"the issue"`,
	tag:   string `args:"required" usage:"the tag"`,
}

// A usage line reads each option from its field: positionals by name, [..] unless required, enums by their names,
// a `hint` as given, a renamed flag by its name; hidden fields stay out; forms joined with `|`.
@(test)
usage_lines_come_from_the_options :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	command := cli.Command {
		name    = "demo",
		options = cli.option_types(Usage_Opts),
	}
	testing.expect_value(
		t,
		cli.command_usage(command),
		"demo [game] [--mode dev|release] [--screen n|left] [--ref <ref>] [--check] [--box3d-debug] [-- args]",
	)
	command.options = cli.option_forms({"", Usage_Opts}, {"set", Usage_Set_Opts})
	usage := cli.command_usage(command)
	testing.expectf(t, strings.has_suffix(usage, " | demo set <issue> --tag <tag>"), "%s", usage)
	help := cli.command_help(command)
	testing.expect(t, strings.contains(help, "--mode dev|release  the build"), help)
	testing.expect(t, !strings.contains(help, "internal"), help)
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
	// what `test` adds up when the odin suite runs several binaries
	testing.expect_value(t, cli.test_output_finished(output), 274)
	testing.expect_value(t, cli.test_output_finished("No test found for the name: \"x\"\nNo tests to run.\n"), 0)
}
