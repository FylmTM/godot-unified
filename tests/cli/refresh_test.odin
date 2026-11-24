package test_cli

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
	for named in ([]string{"GUIDE.md", "unified_index.tres", "addons/unified", ".gitignore", "export_presets.cfg", "uni:", "uni.cmd:", "simulation/game/state.odin"}) {
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
	testing.expect_value(t, presets, "exclude_filter=\"game/tools/*, unified/*\"\n")
	state, _ := cli.read_text(cli.join(root, "simulation", "game", "state.odin"))
	testing.expect_value(t, state, "// desyncs after a rollback (unified/docs/gameplay.md).\n")
	shim, _ := cli.read_text(cli.join(root, "uni"))
	testing.expect(t, strings.contains(shim, "unified/uni"), "the shim runs the submodule's")
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
