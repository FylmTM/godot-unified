// Steering and movement (src/nav/README.md): where a walker heads next along a field (the corner a string pulled
// through the portals ahead turns at), and a move along the surface (across portals, sliding along walls, at the
// polygon's height), so a walker never leaves the mesh and needs no physics query to move.
package nav

import "unified:dmath"

// How many portals steer looks ahead: past them a walker heads into the funnel they leave open.
LOOKAHEAD :: 16

// How many edges one move may cross or slide along before it stops where it got to.
MOVE_STEPS :: 64

// Where a walker on `poly` at `pos` heads next on its way to `goal` (a point on the field's goal polygon): the first
// corner the shortest path through the next LOOKAHEAD portals turns at (the funnel of the portals' ends, pulled taut),
// TURN_INSET inside its portal, or `goal` itself when nothing is in the way (a turn the walker stands on is passed). On the goal polygon: `goal`.
// When the goal can't be reached, or without a field or a polygon: `pos` (stay). The mesh is already shrunk by the
// bake's agent radius, so a corner is where a walker of that radius can stand.
steer :: proc(mesh: ^Mesh, field: ^Field, poly: Poly, pos, goal: [3]f32) -> [3]f32 {
	if field == nil || poly == NO_POLY do return pos
	if poly == field.goal do return goal
	if field.next[poly] < 0 do return pos
	// The portals ahead as the walker sees them: leaving a counter-clockwise polygon through its edge a → b, b is on
	// the left. The goal, once the chain reaches its polygon, is a portal of one point.
	lefts, rights: [LOOKAHEAD + 1][3]f32
	count := 0
	reached := false
	for at := poly; count < LOOKAHEAD; count += 1 {
		if at == field.goal {
			lefts[count], rights[count] = goal, goal
			count += 1
			reached = true
			break
		}
		rights[count], lefts[count] = corner_edge(mesh, at, field.next[at])
		at = mesh.across[field.next[at]]
	}
	// The funnel from the apex: it narrows portal by portal, and where one side crosses the other the path turns at
	// that side's corner. A corner the walker stands on becomes the apex and the funnel starts again past it (a side
	// still at the apex takes the next portal's end whatever it is, so each restart starts further on).
	apex, left, right := pos, pos, pos
	apex_at, left_at, right_at := -1, -1, -1
	for i := 0; i < count; i += 1 {
		if area2(apex, right, rights[i]) >= 0 {
			if apex == right || apex == left || area2(apex, left, rights[i]) < 0 {
				right, right_at = rights[i], i
			} else {
				turn := pulled(lefts[left_at], rights[left_at])
				if !standing_on(pos, turn) do return turn
				apex, apex_at = turn, left_at
				left, left_at, right, right_at = apex, apex_at, apex, apex_at
				i = apex_at
				continue
			}
		}
		if area2(apex, left, lefts[i]) <= 0 {
			if apex == left || apex == right || area2(apex, right, lefts[i]) > 0 {
				left, left_at = lefts[i], i
			} else {
				turn := pulled(rights[right_at], lefts[right_at])
				if !standing_on(pos, turn) do return turn
				apex, apex_at = turn, right_at
				left, left_at, right, right_at = apex, apex_at, apex, apex_at
				i = apex_at
				continue
			}
		}
	}
	if reached do return goal
	return (left + right) * 0.5 // the lookahead ran out: into the funnel it leaves open
}

// How far a turn is pulled in from its corner along the portal, so a walker passes beside the corner rather than on it
// (on a corner, which of the polygons around it a walker is in is a guess; on a portal's inside it is not).
TURN_INSET :: f32(0.05)

// A corner `end` of a portal, pulled TURN_INSET toward its other end `other` (at most to its middle).
@(private)
pulled :: proc(end, other: [3]f32) -> [3]f32 {
	length := dmath.length2(other.xz - end.xz)
	if !(length > 0) do return end
	return end + (other - end) * dmath.min(TURN_INSET / length, 0.5)
}

// Whether a walker at `pos` stands on `point` (within a millimetre, seen from above).
@(private)
standing_on :: #force_inline proc "contextless" (pos, point: [3]f32) -> bool {
	away := point.xz - pos.xz
	return away.x * away.x + away.y * away.y < 0.000001
}

// Moves a walker on `poly` from `from` toward `to` along the surface, seen from above: across the polygons it enters,
// sliding along a wall it meets (a millimetre inside), at most MOVE_STEPS edges. The polygon it ends on and where, at
// that polygon's height (`to`'s height is not read). A walker moved only by `move` stays on the mesh.
move :: proc(mesh: ^Mesh, poly: Poly, from, to: [3]f32) -> (Poly, [3]f32) {
	if poly == NO_POLY do return poly, from
	at, current, target := poly, from, to
	for _ in 0 ..< MOVE_STEPS {
		exit: i32 = -1
		exit_t: f32 = 2
		for k in mesh.first[at] ..< mesh.first[at + 1] {
			a, b := corner_edge(mesh, at, k)
			beyond := area2(a, b, target)
			if beyond >= 0 do continue // the target is on the inside of this edge
			inside := area2(a, b, current)
			t: f32 = 0
			if inside > 0 do t = inside / (inside - beyond)
			if t < exit_t do exit, exit_t = k, t
		}
		if exit < 0 {
			current = target
			break
		}
		// Leaving at once from a corner (steer heads for corners, so a walker often stands on one), the move goes into
		// whichever polygon around the corner its direction points into, not across the first edge that meets there.
		if exit_t == 0 {
			if around := around_corner(mesh, at, current, target); around != NO_POLY {
				at = around
				continue
			}
		}
		hit := current + (target - current) * exit_t
		if neighbour := mesh.across[exit]; neighbour != NO_POLY {
			at, current = neighbour, hit
			continue
		}
		// a wall: keep the part of the move along it
		a, b := corner_edge(mesh, at, exit)
		along := dmath.normalize2(b.xz - a.xz, 0)
		inward := [2]f32{along.y, 0 - along.x} // left of a → b: the polygon's side
		rest := dmath.dot2(target.xz - hit.xz, along)
		slid := hit.xz + inward * 0.001
		current = {slid.x, hit.y, slid.y}
		target = {slid.x + along.x * rest, hit.y, slid.y + along.y * rest}
	}
	current.y = height_at(mesh, at, current)
	return at, current
}

// When `pos` is on a corner of `poly` (seen from above): the polygon around that corner, found by stepping across the
// edges that meet at it (the nearest first, then by corner order), whose angle at the corner holds the direction toward
// `target` (an edge's direction counts for both sides); NO_POLY when `pos` is on no corner or none does (the corner is
// on the mesh's border and the move leaves it).
@(private)
around_corner :: proc(mesh: ^Mesh, poly: Poly, pos, target: [3]f32) -> Poly {
	vertex: i32 = -1
	for k in mesh.first[poly] ..< mesh.first[poly + 1] {
		if standing_on(pos, mesh.vertices[mesh.corners[k]]) do vertex = mesh.corners[k]
	}
	if vertex < 0 do return NO_POLY
	corner := mesh.vertices[vertex]
	ahead := corner + (target - pos)
	// a fan of at most MAX_FAN polygons, walked across the edges that end at the corner
	MAX_FAN :: 16
	fan: [MAX_FAN]Poly
	fan[0] = poly
	count := 1
	for i := 0; i < count; i += 1 {
		at := fan[i]
		first, last := mesh.first[at], mesh.first[at + 1]
		for k in first ..< last {
			if mesh.corners[k] != vertex do continue
			before := mesh.vertices[mesh.corners[k - 1 if k > first else last - 1]]
			after := mesh.vertices[mesh.corners[k + 1 if k + 1 < last else first]]
			if i > 0 && area2(corner, after, ahead) >= 0 && area2(before, corner, ahead) >= 0 do return at
		}
		for k in first ..< last {
			lo, hi := edge_key(mesh, at, k)
			if lo != vertex && hi != vertex do continue
			next := mesh.across[k]
			if next == NO_POLY || count == MAX_FAN do continue
			seen := false
			for earlier in fan[:count] do seen ||= earlier == next
			if !seen {
				fan[count] = next
				count += 1
			}
		}
	}
	return NO_POLY
}
