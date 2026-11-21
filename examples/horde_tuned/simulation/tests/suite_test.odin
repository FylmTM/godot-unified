// horde_tuned's check: its extension installs (the sim is examples/horde's, whose suite proves and lints it).
package test_horde_tuned

import "core:testing"
import "unified:godot"

import g "../../../horde/simulation/horde"
import ext "../extension"

// The extension installs: what Godot would report when it loads it, here in a second.
@(test)
the_extension_installs :: proc(t: ^testing.T) {
	for problem in godot.install_problems(&g.GAME, ext.GLUE) do testing.expect(t, false, problem)
}
