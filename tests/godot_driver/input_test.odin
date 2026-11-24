// unified:godot's input arithmetic that needs no Godot: the radial deadzone a local player's own pad gets
// (action_vector on a device of its own), which must keep a stick's direction as Input.get_vector does.
package test_godot_driver

import "core:testing"
import "unified:godot"

// Inside the deadzone the stick reads zero; past it the length is rescaled from the deadzone's edge, the direction
// kept exactly (no snapping onto an axis), and full tilt clamps to length 1.
@(test)
radial_deadzone_keeps_the_direction :: proc(t: ^testing.T) {
	testing.expect_value(t, godot.radial_deadzone({0.1, 0.1}, 0.2), [2]f32{})
	slanted := godot.radial_deadzone({0.94, 0.342}, 0.2) // full tilt 20 degrees off the x axis
	testing.expectf(t, abs(slanted.y / slanted.x - 0.342 / 0.94) < 1e-5, "the direction is kept: %v", slanted)
	testing.expectf(
		t,
		abs(slanted.x * slanted.x + slanted.y * slanted.y - 1) < 1e-4,
		"full tilt is length 1: %v",
		slanted,
	)
	half := godot.radial_deadzone({0.6, 0}, 0.2)
	testing.expectf(t, abs(half.x - 0.5) < 1e-6 && half.y == 0, "rescaled from the deadzone's edge: %v", half)
	corner := godot.radial_deadzone({1, 1}, 0.2)
	testing.expectf(t, abs(corner.x * corner.x + corner.y * corner.y - 1) < 1e-4, "a corner clamps to 1: %v", corner)
}
