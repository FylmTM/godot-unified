// This repo's CLI (src/cli/README.md): the public commands of unified:cli plus unified's private ones, which no game
// needs (yet), and what this repo adds to the conventions (its test root, the toy game, the Godot test projects).
// Run it through the shims, ./uni or uni.cmd; the binary rebuilds itself when a source changes. A command moves into
// src/cli when a game needs it. The files:
//
//	main.odin           this registration
//	suites.odin         the `net` suite (the toy's relay and 3 clients over real UDP) and the `godot-bindings` suite
//	                    (tests/godot, tests/godot_views, a script error under the debugger)
//	view_bench.odin     `view-bench`: the Godot host's view sync
//	physics_bench.odin  `bench`'s physics row
//	grid_bench.odin     `bench`'s grid row
//	release.odin        `release`: playable builds (the `release` skill), and `release notes`
//	board.odin          `board list|set`: the work board (GitHub Project 2) through gh (needs the `project` scope)
//	selftest.odin       `selftest`: a fresh clone bootstrapped by its shim, `init` end to end, the test watchdog
package main

import "core:slice"

import "unified:cli"

main :: proc() {
	cli.configure({
		tests      = "tests",
		headless   = {{name = "toy", pkg = "tests/toy/headless"}},
		vet        = {"tests/godot/ext", "tests/godot_views/ext"},
		fmt        = {"src", "tests"},
		uses_box3d = true,
		bench      = {{name = "physics", run = physics_bench}, {name = "grid", run = grid_bench}},
		bake       = {{dir = "tests/godot", scenes = {"res://levels/level_2d.tscn", "res://levels/shapes_3d.tscn"}}},
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
			summary   = "a playable build: export, version stamp, sign, zip, smoke test (macOS and Windows); `notes`: its release notes",
			no_budget = "exports and downloads",
			options   = cli.option_forms({"", Release_Opts}, {"notes", Release_Notes_Opts}),
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
