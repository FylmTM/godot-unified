// What `uni coop --record` does to a game's replay folder (cli.replay_record, cli.replay_install, cli.replay_restore,
// cli.replay_restore_killed) and how --rerecord gets its options back (cli.coop_record_args, cli.coop_saved_opts):
// the recording's files in, the stale expectation out, the options kept; and everything back when the check refuses
// it, passes without checking, or the run was killed.
package test_cli

import "core:os"
import "core:testing"
import "unified:cli"

// A game's replay folder with an old recording in it, and a new session recording beside it, under a temp root.
@(private = "file")
Fixture :: struct {
	root, recording, folder, backups: string,
}

@(private = "file")
fixture :: proc(t: ^testing.T) -> Fixture {
	root, temp_err := os.make_directory_temp("", "unified-replays-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	f := Fixture {
		root      = root,
		recording = cli.join(root, "user", "recordings", "20261126_101500"),
		folder    = cli.replay_folder(cli.join(root, "game"), "lan_pair"),
		backups   = cli.join(root, "game", ".out", cli.REPLAY_BACKUPS, "lan_pair"),
	}
	cli.write_text(cli.join(f.recording, cli.REPLAY_INPUTS), "new inputs")
	cli.write_text(cli.join(f.recording, cli.REPLAY_SNAPSHOT), "new snapshot")
	cli.write_text(cli.join(f.recording, "session.json"), "{}")
	cli.write_text(cli.join(f.folder, cli.REPLAY_INPUTS), "old inputs")
	cli.write_text(cli.join(f.folder, cli.REPLAY_SNAPSHOT), "old snapshot")
	cli.write_text(cli.join(f.folder, cli.REPLAY_EXPECTED), "old expectation")
	return f
}

// The folder holds the old recording again, byte for byte, with no coop.args it never had, and no backups are left.
@(private = "file")
expect_old :: proc(t: ^testing.T, f: Fixture, loc := #caller_location) {
	inputs, _ := cli.read_text(cli.join(f.folder, cli.REPLAY_INPUTS))
	snapshot, _ := cli.read_text(cli.join(f.folder, cli.REPLAY_SNAPSHOT))
	expected, _ := cli.read_text(cli.join(f.folder, cli.REPLAY_EXPECTED))
	testing.expect_value(t, inputs, "old inputs", loc = loc)
	testing.expect_value(t, snapshot, "old snapshot", loc = loc)
	testing.expect_value(t, expected, "old expectation", loc = loc)
	testing.expect(t, !os.exists(cli.join(f.folder, cli.REPLAY_ARGS_FILE)), "no coop.args it never had", loc = loc)
	testing.expect(t, !os.exists(f.backups), "no backups left", loc = loc)
}

// A recording replaces a folder's: its inputs and snapshot in, expected.unie gone, coop.args holding the options a
// line each; restored, the folder holds its old bytes again, and a second restore does nothing.
@(test)
a_recording_replaces_a_replay_and_restores :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	f := fixture(t)
	defer os.remove_all(f.root)
	args := []string{"--lan", "--host-profile", "class=Knight", "--", "--play=lan_pair"}
	backup, problem := cli.replay_install(f.folder, f.recording, args, f.backups)
	testing.expect_value(t, problem, "")
	inputs, _ := cli.read_text(cli.join(f.folder, cli.REPLAY_INPUTS))
	snapshot, _ := cli.read_text(cli.join(f.folder, cli.REPLAY_SNAPSHOT))
	testing.expect_value(t, inputs, "new inputs")
	testing.expect_value(t, snapshot, "new snapshot")
	testing.expect(t, !os.exists(cli.join(f.folder, cli.REPLAY_EXPECTED)), "the stale expectation goes")
	testing.expect(t, !os.exists(cli.join(f.folder, "session.json")), "only the replay's files come")
	saved, found := cli.replay_args(f.folder)
	testing.expect(t, found, "coop.args is written")
	testing.expect_value(t, len(saved), len(args))
	for arg, i in args do if i < len(saved) do testing.expect_value(t, saved[i], arg)
	testing.expect(t, cli.replay_restore(backup), "it puts the folder back")
	expect_old(t, f)
	testing.expect(t, !cli.replay_restore(backup), "a second restore has nothing to do")
}

// A check that refuses the new recording, or passes without writing its expectation (nothing checked it), leaves
// the folder as it was; one that writes it keeps the recording and drops the backups.
@(test)
a_refused_recording_puts_the_folder_back :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer os.remove_all(f.root)
	refuse :: proc(game, folder: string) -> cli.Result {return {ok = false, summary = "the play missed a step"}}
	refused := cli.replay_record("game", f.folder, f.recording, {"--lan"}, f.backups, refuse)
	testing.expect(t, !refused.ok, "a refused check fails the record")
	expect_old(t, f)

	unchecked :: proc(game, folder: string) -> cli.Result {return {ok = true}}
	nothing := cli.replay_record("game", f.folder, f.recording, {"--lan"}, f.backups, unchecked)
	testing.expect(t, !nothing.ok, "a check that wrote no expectation checked nothing")
	expect_old(t, f)

	bless :: proc(game, folder: string) -> cli.Result {
		cli.write_text(cli.join(folder, cli.REPLAY_EXPECTED), "new expectation")
		return {ok = true}
	}
	kept := cli.replay_record("game", f.folder, f.recording, {"--lan"}, f.backups, bless)
	testing.expect(t, kept.ok, kept.summary)
	inputs, _ := cli.read_text(cli.join(f.folder, cli.REPLAY_INPUTS))
	testing.expect_value(t, inputs, "new inputs")
	testing.expect(t, !os.exists(f.backups), "kept: the backups go")
}

// A run killed between install and the check's end leaves its backups: the next run puts the folder back first
// (replay_restore_killed names it), and a fresh install does too before taking its own backup.
@(test)
a_killed_record_is_put_back_by_the_next :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer os.remove_all(f.root)
	_, problem := cli.replay_install(f.folder, f.recording, {"--lan"}, f.backups) // and then killed
	testing.expect_value(t, problem, "")
	put_back := cli.replay_restore_killed(cli.join(f.root, "game", ".out", cli.REPLAY_BACKUPS))
	testing.expect_value(t, len(put_back), 1)
	expect_old(t, f)

	_, _ = cli.replay_install(f.folder, f.recording, {"--lan"}, f.backups) // killed again
	backup, again := cli.replay_install(f.folder, f.recording, {"--lan"}, f.backups)
	testing.expect_value(t, again, "")
	cli.replay_restore(backup)
	expect_old(t, f) // the second install's backup is of the old folder, not of the killed run's change
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
	_, problem := cli.replay_install(folder, recording, {}, cli.join(root, "backups", "old"))
	testing.expect_value(t, problem, "")
	testing.expect(t, !os.exists(cli.join(folder, cli.REPLAY_SNAPSHOT)), "the old snapshot goes")

	fresh := cli.join(root, "replays", "fresh")
	backup, fresh_problem := cli.replay_install(fresh, recording, {"--lan"}, cli.join(root, "backups", "fresh"))
	testing.expect_value(t, fresh_problem, "")
	testing.expect(t, os.is_file(cli.join(fresh, cli.REPLAY_INPUTS)), "a missing folder is made")
	cli.replay_restore(backup)
	testing.expect(t, !os.exists(fresh), "restored, the folder it made is gone")

	_, refused := cli.replay_install(folder, cli.join(root, "nothing"), {}, cli.join(root, "backups", "none"))
	testing.expect(t, refused != "", "a folder without inputs.unil is no recording")
}

// coop.args round-trips: what a --record run wrote (coop_record_args) parses back (coop_saved_opts) to the same
// options; a game, --window or --record in it is refused.
@(test)
coop_args_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	commands := cli.public_commands()
	self := cli.state.command
	defer cli.state.command = self
	for &command in commands do if command.name == "coop" do cli.state.command = &command
	opts := cli.Coop_Opts {
		lan          = true,
		menus        = true,
		host_profile = "class=Knight",
		join_profile = "class=Mage",
	}
	append(&opts.overflow, "--play=lan_pair", "--lag", "40")
	saved := cli.coop_record_args(opts)
	again, problem := cli.coop_saved_opts(saved)
	testing.expect_value(t, problem, "")
	testing.expect(t, again.lan && again.menus && !again.rejoin && !again.crash && !again.window)
	testing.expect_value(t, again.host_profile, "class=Knight")
	testing.expect_value(t, again.join_profile, "class=Mage")
	testing.expect_value(t, len(again.overflow), 3)
	if len(again.overflow) == 3 do testing.expect_value(t, again.overflow[2], "40")
	for bad in ([][]string{{"--window"}, {"--record", "x"}, {"other_game"}}) {
		_, refused := cli.coop_saved_opts(bad)
		testing.expectf(t, refused != "", "%v is refused", bad)
	}
}

// --record and --rerecord take a folder's name: letters, digits, _ and -, never a path.
@(test)
a_replay_is_named_not_pathed :: proc(t: ^testing.T) {
	for good in ([]string{"lan_pair", "bug-7", "A1"}) do testing.expectf(t, cli.replay_name_ok(good), "%q is fine", good)
	for bad in ([]string{"", ".", "..", "../x", "a/b", "a\\b", "C:x", "a b", "é"}) {
		testing.expectf(t, !cli.replay_name_ok(bad), "%q is refused", bad)
	}
}
