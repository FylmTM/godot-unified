// src/level/README.md, Authoring: the exporter's 3D fixture (tests/godot/levels/shapes_3d.tscn, exported by `uni test
// --suite godot-bindings`) holds every 3D shape kind Godot can author, surfaces of the body's and of their own, and a
// Curve property; physics builds it where the scene drew it.
package test_level

import "core:testing"

import "unified:level"
import "unified:physics"

// tests/godot/levels/shapes_3d.tscn as exported.
FIXTURE_3D :: #load("../godot/levels/shapes_3d.level")

@(test)
fixture_3d_records :: proc(t: ^testing.T) {
	loaded, ok := level.load(FIXTURE_3D)
	defer level.destroy(&loaded)
	testing.expect(t, ok)
	if !ok do return
	testing.expect_value(t, loaded.scene, "res://levels/shapes_3d.tscn")
	testing.expect_value(t, level.scene_of(FIXTURE_3D), "res://levels/shapes_3d.tscn")
	testing.expect_value(t, len(loaded.bodies), 3) // Ground, Deck, Hill
	testing.expect_value(t, len(loaded.markers), 1)
	if len(loaded.bodies) != 3 || len(loaded.markers) != 1 do return

	ground := &loaded.bodies[0]
	testing.expect_value(t, ground.category, 2)
	surface := ground.surface
	testing.expectf(
		t,
		near_f32(surface.friction, 0.7) &&
		near_f32(surface.restitution, 0.1) &&
		near_f32(surface.rolling_resistance, 0.05) &&
		surface.material == 5,
		"%v",
		surface,
	)
	testing.expect_value(t, len(ground.shapes), 5) // Floor, Ball, Pill, Drum, Rock
	if len(ground.shapes) == 5 {
		floor, ball, pill, drum, rock :=
			ground.shapes[0], ground.shapes[1], ground.shapes[2], ground.shapes[3], ground.shapes[4]
		testing.expect(
			t,
			floor.kind == .Box && floor.surface == surface,
			"a shape without metadata has its body's surface",
		)
		testing.expect(
			t,
			ball.kind == .Sphere && ball.surface.material == 9,
			"the Ball's metadata: a surface of its own",
		)
		testing.expect(t, near_f32(ball.surface.friction, 0.7), "an own surface starts from its body's")
		testing.expect(t, pill.kind == .Capsule)
		testing.expect(t, drum.kind == .Hull && len(drum.points) == 32, "a cylinder is a hull of 2 x 16 points")
		if len(drum.points) == 32 {
			testing.expectf(
				t,
				near(drum.points[0], {0.5, 0, 3}) && near(drum.points[20], {0, 1, 3.5}),
				"%v",
				drum.points,
			)
		}
		testing.expect(t, rock.kind == .Hull && len(rock.points) == 5)
	}

	deck := &loaded.bodies[1]
	testing.expect(t, deck.pos == {10, 0, 0} && len(deck.shapes) == 1)
	if len(deck.shapes) == 1 {
		mesh := deck.shapes[0]
		testing.expect(
			t,
			mesh.kind == .Mesh && len(mesh.points) == 4 && len(mesh.triangles) == 2,
			"welded: 4 vertices",
		)
		testing.expect(t, mesh.surface.tangent_velocity == {1, 0, 0}, "the Mesh's metadata: a conveyor")
		testing.expect(t, mesh.pos == {} && mesh.rot == {0, 0, 0, 1}, "vertices are body-local")
		if len(mesh.triangles) == 2 {
			// counter-clockwise seen from above: (b - a) x (c - a) points up
			a, b, c :=
				mesh.points[mesh.triangles[0][0]], mesh.points[mesh.triangles[0][1]], mesh.points[mesh.triangles[0][2]]
			u, v := b - a, c - a
			testing.expectf(t, u.z * v.x - u.x * v.z > 0, "the first triangle faces down: %v %v %v", a, b, c)
		}
	}

	hill := &loaded.bodies[2]
	testing.expect(t, hill.pos == {-10, 0, 0} && len(hill.shapes) == 1)
	if len(hill.shapes) == 1 {
		field := hill.shapes[0]
		testing.expect(t, field.kind == .Height_Field && field.count_x == 3 && field.count_z == 3)
		testing.expectf(
			t,
			near(field.pos, {-2, 0, -2}) && near(field.scale, {2, 2, 2}),
			"%v %v",
			field.pos,
			field.scale,
		)
		testing.expect(t, len(field.heights) == 9 && field.heights[2] == 1 && field.heights[4] == 2)
	}

	spot := &loaded.markers[0]
	testing.expect(t, spot.kind == "spot" && len(spot.props) == 1)
	if len(spot.props) == 1 {
		curve, is_curve := spot.props[0].value.(level.Curve_Ref)
		testing.expect(t, spot.props[0].key == "falloff" && is_curve)
		if is_curve {
			// flat tangents at (0, 0) and (1, 1): Godot's cubic is the smoothstep 3x² - 2x³
			samples := loaded.curves[curve]
			for sample, i in samples {
				x := f32(i) / (level.CURVE_SAMPLES - 1)
				testing.expectf(t, near_f32(sample, x * x * (3 - 2 * x)), "sample %d: %v", i, sample)
			}
		}
	}
}

// The 3D fixture built as a level: the deck mesh collides from above, the cylinder is round, and the height
// field stands where Godot's physics puts the height map (tests/godot/test.gd probes the same points).
@(test)
level_bodies_3d :: proc(t: ^testing.T) {
	session := show(FIXTURE_3D)
	defer show_end(session)
	world := session.world.phys
	top :: proc(world: ^physics.World, x, z: f32) -> (y: f32, normal: [3]f32, material: u64) {
		hit, ok := physics.world_cast_ray_closest(world, {x, 10, z}, {0, -20, 0})
		if !ok do return -100, {}, 0
		return hit.point.y, hit.normal, hit.material
	}
	expect_top :: proc(t: ^testing.T, world: ^physics.World, x, z, want: f32, loc := #caller_location) {
		y, _, _ := top(world, x, z)
		testing.expectf(t, abs(y - want) < 2e-3, "at (%v, %v): %v, want %v", x, z, y, want, loc = loc)
	}
	y, normal, material := top(world, 10.5, 0.5)
	testing.expectf(t, abs(y - 1) < 1e-3 && normal.y > 0.99, "the deck: %v %v", y, normal)
	testing.expect_value(t, material, 6)
	_, _, material = top(world, 3, 0)
	testing.expect_value(t, material, 9)
	expect_top(t, world, 0, 3, 1) // the drum's top
	expect_top(t, world, 0.45, 3, 1) // inside its rim
	expect_top(t, world, -10, 0, 4) // the hill's centre: 2, scaled 2
	expect_top(t, world, -9, 0, 2) // half way down its grid lines
	expect_top(t, world, -10, 1, 2)
	expect_top(t, world, -9, -1, 3) // Box3D's diagonal of the cell under the raised corner (4 to 2)
}

near_f32 :: proc(a, b: f32, eps: f32 = 1e-4) -> bool {
	return abs(a - b) <= eps
}
