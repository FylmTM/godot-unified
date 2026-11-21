package test_cli

import "core:os"
import "core:testing"
import "unified:cli"

// A feedback directory as a dev build leaves it: a bug note with its recording, a second note within the same
// second, an older note, a freeze, and a folder that is no note.
@(private = "file")
feedback_fixture :: proc(feedback: string) {
	files := [][2]string {
		{"20261121-011449/note.txt", "[bug]\r\nFPS on this scene is horrible.\r\nwhy?"},
		{
			"20261121-011449/note.json",
			`{"game": "g", "version": "0.1.0", "bug": true, "tick": 1234, "recording": true}`,
		},
		{"20261121-011449/screenshot.png", ""},
		{"20261121-011449/snapshot.unis", ""},
		{"20261121-011449/inputs.unil", ""},
		{"20261121-011449-2/note.txt", "[note]\njump feels floaty"},
		{"20261120-090000/note.txt", "[note]\nolder"},
		{"freeze-20261121-020000/freeze.json", `{"tick": 55, "in_fill": true, "zones": ["steer", "combat"]}`},
		{"freeze-20261121-020000/inputs.unil", ""},
		{"stray/readme.txt", "not a note"},
	}
	for file in files {
		cli.write_text(cli.join(feedback, file[0]), file[1])
	}
}

@(test)
feedback_lists_reads_and_marks_notes_done :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	feedback, temp_err := os.make_directory_temp("", "unified-feedback-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(feedback)
	feedback_fixture(feedback)

	notes := cli.feedback_list(feedback)
	names := make([]string, len(notes))
	for note, i in notes do names[i] = note.name
	testing.expect_value(t, len(names), 4)
	if len(names) == 4 {
		// newest first by local time, a freeze among the notes, the stray folder skipped
		want := []string{"freeze-20261121-020000", "20261121-011449-2", "20261121-011449", "20261120-090000"}
		for name, i in want do testing.expect_value(t, names[i], name)
	}

	bug, ok := cli.feedback_read(cli.join(feedback, "20261121-011449"))
	testing.expect(t, ok)
	testing.expect_value(t, bug.kind, "bug")
	testing.expect_value(t, bug.text, "FPS on this scene is horrible.\nwhy?")
	testing.expect_value(t, bug.tick, 1234)
	testing.expect_value(t, bug.version, "0.1.0")
	testing.expect(t, bug.recording && bug.screenshot != "")
	note, _ := cli.feedback_read(cli.join(feedback, "20261121-011449-2"))
	testing.expect_value(t, note.kind, "note")
	testing.expect_value(t, note.text, "jump feels floaty")
	testing.expect(t, !note.recording && note.screenshot == "")
	freeze, _ := cli.feedback_read(cli.join(feedback, "freeze-20261121-020000"))
	testing.expect_value(t, freeze.kind, "freeze")
	testing.expect_value(t, freeze.text, "frozen in fill_frame: steer > combat")
	testing.expect_value(t, freeze.tick, 55)
	_, ok = cli.feedback_read(cli.join(feedback, "stray"))
	testing.expect(t, !ok, "a folder with no note's files is no note")

	// every name is checked before anything moves
	_, problem := cli.feedback_mark_done(feedback, {"20261120-090000", "nope"})
	testing.expect(t, problem != "")
	testing.expect(t, os.is_directory(cli.join(feedback, "20261120-090000")), "nothing moved")
	for bad in ([]string{"done", "../x", "stray"}) {
		_, problem = cli.feedback_mark_done(feedback, {bad})
		testing.expect(t, problem != "", bad)
	}

	moved, problem2 := cli.feedback_mark_done(feedback, {"20261120-090000", "freeze-20261121-020000"})
	testing.expect_value(t, problem2, "")
	testing.expect_value(t, len(moved), 2)
	testing.expect_value(t, len(cli.feedback_list(feedback)), 2)
	done := cli.join(feedback, cli.FEEDBACK_DONE_DIR)
	testing.expect_value(t, len(cli.feedback_list(done)), 2)
	testing.expect(t, os.is_file(cli.join(done, "freeze-20261121-020000", "inputs.unil")), "moved whole")
	_, problem = cli.feedback_mark_done(feedback, {"20261120-090000"})
	testing.expect(t, problem != "", "a handled note is not handled again")

	// a name already in done/ (a note sent again within the second, after the first was handled) gets a suffix
	cli.write_text(cli.join(feedback, "20261120-090000", "note.txt"), "[note]\nagain")
	moved, problem = cli.feedback_mark_done(feedback, {"20261120-090000"})
	testing.expect_value(t, problem, "")
	testing.expect(t, os.is_directory(cli.join(done, "20261120-090000-2")))
}

@(test)
game_user_dir_follows_godot :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	game, temp_err := os.make_directory_temp("", "unified-userdir-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(game)
	project := cli.join(game, "project.godot")
	base := cli.join(game, "base")
	godot := cli.godot_user_dir(base)

	cli.write_text(project, "[application]\nconfig/name=\"My: Game?\"\n")
	testing.expect_value(t, cli.game_user_dir(game, base), cli.join(godot, "app_userdata", "My- Game-"))
	cli.write_text(project, "[application]\nconfig/name=\"My Game\"\nconfig/use_custom_user_dir=true\n")
	testing.expect_value(t, cli.game_user_dir(game, base), cli.join(base, "My Game"))
	cli.write_text(
		project,
		"[application]\nconfig/name=\"My Game\"\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name=\"studio/my_game\"\n",
	)
	testing.expect_value(t, cli.game_user_dir(game, base), cli.join(base, "studio/my_game"))
	cli.write_text(project, "[application]\n")
	testing.expect_value(t, cli.game_user_dir(game, base), cli.join(godot, "app_userdata", "[unnamed project]"))
}
