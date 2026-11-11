// This repo's CLI (src/cli/SPEC.md): the public commands of unified:cli plus unified's private ones, which no game
// needs (yet). Run it through the shims, ./unified or unified.cmd.
package main

import "unified:cli"

main :: proc() {
	cli.run(cli.public_commands(), private_commands())
}

private_commands :: proc() -> []cli.Command {
	return {}
}
