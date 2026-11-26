package test_cli

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "unified:cli"

// A game repo an older unified made: its copied guide, view index, tool mirror (with its .gitignore line and export
// filter) and full shims. refresh_problems names each; write_refresh deletes unified's copies, retargets the filter,
// keeps the game's own lines and files, and leaves nothing to report.
@(test)
refresh_retires_what_an_older_unified_copied_in :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	root, temp_err := os.make_directory_temp("", "unified-refresh-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(root)
	cli.write_agents(UNIFIED_ROOT, root)
	cli.write_text(cli.join(root, "GUIDE.md"), "# Writing gameplay that survives rollback\n\nold copy\n")
	cli.write_text(
		cli.join(root, "unified_index.tres"),
		"[gd_resource type=\"Resource\" format=3]\n\n[resource]\nmetadata/views = {\n}\n",
	)
	cli.write_text(cli.join(root, "addons", "unified", "tool.gd"), "class_name UnifiedTool\n")
	cli.write_text(cli.join(root, "addons", "unified", cli.MIRROR_STAMP), "")
	cli.write_text(cli.join(root, "addons", "steam", "steam.gdextension"), "[configuration]\n")
	cli.write_text(
		cli.join(root, ".gitignore"),
		".out/\n# unified's tool scripts (unified/src/godot/tools), mirrored by uni before every Godot run.\naddons/unified/\n.env\n",
	)
	cli.write_text(cli.join(root, "export_presets.cfg"), "exclude_filter=\"game/tools/*, addons/unified/*\"\n")
	cli.write_text(cli.join(root, "simulation", "game", "state.odin"), "// desyncs after a rollback (GUIDE.md).\n")
	cli.write_text(cli.join(root, "uni"), "#!/bin/sh\n# the full bootstrap an older init copied\n")
	cli.write_text(cli.join(root, "uni.cmd"), "@echo off\r\nrem the full bootstrap\r\n")

	problems := strings.join(cli.refresh_problems(UNIFIED_ROOT, root), "\n")
	for named in ([]string{"GUIDE.md", "unified_index.tres", "addons/unified", ".gitignore", "export_presets.cfg", "uni:", "uni.cmd:"}) {
		testing.expectf(t, strings.contains(problems, named), "refresh_problems names %s:\n%s", named, problems)
	}

	cli.write_refresh(UNIFIED_ROOT, root)
	testing.expect_value(t, len(cli.refresh_problems(UNIFIED_ROOT, root)), 0)
	testing.expect(t, !os.exists(cli.join(root, "GUIDE.md")) && !os.exists(cli.join(root, "unified_index.tres")))
	testing.expect(t, !os.exists(cli.join(root, "addons", "unified")), "the old mirror goes")
	testing.expect(t, os.is_file(cli.join(root, "addons", "steam", "steam.gdextension")), "the game's own addon stays")
	ignore, _ := cli.read_text(cli.join(root, ".gitignore"))
	testing.expect_value(t, ignore, ".out/\n.env\n")
	presets, _ := cli.read_text(cli.join(root, "export_presets.cfg"))
	testing.expect_value(t, presets, "exclude_filter=\"game/tools/*, unified/tools_godot/*\"\n")
	state, _ := cli.read_text(cli.join(root, "simulation", "game", "state.odin"))
	testing.expect_value(t, state, "// desyncs after a rollback (GUIDE.md).\n") // the game's own: never touched
	shim, _ := cli.read_text(cli.join(root, "uni"))
	testing.expect(t, strings.contains(shim, "unified/uni"), "the shim runs the submodule's")
	testing.expect(t, !strings.contains(shim, "\r"), "the sh shim has LF line endings")
	cmd_shim, _ := cli.read_text(cli.join(root, "uni.cmd"))
	testing.expect(
		t,
		strings.contains(cmd_shim, "\r\n"),
		"the batch shim has CRLF line endings, as a checkout gives it",
	)
	testing.expect(t, !strings.contains(strings.trim_suffix(cmd_shim, "\r\n"), "\n\n"), "no doubled line ends")
}

// An export filter that leaves out the whole of unified/ (what refresh wrote before godot_runtime/ existed) is
// narrowed to its tool scripts, so the export ships what a running game loads; the game's own filters stay, and a
// filter already right is left alone.
@(test)
refresh_narrows_the_export_filter_to_the_tool_scripts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	before := "[preset.0]\nexclude_filter=\"game/tools/*, unified/*, secret/*\"\n[preset.1]\nexclude_filter=\"unified/*\"\n"
	after, changed := cli.retarget_export_filters(before)
	testing.expect(t, changed)
	testing.expect_value(
		t,
		after,
		"[preset.0]\nexclude_filter=\"game/tools/*, secret/*, unified/tools_godot/*\"\n[preset.1]\nexclude_filter=\"unified/tools_godot/*\"\n",
	)
	_, again := cli.retarget_export_filters(after)
	testing.expect(t, !again, "a narrowed filter is left alone")
}

// A repo's own files from init: a batch file as a checkout gives it (CRLF), every other file LF.
@(test)
init_writes_line_endings_as_a_checkout_gives_them :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	root, temp_err := os.make_directory_temp("", "unified-init-eol-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(root)
	cli.write_repo_files(cli.absolute_path(root, cli.join(UNIFIED_ROOT, cli.REPO_TEMPLATE)), root, "eolgame")
	cmd_shim, _ := cli.read_text(cli.join(root, "uni.cmd"))
	testing.expect(t, strings.count(cmd_shim, "\r\n") == strings.count(cmd_shim, "\n"), "uni.cmd: CRLF on every line")
	for name in ([]string{"uni", ".gitignore", ".gitattributes", "AGENTS.md"}) {
		text, found := cli.read_text(cli.join(root, name))
		testing.expectf(t, found && !strings.contains(text, "\r"), "%s: LF only", name)
	}
}

// A game's own GUIDE.md (not unified's copy) is the game's: refresh neither names nor deletes it.
@(test)
refresh_keeps_a_games_own_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	root, temp_err := os.make_directory_temp("", "unified-refresh-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(root)
	cli.write_refresh(UNIFIED_ROOT, root)
	cli.write_text(cli.join(root, "GUIDE.md"), "# Our style guide\n")
	testing.expect_value(t, len(cli.refresh_problems(UNIFIED_ROOT, root)), 0)
	cli.write_refresh(UNIFIED_ROOT, root)
	testing.expect(t, os.is_file(cli.join(root, "GUIDE.md")))
}

// The starters: write_refresh writes a missing one, from a template that parses, and keeps the game's own; they are
// never a problem. odinfmt.json is unified's: a missing or changed one is.
@(test)
refresh_writes_missing_starters_and_keeps_the_games :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	root, temp_err := os.make_directory_temp("", "unified-refresh-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(root)
	problems := strings.join(cli.refresh_problems(UNIFIED_ROOT, root), "\n")
	testing.expectf(
		t,
		strings.contains(problems, "odinfmt.json"),
		"refresh_problems names odinfmt.json:\n%s",
		problems,
	)
	cli.write_refresh(UNIFIED_ROOT, root)
	for starter in cli.STARTERS {
		text, found := cli.read_text(cli.join(root, starter.path))
		value, parse_err := json.parse_string(text)
		testing.expectf(t, found && parse_err == nil, "%s: written and valid JSON (%v)", starter.path, parse_err)
		json.destroy_value(value)
	}
	cli.write_text(cli.join(root, "ols.json"), "{\"the game's\": true}\n")
	cli.write_refresh(UNIFIED_ROOT, root)
	ols, _ := cli.read_text(cli.join(root, "ols.json"))
	testing.expect_value(t, ols, "{\"the game's\": true}\n")
	testing.expect_value(t, len(cli.refresh_problems(UNIFIED_ROOT, root)), 0)
	cli.write_text(cli.join(root, "odinfmt.json"), "{}\n")
	problems = strings.join(cli.refresh_problems(UNIFIED_ROOT, root), "\n")
	testing.expectf(t, strings.contains(problems, "odinfmt.json"), "a changed odinfmt.json is named:\n%s", problems)
}

// The game's settings.json starter runs the same format hook as unified's own: one command and timeout, kept in step
// (the first edit in a fresh checkout may build odinfmt).
@(test)
settings_starter_runs_unifieds_format_hook :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	Hook :: struct {
		command: string,
		timeout: int,
	}
	Settings :: struct {
		hooks: struct {
			PostToolUse: []struct {
				matcher: string,
				hooks:   []Hook,
			},
		},
	}
	hook :: proc(t: ^testing.T, path: string) -> Hook {
		settings: Settings
		text, found := cli.read_text(path)
		testing.expectf(t, found && json.unmarshal_string(text, &settings) == nil, "%s parses", path)
		if len(settings.hooks.PostToolUse) == 0 || len(settings.hooks.PostToolUse[0].hooks) == 0 do return {}
		return settings.hooks.PostToolUse[0].hooks[0]
	}
	starter := hook(t, cli.join(UNIFIED_ROOT, cli.STARTER_TEMPLATES, "settings.json"))
	testing.expect(t, strings.contains(starter.command, "fmt --hook"))
	testing.expect_value(t, starter, hook(t, cli.join(UNIFIED_ROOT, ".claude", "settings.json")))
}

// A `uni` shim committed without its executable bit (what a Windows checkout does): refresh_problems names it and
// write_refresh marks the mode executable in the index, leaving its staged content as it was. An untracked shim is no
// problem.
@(test)
refresh_marks_the_shim_executable_in_git :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	root, temp_err := os.make_directory_temp("", "unified-refresh-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(root)
	git :: proc(root: string, args: ..string) -> string {
		cmd := make([dynamic]string)
		append(&cmd, cli.git(), "-C", root)
		append(&cmd, ..args)
		return cli.run_proc({cmd = cmd[:], capture = true, quiet = true}).stdout
	}
	git(root, "init", "-q")
	cli.write_refresh(UNIFIED_ROOT, root)
	testing.expect_value(t, len(cli.refresh_problems(UNIFIED_ROOT, root)), 0)
	cli.write_text(cli.join(root, "uni"), "#!/bin/sh\n# an older shim\n")
	git(root, "add", "--chmod=-x", "--", "uni")
	staged := strings.fields(git(root, "ls-files", "--stage", "--", "uni"))
	problems := strings.join(cli.refresh_problems(UNIFIED_ROOT, root), "\n")
	testing.expectf(
		t,
		strings.contains(problems, "uni: not executable"),
		"refresh_problems names the mode:\n%s",
		problems,
	)
	cli.write_refresh(UNIFIED_ROOT, root)
	refreshed := strings.fields(git(root, "ls-files", "--stage", "--", "uni"))
	testing.expect(t, len(staged) >= 2 && len(refreshed) >= 2)
	testing.expect_value(t, refreshed[0], "100755")
	testing.expect_value(t, refreshed[1], staged[1]) // the mode alone: the staged content is the old shim's
	testing.expect(t, !strings.contains(strings.join(cli.refresh_problems(UNIFIED_ROOT, root), "\n"), "uni: not"))
}

// No example keeps a file refresh would retire from a game repo (an older unified's copy, such as GUIDE.md).
@(test)
no_example_keeps_a_retired_copy :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries, _ := os.read_all_directory_by_path(cli.join(UNIFIED_ROOT, "examples"), context.allocator)
	for entry in entries {
		if entry.type != .Directory do continue
		for problem in cli.retired_copies(entry.fullpath) do testing.expectf(t, false, "%s: %s", entry.name, problem)
	}
}
