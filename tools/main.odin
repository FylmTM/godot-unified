// This repo's CLI (src/cli/README.md): the public commands of unified:cli plus unified's private ones, which no game
// needs (yet), and what this repo adds to the conventions (its test root, the toy game, the Godot test projects).
// Run it through the shims, ./uni or uni.cmd; the binary rebuilds itself when a source changes. A command moves into
// src/cli when a game needs it.
package main

import "core:slice"

import "unified:cli"

main :: proc() {
	cli.configure({
		tests             = "tests",
		unoptimized_tests = "tests/tooling",
		headless          = {{name = "toy", pkg = "tests/toy/headless"}},
		vet               = {"tests/godot/ext", "tests/godot_views/ext"},
		fmt               = {"src", "tests"},
		uses_box3d        = true,
		bench             = {
			{name = "physics", run = physics_bench},
			{name = "grid", run = grid_bench},
			{name = "wake", run = wake_bench},
		},
		bake              = {
			{dir = "tests/godot", scenes = {"res://levels/level_2d.tscn", "res://levels/shapes_3d.tscn"}},
			{dir = "tests/godot_views", scenes = {"res://levels/meadow.tscn", "res://levels/cave.tscn"}},
		},
	})
	cli.add_suites(..private_suites())
	cli.run(cli.public_commands(), private_commands())
}

private_commands :: proc() -> []cli.Command {
	return slice.clone([]cli.Command {
		{
			name    = "view-bench",
			summary = "the Godot host's main-thread view sync at 1k, 4k and 16k MultiMesh instances (headless; --window: the real renderer)",
			budget  = 15,
			options = cli.option_types(View_Bench_Opts),
			details = view_bench_details,
			run     = cmd_view_bench,
		},
		{
			name      = "release",
			summary   = "playable builds of every game (or one) for this host: export, version stamp, sign, zip, smoke test (macOS and Windows)",
			no_budget = "exports and downloads",
			options   = cli.option_types(Release_Opts),
			run       = cmd_release,
		},
		{
			name      = "board",
			summary   = "the work board through gh (set --status Done also closes the issue)",
			no_budget = "networked",
			options   = cli.option_forms({"list", Board_List_Opts}, {"set", Board_Set_Opts}),
			run       = cmd_board,
		},
		{
			name      = "selftest",
			summary   = "the bootstrap (the shims' Odin download), init end to end from a fresh clone, and the test watchdog (run before tooling PRs; never by verify)",
			no_budget = "clones and builds from scratch",
			options   = cli.option_types(Selftest_Opts),
			run       = cmd_selftest,
		},
	})
}
