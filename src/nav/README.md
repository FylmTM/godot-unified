# `unified:nav`: walking a navigation mesh

Tick code for walkers that follow the floor in 3D: enemies chasing players across a yard, up a ramp onto a deck, over
a bridge or through the corridor under it. A `Mesh` is built once in a game's `world_create` from plain slices
(`build`): a level's baked navigation (`Level.nav_vertices`, `nav_polygons`: src/level/README.md, Authoring) or a
generated level's own. It imports only `dmath`, so it needs neither a level nor the sim, and a game's sim imports it
like any tick package.

## How it works

- **The mesh** is convex polygons, counter-clockwise seen from above, each linked to the polygons across its edges by
  their two vertex indices (a counting sort, no hashing: a level's mesh guarantees that adjacent polygons share
  indices). Each polygon has its plane, so a walker's height is the floor's under it, and an XZ grid finds the
  polygon under a point (`locate`, the floor nearest in height on stacked floors) or the nearest point of the mesh
  (`nearest`, for a player standing just off it: Godot's bake shrinks the mesh by its agent radius from the walls).
- **A walker keeps its polygon** (`Poly`, an i32 in its row) and passes it to every call, so it is never located
  again after its spawn.
- **Fields.** A `Field` is every polygon's distance to a goal polygon and the edge that leads toward it: Dijkstra over
  the polygons, ordered by (cost, polygon index), so it is one function of the mesh and the goal. `Fields` memoizes
  a few of them in the World, least recently used replaced: a hit and a miss return the same field, so a rollback, a
  late join or a replay can never find it stale (the World rule: src/sim/README.md, World). Every walker chasing one
  player shares that player's field.
- **Steering** (`steer`) pulls a string through the next `LOOKAHEAD` portals of the field's path (the funnel of their
  ends) and returns the first turn, set `TURN_INSET` inside its portal: a walker passes beside a corner, never on it,
  where which polygon it is in would be a guess. **Moving** (`move`) walks a straight step across the polygons it
  enters and slides along a wall it meets, then takes the floor's height: a walker moved only by `move` never leaves
  the mesh, and needs no physics query to walk. A game drives its walker's kinematic body to that pose.
- **Determinism**: f32 with `+ − × ÷ sqrt`, fixed iteration orders, ties broken by index, and no allocation after
  `build` and `fields_make` (a miss of the memo computes into a slot it already has). `tests/nav` pins a walker run
  every CI platform must reproduce bit for bit.

## Decisions

- **Godot bakes triangles** (Recast's detail mesh), two to three times the polygons a merged mesh would have. Fields
  and steering are cheap enough at a yard's size (`uni bench`'s nav row) that the mesh is used as baked; merging
  triangles into convex polygons at build is the step to take if a larger level's field cost asks for it.
- **The baked mesh floats** a cell or two (the bake's cell height) above the floor it was baked from. A walker's
  height is the mesh's; a game that wants feet on the collision floor offsets its body by that.
- **No avoidance between walkers.** A crowd that must not overlap separates itself in the game (a neighbour pass on
  `sim.Grid`), and a walker blocked by a moving body is the game's rule; the mesh is the static floor only.
- **No off-mesh links** (jumps, drops, ladders): a walker goes where the floor joins.
