// Navigation meshes (src/nav/README.md): a mesh built once from plain vertex and polygon slices (a level's baked
// navigation, Level.nav_vertices and nav_polygons, or a generated level's), with each polygon's neighbours across its
// edges, its centre and plane, and an XZ grid for finding the polygon under a point. Deterministic: f32 with
// + − × ÷ sqrt, fixed iteration orders, ties broken by index.
package nav

import "unified:dmath"

// A polygon of a Mesh, by index (NO_POLY: none). A walker keeps the one it stands on, so it never has to look itself
// up again (locate, nearest find it once).
Poly :: distinct i32

// No polygon: off the mesh, a wall's far side, or unreachable.
NO_POLY :: Poly(-1)

// A navigation mesh: convex polygons, counter-clockwise seen from above, joined where they share an edge. Built once
// (build) in a game's world_create and kept in its World, outside the block; it never changes.
Mesh :: struct {
	vertices:   [][3]f32,
	first:      []i32, // polygon p's corners are corners[first[p] ..< first[p + 1]]
	corners:    []i32, // vertex indices, counter-clockwise seen from above
	across:     []Poly, // per corner: the polygon across the edge from it to the next corner (NO_POLY: a wall)
	edge_len:   []f32, // per corner: that edge's length seen from above
	centers:    [][3]f32, // the average of each polygon's vertices
	normals:    [][3]f32, // each polygon's unit normal, pointing up
	// The grid over the mesh's XZ bounds: each cell's polygons (cell_polys[cell_first[c] ..< cell_first[c + 1]], by
	// index) are those whose XZ bounds touch it.
	origin:     [2]f32,
	cell:       f32,
	columns:    i32,
	rows:       i32,
	cell_first: []i32,
	cell_polys: []Poly,
}

// Why build refused its input.
Build_Error :: enum u8 {
	None,
	Small_Polygon, // fewer than 3 vertices
	Bad_Index, // an index past the vertices
	Flat_Polygon, // no area seen from above, or too steep to stand on (its normal under 0.1 up)
	Bad_Vertex, // a NaN or an infinity
	Crowded_Edge, // an edge shared by more than two polygons
	Bad_Cell, // a cell size not above 0, or a grid of more than 2^24 cells
}

// Builds a mesh from vertices and convex polygons (each a list of vertex indices, either winding): a polygon's
// neighbours are the polygons that share an edge's two vertices, its plane the one through its vertices (Newell's
// normal). Vertices at exactly the same position are one vertex (welded here: a level's mesh already shares indices,
// src/level/README.md, Authoring; a generated one need not). `cell`:
// the XZ grid's cell size in metres; a few times a polygon's size keeps locate's buckets short. Everything is copied
// into storage made with `allocator`, which destroy frees with the same allocator.
build :: proc(
	vertices: [][3]f32,
	polygons: [][]u32,
	cell: f32 = 2,
	allocator := context.allocator,
) -> (
	mesh: Mesh,
	err: Build_Error,
) {
	context.allocator = allocator
	for vertex in vertices {
		for value in vertex do if !(abs(value) < 1e30) do return {}, .Bad_Vertex
	}
	if !(cell > 0) do return {}, .Bad_Cell
	corner_count := 0
	for polygon in polygons {
		if len(polygon) < 3 do return {}, .Small_Polygon
		for index in polygon do if int(index) >= len(vertices) do return {}, .Bad_Index
		corner_count += len(polygon)
	}
	mesh.cell = cell
	mesh.vertices = make([][3]f32, len(vertices))
	copy(mesh.vertices, vertices)
	welded := weld(vertices)
	mesh.first = make([]i32, len(polygons) + 1)
	mesh.corners = make([]i32, corner_count)
	mesh.across = make([]Poly, corner_count)
	mesh.edge_len = make([]f32, corner_count)
	mesh.centers = make([][3]f32, len(polygons))
	mesh.normals = make([][3]f32, len(polygons))
	at := 0
	for polygon, p in polygons {
		mesh.first[p] = i32(at)
		// twice the signed area seen from above: positive counter-clockwise
		area: f32 = 0
		for k in 1 ..< len(polygon) - 1 {
			area += area2(vertices[polygon[0]], vertices[polygon[k]], vertices[polygon[k + 1]])
		}
		for k in 0 ..< len(polygon) {
			mesh.corners[at + k] = welded[polygon[k] if area > 0 else polygon[len(polygon) - 1 - k]]
		}
		center, newell: [3]f32
		for k in 0 ..< len(polygon) {
			a := mesh.vertices[mesh.corners[at + k]]
			b := mesh.vertices[mesh.corners[at + (k + 1) % len(polygon)]]
			center += a
			newell += {(a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)}
			mesh.edge_len[at + k] = dmath.length2(b.xz - a.xz)
		}
		mesh.centers[p] = center / f32(len(polygon))
		mesh.normals[p] = dmath.normalize3(newell, 0)
		if !(abs(area) > 1e-8) || !(mesh.normals[p].y > 0.1) {
			destroy(&mesh, allocator)
			return {}, .Flat_Polygon
		}
		at += len(polygon)
	}
	mesh.first[len(polygons)] = i32(at)
	if !link_edges(&mesh) {
		destroy(&mesh, allocator)
		return {}, .Crowded_Edge
	}
	if !build_grid(&mesh) {
		destroy(&mesh, allocator)
		return {}, .Bad_Cell
	}
	return mesh, .None
}

// Frees what build made (with the allocator it was given) and zeroes the mesh.
destroy :: proc(mesh: ^Mesh, allocator := context.allocator) {
	context.allocator = allocator
	delete(mesh.vertices)
	delete(mesh.first)
	delete(mesh.corners)
	delete(mesh.across)
	delete(mesh.edge_len)
	delete(mesh.centers)
	delete(mesh.normals)
	delete(mesh.cell_first)
	delete(mesh.cell_polys)
	mesh^ = {}
}

// The number of polygons.
poly_count :: #force_inline proc "contextless" (mesh: ^Mesh) -> int {
	return len(mesh.first) - 1
}

// The polygon under `pos` seen from above whose surface is within `max_dy` of its height, the nearest in height (then
// the lowest index); NO_POLY when none is. On stacked floors (a deck over a yard) the height picks the floor.
locate :: proc(mesh: ^Mesh, pos: [3]f32, max_dy: f32) -> Poly {
	if poly_count(mesh) == 0 do return NO_POLY
	cell := cell_of(mesh, pos.xz)
	best := NO_POLY
	best_dy := max_dy
	for polygon in mesh.cell_polys[mesh.cell_first[cell]:mesh.cell_first[cell + 1]] {
		if !contains(mesh, polygon, pos) do continue
		dy := abs(height_at(mesh, polygon, pos) - pos.y)
		if dy < best_dy || (dy == best_dy && best == NO_POLY) || (dy == best_dy && polygon < best) {
			best, best_dy = polygon, dy
		}
	}
	return best
}

// The point of the mesh nearest to `pos` within `max_distance` (in 3D, the point on a polygon's surface: its XZ
// closest point at its plane's height), and its polygon; NO_POLY when none is that close. For what may stand just off
// the mesh (a player by a wall, a spawn marker): the mesh is shrunk by the bake's agent radius.
nearest :: proc(mesh: ^Mesh, pos: [3]f32, max_distance: f32) -> (poly: Poly, point: [3]f32) {
	poly = NO_POLY
	if poly_count(mesh) == 0 || !(max_distance >= 0) do return
	best := max_distance * max_distance
	lo := cell_xy(mesh, pos.xz - max_distance)
	hi := cell_xy(mesh, pos.xz + max_distance)
	for row in lo.y ..= hi.y {
		for column in lo.x ..= hi.x {
			cell := row * mesh.columns + column
			for polygon in mesh.cell_polys[mesh.cell_first[cell]:mesh.cell_first[cell + 1]] {
				xz := closest_xz(mesh, polygon, pos.xz)
				on := [3]f32{xz.x, height_at(mesh, polygon, {xz.x, 0, xz.y}), xz.y}
				distance := dmath.dist_sq3(on, pos)
				if distance < best || (distance == best && poly == NO_POLY) || (distance == best && polygon < poly) {
					poly, point, best = polygon, on, distance
				}
			}
		}
	}
	return
}

// The height of a polygon's plane at pos's x and z.
height_at :: proc(mesh: ^Mesh, poly: Poly, pos: [3]f32) -> f32 {
	center, normal := mesh.centers[poly], mesh.normals[poly]
	return center.y - (normal.x * (pos.x - center.x) + normal.z * (pos.z - center.z)) / normal.y
}

// Whether pos is inside a polygon seen from above (a millimetre's margin: a point on an edge is in both polygons).
contains :: proc(mesh: ^Mesh, poly: Poly, pos: [3]f32) -> bool {
	first, last := mesh.first[poly], mesh.first[poly + 1]
	for k in first ..< last {
		if edge_side(mesh, poly, k, pos) < -0.001 * mesh.edge_len[k] do return false
	}
	return true
}

// Which side of corner k's edge `pos` is on, seen from above: positive inside `poly`, its magnitude the distance times
// the edge's length. Computed from the edge's ends in vertex index order and negated for the polygon that has them the
// other way, so the two polygons of a shared edge get exact opposites and a point is never beyond it from both.
edge_side :: proc(mesh: ^Mesh, poly: Poly, k: i32, pos: [3]f32) -> f32 {
	next := k + 1 if k + 1 < mesh.first[poly + 1] else mesh.first[poly]
	a, b := mesh.corners[k], mesh.corners[next]
	if a < b do return area2(mesh.vertices[a], mesh.vertices[b], pos)
	return 0 - area2(mesh.vertices[b], mesh.vertices[a], pos)
}

// The two ends of corner k's edge (k an index into corners, in polygon `poly`): the corner's vertex and the next one.
corner_edge :: #force_inline proc(mesh: ^Mesh, poly: Poly, k: i32) -> (a, b: [3]f32) {
	next := k + 1 if k + 1 < mesh.first[poly + 1] else mesh.first[poly]
	return mesh.vertices[mesh.corners[k]], mesh.vertices[mesh.corners[next]]
}

// Twice the signed area of the triangle a, b, c seen from above (x and z): positive when they turn counter-clockwise,
// so c is left of a → b (inside a counter-clockwise polygon whose edge a → b is).
area2 :: #force_inline proc "contextless" (a, b, c: [3]f32) -> f32 {
	return (b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z)
}

// Each vertex's index, or the lowest index of a vertex at exactly its position: the indices sorted by position (a
// bottom-up merge sort, no hashing), each run of equal positions given its first index.
@(private)
weld :: proc(vertices: [][3]f32) -> []i32 {
	count := len(vertices)
	welded := make([]i32, count, context.temp_allocator)
	order := make([]i32, count, context.temp_allocator)
	scratch := make([]i32, count, context.temp_allocator)
	for i in 0 ..< count do order[i] = i32(i)
	before :: proc(vertices: [][3]f32, a, b: i32) -> bool {
		p, q := vertices[a], vertices[b]
		if p.x != q.x do return p.x < q.x
		if p.y != q.y do return p.y < q.y
		if p.z != q.z do return p.z < q.z
		return a < b
	}
	from, to := order, scratch
	for width := 1; width < count; width *= 2 {
		for start := 0; start < count; start += 2 * width {
			middle, end := dmath.min(start + width, count), dmath.min(start + 2 * width, count)
			i, j, out := start, middle, start
			for out < end {
				if j >= end || (i < middle && !before(vertices, from[j], from[i])) {
					to[out] = from[i]
					i += 1
				} else {
					to[out] = from[j]
					j += 1
				}
				out += 1
			}
		}
		from, to = to, from
	}
	for i in 0 ..< count {
		index := from[i]
		same := i > 0 && vertices[from[i - 1]] == vertices[index]
		welded[index] = welded[from[i - 1]] if same else index
	}
	return welded
}

// Pairs every edge with the polygon across it, by its two vertex indices: corners bucketed by their edge's lower index
// (a counting sort, no hashing), a bucket's corners matched by the higher one. False: an edge in more than two
// polygons.
@(private)
link_edges :: proc(mesh: ^Mesh) -> bool {
	vertex_count := len(mesh.vertices)
	start := make([]i32, vertex_count + 1, context.temp_allocator)
	order := make([]i32, len(mesh.corners), context.temp_allocator)
	poly_of := make([]Poly, len(mesh.corners), context.temp_allocator)
	for p in 0 ..< poly_count(mesh) {
		for k in mesh.first[p] ..< mesh.first[p + 1] {
			poly_of[k] = Poly(p)
			lo, _ := edge_key(mesh, Poly(p), k)
			start[lo + 1] += 1
		}
	}
	for v in 0 ..< vertex_count do start[v + 1] += start[v]
	fill := make([]i32, vertex_count, context.temp_allocator)
	for k in 0 ..< i32(len(mesh.corners)) {
		lo, _ := edge_key(mesh, poly_of[k], k)
		order[start[lo] + fill[lo]] = k
		fill[lo] += 1
	}
	for &across in mesh.across do across = NO_POLY
	for v in 0 ..< vertex_count {
		bucket := order[start[v]:start[v + 1]]
		for k, i in bucket {
			_, hi := edge_key(mesh, poly_of[k], k)
			for other in bucket[i + 1:] {
				_, other_hi := edge_key(mesh, poly_of[other], other)
				if other_hi != hi do continue
				if mesh.across[k] != NO_POLY || mesh.across[other] != NO_POLY do return false
				mesh.across[k], mesh.across[other] = poly_of[other], poly_of[k]
			}
		}
	}
	return true
}

// A corner's edge as its two vertex indices, lower first.
@(private)
edge_key :: proc(mesh: ^Mesh, poly: Poly, k: i32) -> (lo, hi: i32) {
	next := k + 1 if k + 1 < mesh.first[poly + 1] else mesh.first[poly]
	a, b := mesh.corners[k], mesh.corners[next]
	return (a if a < b else b), (b if a < b else a)
}

// The XZ grid: each polygon in every cell its XZ bounds touch, in index order (a counting sort in two passes).
@(private)
build_grid :: proc(mesh: ^Mesh) -> bool {
	if len(mesh.vertices) == 0 {
		mesh.columns, mesh.rows = 1, 1
		mesh.cell_first = make([]i32, 2)
		return true
	}
	lo, hi := mesh.vertices[0].xz, mesh.vertices[0].xz
	for vertex in mesh.vertices {
		lo = {dmath.min(lo.x, vertex.x), dmath.min(lo.y, vertex.z)}
		hi = {dmath.max(hi.x, vertex.x), dmath.max(hi.y, vertex.z)}
	}
	mesh.origin = lo
	columns := (hi.x - lo.x) / mesh.cell + 1
	rows := (hi.y - lo.y) / mesh.cell + 1
	if !(columns * rows < 1 << 24) do return false
	mesh.columns, mesh.rows = i32(columns), i32(rows)
	cells := int(mesh.columns * mesh.rows)
	mesh.cell_first = make([]i32, cells + 1)
	fill := make([]i32, cells, context.temp_allocator)
	for pass in 0 ..< 2 {
		for p in 0 ..< poly_count(mesh) {
			first, last := poly_cells(mesh, Poly(p))
			for row in first.y ..= last.y {
				for column in first.x ..= last.x {
					cell := row * mesh.columns + column
					if pass == 0 {
						mesh.cell_first[cell + 1] += 1
					} else {
						mesh.cell_polys[mesh.cell_first[cell] + fill[cell]] = Poly(p)
						fill[cell] += 1
					}
				}
			}
		}
		if pass == 0 {
			for c in 0 ..< cells do mesh.cell_first[c + 1] += mesh.cell_first[c]
			mesh.cell_polys = make([]Poly, mesh.cell_first[cells])
		}
	}
	return true
}

// The first and last cell (column, row) a polygon's XZ bounds touch.
@(private)
poly_cells :: proc(mesh: ^Mesh, poly: Poly) -> (first, last: [2]i32) {
	first, last = {max(i32), max(i32)}, {-1, -1}
	for k in mesh.first[poly] ..< mesh.first[poly + 1] {
		at := cell_xy(mesh, mesh.vertices[mesh.corners[k]].xz)
		first, last =
			{dmath.min(first.x, at.x), dmath.min(first.y, at.y)}, {dmath.max(last.x, at.x), dmath.max(last.y, at.y)}
	}
	return
}

// The grid cell (column, row) of an XZ point, clamped to the grid.
@(private)
cell_xy :: proc(mesh: ^Mesh, xz: [2]f32) -> [2]i32 {
	return {
		dmath.to_i32_clamped((xz.x - mesh.origin.x) / mesh.cell, 0, mesh.columns - 1),
		dmath.to_i32_clamped((xz.y - mesh.origin.y) / mesh.cell, 0, mesh.rows - 1),
	}
}

// The grid cell index of an XZ point, clamped to the grid.
@(private)
cell_of :: proc(mesh: ^Mesh, xz: [2]f32) -> i32 {
	at := cell_xy(mesh, xz)
	return at.y * mesh.columns + at.x
}

// The point of a polygon nearest to an XZ point, seen from above: the point itself when inside, else the nearest
// point of its nearest edge (the first such edge).
@(private)
closest_xz :: proc(mesh: ^Mesh, poly: Poly, xz: [2]f32) -> [2]f32 {
	pos := [3]f32{xz.x, 0, xz.y}
	if contains(mesh, poly, pos) do return xz
	best: f32 = max(f32)
	out := xz
	for k in mesh.first[poly] ..< mesh.first[poly + 1] {
		a, b := corner_edge(mesh, poly, k)
		ab := b.xz - a.xz
		t := dmath.clamp(dmath.dot2(xz - a.xz, ab) / dmath.max(dmath.dot2(ab, ab), 1e-12), 0, 1)
		on := a.xz + ab * t
		distance := dmath.dist_sq2(on, xz)
		if distance < best do best, out = distance, on
	}
	return out
}
