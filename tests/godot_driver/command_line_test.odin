// unified:godot's command line (src/godot/README.md, command-line flags): its own flags are read and checked, a near
// miss of one is an error, the game's and tool scripts' flags pass, and a build without the dev UI ignores the dev
// flags.
package test_godot_driver

import "core:strings"
import "core:testing"

import "unified:godot"

@(test)
command_line_reads_its_flags_and_leaves_the_games :: proc(t: ^testing.T) {
	args, problems, ignored := godot.parse_command_line({
			"--autostart",
			"--ticks",
			"600",
			"--seed",
			"-3",
			"--no-settings",
			"--frames=5",
			"--role",
			"host",
			"--lan",
			"--rejoin",
			"--name",
			"x",
			"--join",
			"a:1",
			"--control",
			"drive/1.port",
		}, true)
	defer delete(args.join)
	defer delete(args.control)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, len(ignored), 0)
	testing.expect(t, args.autostart)
	testing.expect_value(t, args.ticks, 600)
	testing.expect_value(t, args.seed, -3)
	testing.expect_value(t, args.join, "a:1")
	testing.expect_value(t, args.control, "drive/1.port") // the control socket's port file
	testing.expect(t, !args.verified_players) // the verified timeline is off unless asked for
	verified, _, _ := godot.parse_command_line({"--verified-players"}, true)
	testing.expect(t, verified.verified_players)
}

@(test)
command_line_rejects_bad_numbers_and_near_misses :: proc(t: ^testing.T) {
	cases := []struct {
		args: []string,
		want: string, // a fragment of the one problem
	} {
		{{"--ticks", "abc"}, "--ticks wants a whole number"},
		{{"--ticks"}, "--ticks wants a whole number"},
		{{"--host-port", "70000"}, "--host-port wants a whole number from 1 to 65535"},
		{{"--tiks", "100"}, "did you mean --ticks"},
		{{"--sede", "1"}, "did you mean --seed"},
		{{"--quit-at-nd"}, "did you mean --quit-at-end"},
		{{"--ticks=100"}, "write --ticks VALUE"},
		{{"--join-code"}, "--join-code wants a code"},
	}
	for test_case in cases {
		args, problems, _ := godot.parse_command_line(test_case.args, true)
		delete(args.join)
		delete(args.join_code)
		if !testing.expectf(t, len(problems) == 1, "%v: %d problems (%v)", test_case.args, len(problems), problems) {
			continue
		}
		testing.expectf(t, strings.contains(problems[0], test_case.want), "%v: %q", test_case.args, problems[0])
	}
}

@(test)
command_line_without_the_dev_ui_ignores_dev_flags :: proc(t: ^testing.T) {
	args, problems, ignored := godot.parse_command_line({
			"--scripted",
			"--lag",
			"80",
			"--bench",
			"500",
			"--devui",
			"--seed",
			"4",
			"--verified-players",
			"--autostart",
			"--ticks",
			"300",
		}, false)
	testing.expect_value(t, len(problems), 0) // an ignored flag's value isn't read
	testing.expect_value(t, len(ignored), 6)
	testing.expect(t, !args.verified_players)
	testing.expect(t, args.autostart && !args.scripted && !args.devui)
	testing.expect(t, args.lag_ms == 0 && args.bench == 0 && args.seed == 0)
	testing.expect_value(t, args.ticks, 300) // not a dev flag: a release build's smoke test bounds its session with it
}
