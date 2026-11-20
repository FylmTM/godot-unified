# `unified:navreport`: a level's navigation, reported

What `uni bake --report` prints for each level with a navigation mesh: the mesh the sim gets, with what makes a
level's walkers fail without an error anywhere. A mesh that loads and builds can still be cut in pieces: a ramp that
doesn't join the deck, a crate's top, or the floor inside a solid that Godot's bake finds walkable. A gate whose
nearest floor is one of those pieces never reaches the core, so its enemies stand still. Those show here, before the
game runs on the level, instead of in a test written to dump polygons.

It is a small program and a package. The CLI imports no unified package (src/cli/README.md), so it builds this one
from the unified checkout (a game repo's submodule too) and runs it on the files the bake exported; `tests/navreport`
tests the package directly. It reads a `.level` with `unified:level` and builds the mesh with `unified:nav` exactly as
a game's `world_create` does, so the report is of the mesh the sim walks, not of the scene.

## Reading a report

- **The mesh:** its polygons, vertices and the agent it was baked for (radius, height, max climb).
- **Findings:** a one-line summary of what follows: islands cut off, markers on a cut-off island, markers off the
  mesh. "None" is a mesh in one piece with every marker on it.
- **Islands** (`nav.island_of`): the polygons joined by shared edges, the largest first, each with its polygon count
  and bounds. The largest is the level's floor; every other one is cut off, since a walker on it reaches nothing
  else. Small ones on top of props are usual and harmless. One that holds a marker is named with it, and is the
  finding to act on.
- **Markers:** every marker, with its position and where it is. On the mesh means its nearest polygon
  (`nav.nearest`) is within the agent's radius plus `MARKER_MARGIN`: Godot's bake shrinks the mesh by the radius from
  the walls, and a game finds a marker's polygon within about that. A marker on a cut-off island is flagged; one
  farther off is flagged as off the mesh, with the island its nearest polygon within `MARKER_REACH` is on, if any.
  The report doesn't know the game's vocabulary, so it places every marker and leaves a reader to judge which ones
  walkers use: a marker for a light or a camera is off the mesh by design.
- **Export:** what the exporter changed in the bake (src/level/README.md, Authoring): how far it lowered a vertex
  onto the floor at most (Godot's bake floats the whole mesh a little; much more than a cell's height is worth a
  look), and how many polygons inside solids it left out. It exists only during an export, so the CLI passes it in.

## Decisions

- It only reports. Its findings never fail a bake: a level may have harmless islands, and markers walkers never use.
  A game that wants a guarantee asserts it in its own tests, or checks at run time with `nav.connected`.
