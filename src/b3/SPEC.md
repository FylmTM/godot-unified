# `unified:b3`: the Box3D API

Status: signed off 2026-11-14 (#7); its conventions 2026-11-11; 2026-11-16 private to physics (#236).

Box3D is the unified-box3d shared library (Box3D ported to Odin, exporting upstream's C API plus our snapshots and
images; `pins.cfg`). Its Odin bindings are the `box3d:` collection (`box3d "box3d:bindings"`, upstream's API 1:1).
`b3` is the hand-written layer over them, and **physics' private implementation** (#236): only `src/physics` and
`tests/b3` import `unified:b3` (the lint); games reach Box3D through `unified:physics` (`src/physics/SPEC.md`, The
boundary), and nothing imports `box3d:bindings` but `b3`.

## Conventions

- **Names** derived mechanically from C: `b3Body_GetPosition` → `body_get_position`, `b3World_CastRayClosest` →
  `world_cast_ray_closest`; types Ada_Case (`b3BodyId` → `Body_Id`, `b3ShapeDef` → `Shape_Def`), fields snake_case
  (`bodyIdA` → `body_id_a`), enum members Ada_Case (`b3_dynamicBody` → `.Dynamic_Body`).
- **Vectors** are `[3]f32`, **rotations** `[4]f32` (x, y, z, w), in signatures and in structs.
- **Structs** are mirrors: the bindings' layout scalar for scalar, with the names and vector types above (def structs,
  `Transform`, `AABB`, `Sphere`, `Capsule`, `Query_Filter`, `Ray_Result`, contact events). A conversion is a
  `transmute` or a pointer cast: no copy loop, no math. Sizes are `#assert`ed in `types.odin`; `tests/b3` checks every
  scalar's offset and kind. Ids and structs callers don't touch are aliases (`Body_Id :: box3d.BodyId`, `Hull_Data`,
  `Box_Hull`, `World_Snapshot`, `World_State`).
  Why mirrors rather than aliased defs: an aliased def keeps `Vec3` fields and camelCase enum members, so every
  caller converts again (`bd.position = v3(p)`, `.dynamicBody`); a mirror costs nothing at run time and its layout is
  checked at compile time.
- **Pointer + count** become slices, in (`create_hull(points: [][3]f32, ...)`, `world_load_image(bytes: []u8)`) and
  out (`world_state_get_data`, `world_get_contact_events`: slices into Box3D's memory, valid until the next step or
  save).
- **Callbacks** are Odin procs taking `user: rawptr`; a private trampoline (`proc "c"`) restores the caller's
  `context` and calls them.
- **Results** are `(value, ok)` instead of a `hit` field (`world_cast_ray_closest`). Scalars keep C's types (`i32`).
- **No allocation of its own**: collecting is the caller's (callbacks), images go into the caller's `World_State`,
  snapshots into the caller's `World_Snapshot`.
- **Coverage**: what `src/physics` wraps (its "What physics covers"), nothing more. Each proc is tested once, through
  physics (`tests/physics`); `tests/b3` keeps what is b3's own (below).
- Every proc has a short doc comment: what it does, and anything the C name doesn't say (ownership, validity).
- `b3` is linted as tick code (`tests/lint`): it imports `box3d:bindings` and `base:runtime` only.

## Coverage

Physics' coverage (`src/physics/SPEC.md`, What physics covers) plus what the plug-in itself needs: world creation
and destruction, `world_step`, snapshots, world states, images, `world_hash_state`, `world_hash_awake_bodies`, the
profile and counters (the bench).

World creation and destruction touch the library's global world table: callers serialise them (`physics.create`
does).

## Tests (`tests/b3`)

Every mirror's layout against its binding, scalar by scalar; the conversions are the identity on the bits; and the
golden trace that pins the library's results on every platform (`GOLDEN`, a fixed scene hashed every 60 ticks: a library upgrade that changes it
fails here first). A sync-test of its own (`sync_test.odin`): a stack falls asleep and a push wakes it while the run
rolls back 8 ticks after every tick; every re-simulated tick hashes (whole world and awake bodies) as a straight
1-worker run does, on 1 and 4 workers. So an upgrade is proven at this layer before physics' tests run.
