// This repo's CLI (src/cli/SPEC.md): the public commands of unified:cli plus unified's private ones, which no game
// needs (yet). Run it through the shims, ./unified or unified.cmd.
package main

import "unified:cli"

main :: proc() {
	cli.add_suites(..private_suites())
	cli.run(cli.public_commands(), private_commands())
}

private_commands :: proc() -> []cli.Command {
	return cli.box_commands(
		{
			name = "godot-gen",
			usage = "[--force]",
			summary = "the Godot bindings, src/gdext/*.gen.odin, from the committed API dump",
			budget = 3,
			run = cmd_godot_gen,
		},
		{
			name = "release",
			usage = "[game] [--tag <game>-v<version> | --version V] [--no-eos] [--no-smoke] | release notes [game] --tag T [--no-eos]",
			summary = "a playable build: export, version stamp, sign, zip, smoke test (macOS and Windows)",
			no_budget = "exports and downloads",
			run = cmd_release,
		},
		{
			name = "board",
			usage = "list [--status S] [--area A] | set <issue> [--status S] [--area A]",
			summary = "the work board through gh (set --status Done also closes the issue)",
			no_budget = "networked",
			run = cmd_board,
		},
		{
			name    = "ci",
			usage   = "summary | cache-key <dep>",
			summary = "the CI job summary (markdown); a dependency's cache key",
			budget  = 2, // a compiled dependency's key asks the C compiler its version (on Windows, through vcvars)
			run     = cmd_ci,
		},
		{
			name = "selftest",
			summary = "the bootstrap and init end to end, from a fresh clone (run before tooling PRs; never by verify)",
			no_budget = "clones and builds from scratch",
			run = cmd_selftest,
		},
	)
}
