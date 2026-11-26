// What `uni coop --record` does to a game's replay folder (cli.replay_install, cli.replay_restore, cli.replay_args):
// the recording's files in, the stale expectation out, the options kept; and everything back when the tests refuse it.
package test_cli

import "core:os"
import "core:testing"
import "unified:cli"

// A recording replaces a folder's: its inputs and snapshot in, expected.unie gone, coop.args holding the options a
// line each (what --rerecord reads back); restored, the folder holds its old bytes again and no coop.args it never had.
@(test)
a_recording_replaces_a_replay_and_restores :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	root, temp_err := os.make_directory_temp("", "unified-replays-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(root)
	recording := cli.join(root, "recordings", "20261126_101500")
	cli.write_text(cli.join(recording, cli.REPLAY_INPUTS), "new inputs")
	cli.write_text(cli.join(recording, cli.REPLAY_SNAPSHOT), "new snapshot")
	cli.write_text(cli.join(recording, "session.json"), "{}")
	folder := cli.replay_folder(cli.join(root, "game"), "lan_pair")
	cli.write_text(cli.join(folder, cli.REPLAY_INPUTS), "old inputs")
	cli.write_text(cli.join(folder, cli.REPLAY_SNAPSHOT), "old snapshot")
	cli.write_text(cli.join(folder, cli.REPLAY_EXPECTED), "old expectation")

	args := []string{"--lan", "--host-profile", "class=Knight", "--", "--play=lan_pair"}
	backup, problem := cli.replay_install(folder, recording, args)
	testing.expect_value(t, problem, "")
	inputs, _ := cli.read_text(cli.join(folder, cli.REPLAY_INPUTS))
	snapshot, _ := cli.read_text(cli.join(folder, cli.REPLAY_SNAPSHOT))
	testing.expect_value(t, inputs, "new inputs")
	testing.expect_value(t, snapshot, "new snapshot")
	testing.expect(t, !os.exists(cli.join(folder, cli.REPLAY_EXPECTED)), "the stale expectation goes")
	testing.expect(t, !os.exists(cli.join(folder, "session.json")), "only the replay's files come")
	saved, found := cli.replay_args(folder)
	testing.expect(t, found, "coop.args is written")
	testing.expect_value(t, len(saved), len(args))
	for arg, i in args do if i < len(saved) do testing.expect_value(t, saved[i], arg)

	cli.replay_restore(backup)
	inputs, _ = cli.read_text(cli.join(folder, cli.REPLAY_INPUTS))
	snapshot, _ = cli.read_text(cli.join(folder, cli.REPLAY_SNAPSHOT))
	expected, _ := cli.read_text(cli.join(folder, cli.REPLAY_EXPECTED))
	testing.expect_value(t, inputs, "old inputs")
	testing.expect_value(t, snapshot, "old snapshot")
	testing.expect_value(t, expected, "old expectation")
	_, found = cli.replay_args(folder)
	testing.expect(t, !found, "the coop.args it never had goes again")
}

// A recording from tick 0 continues no snapshot: the folder's old one goes (the replay would read it). A folder that
// wasn't there is made, and restored, it is gone again. A folder with no recording in it changes nothing.
@(test)
a_recording_without_a_snapshot_and_a_new_folder :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root, temp_err := os.make_directory_temp("", "unified-replays-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(root)
	recording := cli.join(root, "recording")
	cli.write_text(cli.join(recording, cli.REPLAY_INPUTS), "inputs from tick 0")
	folder := cli.join(root, "replays", "old")
	cli.write_text(cli.join(folder, cli.REPLAY_SNAPSHOT), "old snapshot")
	_, problem := cli.replay_install(folder, recording, {})
	testing.expect_value(t, problem, "")
	testing.expect(t, !os.exists(cli.join(folder, cli.REPLAY_SNAPSHOT)), "the old snapshot goes")

	fresh := cli.join(root, "replays", "fresh")
	backup, fresh_problem := cli.replay_install(fresh, recording, {"--lan"})
	testing.expect_value(t, fresh_problem, "")
	testing.expect(t, os.is_file(cli.join(fresh, cli.REPLAY_INPUTS)), "a missing folder is made")
	cli.replay_restore(backup)
	testing.expect(t, !os.exists(fresh), "restored, the folder it made is gone")

	_, refused := cli.replay_install(folder, cli.join(root, "nothing"), {})
	testing.expect(t, refused != "", "a folder without inputs.unil is no recording")
}

// --record and --rerecord take a folder's name, never a path out of the game's replays.
@(test)
a_replay_is_named_not_pathed :: proc(t: ^testing.T) {
	testing.expect(t, cli.replay_name_ok("lan_pair"))
	for bad in ([]string{"", ".", "..", "../x", "a/b", "a\\b", "C:x"}) {
		testing.expectf(t, !cli.replay_name_ok(bad), "%q is refused", bad)
	}
}
