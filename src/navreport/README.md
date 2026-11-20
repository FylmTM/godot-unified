# `unified:navreport`: a level's navigation, reported

What `uni bake --report` prints for each level: the navigation mesh the sim gets, with what makes a level's walkers
fail without an error anywhere. A mesh that loads and builds can still be cut in pieces: a ramp that doesn't join the
deck, a crate's top, or the floor inside a solid that Godot's bake finds walkable; and a gate whose nearest floor is
one of those pieces never reaches the core, so its enemies stand still. Those show here, before the game runs on the
level, instead of in a test written to dump polygons.

It is a small program and a package: the CLI imports no unified package (src/cli/README.md), so it builds this one
from the unified checkout (a game repo's submodule too) and runs it on the files the bake exported, and
`tests/navreport` tests the package directly. It reads a `.level` with `unified:level` and builds the mesh with
`unified:nav` exactly as a game's `world_create` does, so the report is of the mesh the sim walks, not of the scene.

## How it works

- **Islands** are `nav.islands`: polygons joined by shared edges. The largest is the level's floor; every other one is
  cut off, since a walker placed on it reaches nothing else. Small ones on top of props are usual and harmless; one
  that holds a marker is the finding to act on.
- **Markers** are placed with `nav.nearest` within `MARKER_REACH`, as a game finds the polygon of a spawn or a goal:
  each gets the island of its nearest polygon, or none (off the mesh). The report doesn't know the game's vocabulary,
  so it places every marker and leaves a reader to judge which ones walkers use.
- **What the export changed** in the bake (vertices lowered onto the floor, polygons inside solids left out) comes from
  the exporter's result, not the file, so the CLI adds it to each level's report.

## Decisions

- It only reports. Its findings never fail a bake: a level may have harmless islands, and markers walkers never use.
  A game that wants a guarantee asserts it in its own tests with `nav.islands` and `nav.nearest`.
