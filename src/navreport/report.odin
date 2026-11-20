// A level's navigation, reported (src/navreport/README.md): its mesh's size and agent, its islands (the polygons
// joined by shared edges) with their bounds, and the island each marker sits on, so a level a walker can't cross shows
// before a game runs on it. Built on unified:level and unified:nav, as a game builds its mesh.
package navreport

import "core:fmt"
import "core:slice"
import "core:strings"

import "unified:dmath"
import "unified:level"
import "unified:nav"

// How far from a marker its island is looked for (nav.nearest), metres: a marker stands on the floor, a little above
// it (a spawn's centre) or a little off the mesh (Godot's bake shrinks it by the agent's radius from the walls).
MARKER_REACH :: f32(5)

// One level's navigation report (report).
Report :: struct {
	file:     string, // the .level file, as the caller named it
	scene:    string, // the scene it was exported from (level.scene_of; "": none)
	error:    string, // why there is no report ("": there is one): the file doesn't load, or nav.build refused it
	polygons: int, // 0: the level has no navigation mesh
	vertices: int,
	agent:    level.Nav_Agent,
	islands:  []Island, // the largest first (then by lowest polygon)
	markers:  []Marker_Place, // every marker, in the level's order
}

// An island of the mesh (nav.islands): polygons joined by shared edges. A walker on one never reaches another.
Island :: struct {
	polygons:      int,
	first_polygon: int, // its lowest polygon index
	lo, hi:        [3]f32, // its vertices' bounds, level space
}

// Where a marker is on the mesh: the island of its nearest polygon within MARKER_REACH.
Marker_Place :: struct {
	index:    int, // in the level's markers
	kind:     string,
	name:     string,
	pos:      [3]f32,
	island:   int, // in Report.islands (0: the largest); -1: no polygon within MARKER_REACH
	distance: f32, // from pos to the nearest point of the mesh (island -1: 0)
}

// The navigation report of a level file's bytes (`file` names it in the report). The report's strings and slices are
// made with `allocator`; a file that doesn't load or a mesh nav.build refuses is a report with its error set.
report :: proc(file: string, data: []u8, allocator := context.allocator) -> Report {
	context.allocator = allocator
	out := Report {
		file  = strings.clone(file),
		scene = strings.clone(level.scene_of(data)),
	}
	loaded, ok := level.load(data, context.temp_allocator)
	if !ok {
		out.error = "not a level file this unified reads (uni bake)"
		return out
	}
	out.polygons = len(loaded.nav_polygons)
	out.vertices = len(loaded.nav_vertices)
	out.agent = loaded.nav_agent
	if out.polygons == 0 do return out
	mesh, err := nav.build(loaded.nav_vertices, loaded.nav_polygons, allocator = context.temp_allocator)
	if err != .None {
		out.error = fmt.aprintf("nav.build refused the mesh: %v", err)
		return out
	}
	island_of, count := nav.islands(&mesh, context.temp_allocator)
	islands := make([]Island, count)
	for &island in islands do island.first_polygon = -1
	for p in 0 ..< out.polygons {
		island := &islands[island_of[p]]
		if island.first_polygon < 0 {
			island.first_polygon = p
			island.lo = mesh.vertices[mesh.corners[mesh.first[p]]]
			island.hi = island.lo
		}
		island.polygons += 1
		for k in mesh.first[p] ..< mesh.first[p + 1] {
			vertex := mesh.vertices[mesh.corners[k]]
			for axis in 0 ..< 3 {
				island.lo[axis] = min(island.lo[axis], vertex[axis])
				island.hi[axis] = max(island.hi[axis], vertex[axis])
			}
		}
	}
	// the largest first, then by lowest polygon: a stable sort of nav.islands' order, which is by lowest polygon
	out.islands = islands
	slice.stable_sort_by(out.islands, proc(a, b: Island) -> bool {return a.polygons > b.polygons})
	renumber := make([]int, count, context.temp_allocator)
	for island, i in out.islands do renumber[island_of[island.first_polygon]] = i
	out.markers = make([]Marker_Place, len(loaded.markers))
	for marker, i in loaded.markers {
		place := Marker_Place {
			index  = marker.index,
			kind   = strings.clone(marker.kind),
			name   = strings.clone(marker.name),
			pos    = marker.pos,
			island = -1,
		}
		poly, point := nav.nearest(&mesh, marker.pos, MARKER_REACH)
		if poly != nav.NO_POLY {
			place.island = renumber[island_of[poly]]
			place.distance = dmath.length3(point - marker.pos)
		}
		out.markers[i] = place
	}
	return out
}

// Writes a report as text for a reader: the mesh, its islands (every one but the largest flagged: a walker there
// reaches nothing else) and where each marker is (flagged when not on the largest island, or off the mesh).
write_text :: proc(builder: ^strings.Builder, report: Report) {
	name := report.scene != "" ? fmt.tprintf("%s (%s)", report.scene, report.file) : report.file
	fmt.sbprintf(builder, "%s\n", name)
	if report.error != "" {
		fmt.sbprintf(builder, "  %s\n", report.error)
		return
	}
	if report.polygons == 0 {
		fmt.sbprintf(builder, "  no navigation mesh\n")
		return
	}
	agent := report.agent
	fmt.sbprintf(
		builder,
		"  navigation: %d polygons, %d vertices; agent radius %.2f m, height %.2f m, max climb %.2f m\n",
		report.polygons,
		report.vertices,
		agent.radius,
		agent.height,
		agent.max_climb,
	)
	cut_off, off_largest, off_mesh := findings(report)
	fmt.sbprintf(builder, "  findings: ")
	if cut_off + off_largest + off_mesh == 0 {
		fmt.sbprintf(builder, "none: one island, every marker on it\n")
	} else {
		parts := make([dynamic]string, context.temp_allocator)
		if cut_off > 0 do append(&parts, fmt.tprintf("%d island(s) cut off from the largest", cut_off))
		if off_largest > 0 do append(&parts, fmt.tprintf("%d marker(s) not on the largest island", off_largest))
		if off_mesh > 0 do append(&parts, fmt.tprintf("%d marker(s) off the mesh", off_mesh))
		fmt.sbprintf(builder, "%s\n", strings.join(parts[:], "; ", context.temp_allocator))
	}
	fmt.sbprintf(builder, "  islands: %d\n", len(report.islands))
	for island, i in report.islands {
		fmt.sbprintf(
			builder,
			"    #%-3d %5d polygons  x %.2f..%.2f  y %.2f..%.2f  z %.2f..%.2f  %s",
			i,
			island.polygons,
			island.lo.x,
			island.hi.x,
			island.lo.y,
			island.hi.y,
			island.lo.z,
			island.hi.z,
			i == 0 ? "largest" : "cut off",
		)
		on := 0
		for marker in report.markers {
			if i == 0 || marker.island != i do continue // the largest island's: the markers' lines
			fmt.sbprintf(builder, "%s%s %q", on == 0 ? "; markers: " : ", ", marker.kind, marker.name)
			on += 1
		}
		fmt.sbprintf(builder, "\n")
	}
	if len(report.markers) == 0 {
		fmt.sbprintf(builder, "  markers: none\n")
		return
	}
	labels := make([]string, len(report.markers), context.temp_allocator)
	positions := make([]string, len(report.markers), context.temp_allocator)
	label_width, position_width := 0, 0
	for marker, i in report.markers {
		labels[i] = fmt.tprintf("%s %q", marker.kind, marker.name)
		positions[i] = fmt.tprintf("(%.2f, %.2f, %.2f)", marker.pos.x, marker.pos.y, marker.pos.z)
		label_width = max(label_width, len(labels[i]))
		position_width = max(position_width, len(positions[i]))
	}
	fmt.sbprintf(
		builder,
		"  markers: %d, each on the island of its nearest polygon within %.0f m\n",
		len(report.markers),
		MARKER_REACH,
	)
	for marker, i in report.markers {
		fmt.sbprintf(builder, "    %-*s  %-*s  ", label_width, labels[i], position_width, positions[i])
		switch {
		case marker.island < 0:
			fmt.sbprintf(builder, "OFF THE MESH: no polygon within %.0f m\n", MARKER_REACH)
		case marker.island == 0:
			fmt.sbprintf(builder, "island #0, %.2f m from it\n", marker.distance)
		case:
			fmt.sbprintf(
				builder,
				"island #%d, %.2f m from it  NOT ON THE LARGEST ISLAND: cut off from #0\n",
				marker.island,
				marker.distance,
			)
		}
	}
}

// What a report flags: the islands other than the largest, the markers on one of them, and the markers off the mesh.
findings :: proc(report: Report) -> (cut_off, off_largest, off_mesh: int) {
	cut_off = max(len(report.islands) - 1, 0)
	for marker in report.markers {
		if marker.island < 0 do off_mesh += 1
		else if marker.island > 0 do off_largest += 1
	}
	return
}
