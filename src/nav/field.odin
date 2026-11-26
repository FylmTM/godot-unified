// Distance fields (src/nav/README.md): every polygon's distance to a goal polygon and the edge that leads toward it,
// computed once per goal and memoized in the World (Fields), since a field is a pure function of the mesh and the
// goal: a hit and a miss give the same answer, so a rollback can never find it stale.
package nav

import "unified:dmath"

// Every polygon's way to one goal polygon: its distance along the mesh (through the middles of the edges crossed) and
// the corner whose edge leads one polygon closer.
Field :: struct {
	goal: Poly,
	cost: []f32, // UNREACHABLE: no way there
	next: []i32, // the corner (an index into Mesh.corners) whose edge leads toward the goal; -1 at the goal, or none
}

// A Field's cost of a polygon with no way to the goal.
UNREACHABLE :: f32(1e30)

// A World's memo of fields, by goal: a fixed number of them, the least recently used replaced on a miss. What it
// holds never changes what `field` returns, so it is World content that needs no rollback (src/sim/README.md,
// World). Made once next to its Mesh (fields_make).
Fields :: struct {
	mesh:  ^Mesh,
	slots: []Field,
	used:  []u64, // when each slot was last asked for (0: empty)
	clock: u64,
	heap:  [dynamic]Heap_Item, // field_compute's, made with room for every corner: a miss allocates nothing
}

// A Dijkstra queue entry, ordered by cost, then polygon index.
@(private)
Heap_Item :: struct {
	cost: f32,
	poly: Poly,
}

// A memo of `count` fields for `mesh` (at least 1; a few more than the goals a tick asks for: the players' polygons,
// a core), with storage from `allocator` (fields_destroy frees it with the same allocator).
fields_make :: proc(mesh: ^Mesh, count: int, allocator := context.allocator) -> Fields {
	context.allocator = allocator
	fields := Fields {
		mesh  = mesh,
		slots = make([]Field, dmath.max(count, 1)),
		used  = make([]u64, dmath.max(count, 1)),
		heap  = make([dynamic]Heap_Item, 0, len(mesh.corners) + 1),
	}
	for &slot in fields.slots {
		slot = {
			goal = NO_POLY,
			cost = make([]f32, poly_count(mesh)),
			next = make([]i32, poly_count(mesh)),
		}
	}
	return fields
}

// Frees what fields_make made.
fields_destroy :: proc(fields: ^Fields, allocator := context.allocator) {
	context.allocator = allocator
	for slot in fields.slots {
		delete(slot.cost)
		delete(slot.next)
	}
	delete(fields.slots)
	delete(fields.used)
	delete(fields.heap)
	fields^ = {}
}

// The field toward `goal`: the memo's when it holds it, else computed into the least recently used slot (allocating
// nothing). The pointer stays valid until `len(fields.slots)` other goals have been asked for. A goal outside the mesh
// (NO_POLY, or any index a crafted or stale value holds) gives nil.
field :: proc(fields: ^Fields, goal: Poly) -> ^Field {
	if !in_mesh(fields.mesh, goal) do return nil
	fields.clock += 1
	oldest := 0
	for &slot, i in fields.slots {
		if slot.goal == goal {
			fields.used[i] = fields.clock
			return &slot
		}
		if fields.used[i] < fields.used[oldest] do oldest = i
	}
	fields.used[oldest] = fields.clock
	field_compute(fields.mesh, goal, &fields.slots[oldest], &fields.heap)
	return &fields.slots[oldest]
}

// Dijkstra from the goal over the polygons, a step costing the distance from one polygon's centre through the middle
// of the edge between them to the other's; the queue ordered by (cost, polygon index), so the result is one function
// of the mesh and the goal. `heap` is scratch. A goal outside the mesh leaves every polygon UNREACHABLE.
field_compute :: proc(mesh: ^Mesh, goal: Poly, out: ^Field, heap: ^[dynamic]Heap_Item) {
	out.goal = goal
	for p in 0 ..< poly_count(mesh) {
		out.cost[p] = UNREACHABLE
		out.next[p] = -1
	}
	clear(heap)
	if !in_mesh(mesh, goal) do return
	out.cost[goal] = 0
	heap_push(heap, {0, goal})
	for len(heap) > 0 {
		top := heap_pop(heap)
		if top.cost > out.cost[top.poly] do continue // a stale entry
		for k in mesh.first[top.poly] ..< mesh.first[top.poly + 1] {
			neighbour := mesh.across[k]
			if neighbour == NO_POLY do continue
			a, b := corner_edge(mesh, top.poly, k)
			middle := (a + b) * 0.5
			cost :=
				top.cost +
				dmath.length3(middle - mesh.centers[top.poly]) +
				dmath.length3(mesh.centers[neighbour] - middle)
			if cost < out.cost[neighbour] {
				out.cost[neighbour] = cost
				// the neighbour's way on is this same edge, seen from its side
				for j in mesh.first[neighbour] ..< mesh.first[neighbour + 1] {
					if mesh.across[j] == top.poly && same_edge(mesh, top.poly, k, neighbour, j) {
						out.next[neighbour] = j
						break
					}
				}
				heap_push(heap, {cost, neighbour})
			}
		}
	}
}

// Whether corner k of `poly` and corner j of `other` are the same edge (the two polygons may share more than one).
@(private)
same_edge :: proc(mesh: ^Mesh, poly: Poly, k: i32, other: Poly, j: i32) -> bool {
	lo, hi := edge_key(mesh, poly, k)
	other_lo, other_hi := edge_key(mesh, other, j)
	return lo == other_lo && hi == other_hi
}

@(private)
heap_before :: #force_inline proc "contextless" (a, b: Heap_Item) -> bool {
	return a.cost < b.cost || (a.cost == b.cost && a.poly < b.poly)
}

@(private)
heap_push :: proc(heap: ^[dynamic]Heap_Item, item: Heap_Item) {
	append(heap, item)
	i := len(heap) - 1
	for i > 0 {
		parent := (i - 1) / 2
		if !heap_before(heap[i], heap[parent]) do break
		heap[i], heap[parent] = heap[parent], heap[i]
		i = parent
	}
}

@(private)
heap_pop :: proc(heap: ^[dynamic]Heap_Item) -> Heap_Item {
	top := heap[0]
	last := pop(heap)
	if len(heap) == 0 do return top
	heap[0] = last
	i := 0
	for {
		left, right, smallest := 2 * i + 1, 2 * i + 2, i
		if left < len(heap) && heap_before(heap[left], heap[smallest]) do smallest = left
		if right < len(heap) && heap_before(heap[right], heap[smallest]) do smallest = right
		if smallest == i do break
		heap[i], heap[smallest] = heap[smallest], heap[i]
		i = smallest
	}
	return top
}
