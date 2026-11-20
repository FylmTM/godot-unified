// unified:navreport, the report `uni bake --report` prints (src/navreport/README.md), on levels Godot exported:
// tests/godot/levels/nav_island.tscn (a floor, a table whose top is an island of its own, a gate on the table, one far
// off the mesh and a lamp over the floor) and the yard tests/nav walks (tests/godot/levels/nav_yard.tscn).
package test_navreport

import "core:strings"
import "core:testing"

import "unified:navreport"

ISLAND :: #load("../godot/levels/nav_island.level")
YARD :: #load("../godot/levels/nav_yard.level")
LEVEL_2D :: #load("../godot/levels/level_2d.level")

// The table's top is cut off from the floor: two islands, the floor's the largest; the gate on the table is on the
// table's island, the spawn and the goal on the floor's, and the far gate on none.
@(test)
an_island_and_an_unreachable_marker_show :: proc(t: ^testing.T) {
	report := navreport.report("nav_island.level", ISLAND, context.temp_allocator)
	testing.expect_value(t, report.error, "")
	testing.expect_value(t, report.scene, "res://levels/nav_island.tscn")
	testing.expect_value(t, report.polygons, 3)
	testing.expect_value(t, report.agent.radius, 0.5)
	if !testing.expect_value(t, len(report.islands), 2) do return
	testing.expect_value(t, report.islands[0].polygons, 2)
	testing.expect_value(t, report.islands[1].polygons, 1)
	testing.expect_value(t, report.islands[1].lo, [3]f32{4.5, 3, 4.5}) // lowered onto the table's top
	testing.expect_value(t, report.islands[1].hi, [3]f32{7.5, 3, 7.5})
	Want :: struct {
		name:     string,
		island:   int,
		off_mesh: bool,
	}
	// in scene-tree order; the lamp hangs 3 m over the floor: its nearest polygon is the floor's, but it is off the
	// mesh (farther than the agent's radius and the margin)
	want := []Want {
		{"Spawn", 0, false},
		{"Goal", 0, false},
		{"TableGate", 1, false},
		{"FarGate", -1, true},
		{"Lamp", 0, true},
	}
	if !testing.expect_value(t, len(report.markers), len(want)) do return
	for marker, i in report.markers {
		testing.expect_value(t, marker.name, want[i].name)
		testing.expectf(t, marker.island == want[i].island, "%s is on island %d", marker.name, marker.island)
		testing.expectf(t, marker.off_mesh == want[i].off_mesh, "%s off the mesh: %v", marker.name, marker.off_mesh)
	}
	testing.expect(t, abs(report.markers[4].distance - 3) < 1e-4, "the lamp is 3 m over the floor")
	cut_off, off_largest, off_mesh := navreport.findings(report)
	testing.expect_value(t, cut_off, 1)
	testing.expect_value(t, off_largest, 1)
	testing.expect_value(t, off_mesh, 2)
	report.export = navreport.Export{0.25, 0}
	builder := strings.builder_make(context.temp_allocator)
	navreport.write_text(&builder, report)
	text := strings.to_string(builder)
	for line in ([]string {
			"1 island(s) cut off from the largest; 1 marker(s) on a cut-off island; 2 marker(s) off the mesh",
			`cut off; markers: gate "TableGate"`,
			"on island #1  CUT OFF from #0",
			"OFF THE MESH: no polygon within 5 m",
			"OFF THE MESH: 3.00 m from it, nearest island #0",
			"export: vertices lowered onto the floor by up to 0.25 m; 0 polygon(s) inside solids left out",
		}) {
		testing.expectf(t, strings.contains(text, line), "the text says %q:\n%s", line, text)
	}
}

// A baked yard: every polygon on exactly one island, the largest first, and the bounds hold each island's polygons.
@(test)
yard_islands_cover_its_mesh :: proc(t: ^testing.T) {
	report := navreport.report("nav_yard.level", YARD, context.temp_allocator)
	testing.expect_value(t, report.error, "")
	if !testing.expect(t, len(report.islands) > 0, "the yard has islands") do return
	total := 0
	for island, i in report.islands {
		total += island.polygons
		if i > 0 do testing.expect(t, island.polygons <= report.islands[i - 1].polygons, "the largest first")
		for axis in 0 ..< 3 do testing.expect(t, island.lo[axis] <= island.hi[axis], "bounds in order")
	}
	testing.expect_value(t, total, report.polygons)
	testing.expect(t, report.islands[0].polygons > report.polygons / 2, "the yard's floor is most of it")
}

// A level without navigation (a 2D one) is a report of no polygons; bytes that are no level are an error.
@(test)
no_mesh_and_no_level_are_reported :: proc(t: ^testing.T) {
	flat := navreport.report("level_2d.level", LEVEL_2D, context.temp_allocator)
	testing.expect_value(t, flat.error, "")
	testing.expect_value(t, flat.polygons, 0)
	testing.expect_value(t, len(flat.islands), 0)
	junk := navreport.report("junk.level", transmute([]u8)string("not a level"), context.temp_allocator)
	testing.expect(t, junk.error != "", "junk is an error")
}
