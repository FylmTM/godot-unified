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

@(test)
command_line_reads_the_replay_clip :: proc(t: ^testing.T) {
	args, problems, _ := godot.parse_command_line({
			"--replay",
			"rec",
			"--replay-from",
			"4.5s",
			"--replay-to",
			"900",
			"--replay-speed",
			"2",
			"--replay-player",
			"2",
			"--replay-fps",
			"30",
		}, true)
	defer delete(args.replay)
	defer delete(args.replay_from)
	defer delete(args.replay_to)
	defer delete(args.replay_speed)
	testing.expect_value(t, len(problems), 0)
	clip := args.clip
	testing.expect(t, clip.from.set && clip.from.seconds)
	testing.expect_value(t, clip.from.value, 4.5)
	testing.expect(t, clip.to.set && !clip.to.seconds)
	testing.expect_value(t, godot.replay_point_tick(clip.from, 100, 64, 0), 388) // 4.5 s after the first tick
	testing.expect_value(t, godot.replay_point_tick(clip.to, 100, 64, 0), 900) // a tick is a tick
	testing.expect_value(t, godot.replay_point_tick({}, 100, 64, 7), 7) // unset: the fallback
	testing.expect_value(t, clip.speed, 2)
	testing.expect_value(t, clip.player, 2)
	testing.expect_value(t, clip.fps, 30)
	cases := []struct {
		args: []string,
		want: string,
	} {
		{{"--replay-from", "soon"}, "--replay-from wants a tick or seconds"},
		{{"--replay-to", "-3"}, "--replay-to wants a tick or seconds"},
		{{"--replay-from", "10s", "--replay-to", "5s"}, "is not after --replay-from"},
		{{"--replay-speed", "9"}, "--replay-speed wants a speed from 0.25 to 4"},
		{{"--replay-fps", "0"}, "--replay-fps wants a whole number from 1 to 1000"},
	}
	for test_case in cases {
		bad, found, _ := godot.parse_command_line(test_case.args, true)
		delete(bad.replay_from)
		delete(bad.replay_to)
		delete(bad.replay_speed)
		if !testing.expectf(t, len(found) == 1, "%v: %d problems (%v)", test_case.args, len(found), found) do continue
		testing.expectf(t, strings.contains(found[0], test_case.want), "%v: %q", test_case.args, found[0])
	}
}

@(test)
frame_clock_shows_each_frames_moment :: proc(t: ^testing.T) {
	// 64 Hz at 30 fps: frame n is 64n/30 ticks in, shown as the first tick at or after it and its alpha
	tick, alpha := godot.frame_clock_tick(100, 0, 30, 64, 1)
	testing.expect_value(t, tick, 100)
	testing.expect_value(t, alpha, 1)
	tick, alpha = godot.frame_clock_tick(100, 1, 30, 64, 1) // 2.13 ticks in
	testing.expect_value(t, tick, 103)
	testing.expectf(t, abs(alpha - 0.1333) < 0.001, "alpha %v", alpha)
	tick, alpha = godot.frame_clock_tick(100, 15, 30, 64, 1) // exactly 32 ticks in
	testing.expect_value(t, tick, 132)
	testing.expect_value(t, alpha, 1)
	tick, _ = godot.frame_clock_tick(0, 15, 15, 64, 2) // twice as fast: 128 ticks in
	testing.expect_value(t, tick, 128)
	// the clip's length: its ticks at its speed, in frames
	testing.expect_value(t, godot.frame_clock_frames(0, 640, 15, 64, 1), 150) // 10 s at 15 fps
	testing.expect_value(t, godot.frame_clock_frames(0, 640, 30, 64, 2), 150) // 5 s at 30 fps
	testing.expect_value(t, godot.frame_clock_frames(0, 65, 30, 64, 1), 31) // a part frame is a frame
	testing.expect_value(t, godot.frame_clock_frames(5, 5, 30, 64, 1), 1) // a clip of one tick: its frame
}
