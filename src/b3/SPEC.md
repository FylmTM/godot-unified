# `unified:b3`: the Box3D API

Signed off: conventions 2026-11-11; coverage pending review.

Box3D is the unified-box3d shared library (Box3D ported to Odin, exporting upstream's C API plus our snapshots and
images; `pins.cfg`). Its Odin bindings are the `box3d:` collection (`box3d "box3d:bindings"`, upstream's API 1:1).
`b3` is the hand-written layer every unified package and game uses instead: `src/physics` and games import
`unified:b3`, never `box3d:bindings`.

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
- **Coverage**: what `src/physics` and the games use, nothing more; a new use adds its proc with a test.
- `b3` is linted as tick code (`tests/lint`): it imports `box3d:bindings` and `base:runtime` only.

## Coverage

| Group     | Procs |
|-----------|-------|
| World     | `default_world_def`, `create_world`, `destroy_world`, `world_step`, `world_get_gravity`, `world_get_contact_events`, `world_overlap_aabb`, `world_cast_ray`, `world_cast_ray_closest` |
| Rollback  | `world_save_snapshot`, `world_restore_snapshot`, `destroy_world_snapshot`, `create_world_state`, `destroy_world_state`, `world_state_get_data`, `world_save_image`, `world_load_image`, `world_hash_state` |
| Bodies    | `default_body_def`, `create_body`, `destroy_body`, `body_is_valid`, `body_get_type`, `body_get_position`, `body_get_rotation`, `body_set_transform`, `body_get_local_point`, `body_get_linear_velocity`, `body_get_angular_velocity`, `body_set_linear_velocity`, `body_set_angular_velocity`, `body_apply_linear_impulse_to_center`, `body_get_mass` |
| Shapes    | `default_shape_def`, `default_query_filter`, `create_sphere_shape`, `create_capsule_shape`, `create_hull_shape`, `shape_get_body`, `shape_is_sensor`, `create_hull`, `clone_and_transform_hull`, `destroy_hull`, `make_box_hull` |
| Joints    | `destroy_joint`, `joint_is_valid`, `joint_get_body_a`, `joint_set_local_frame_a`, `joint_set_local_frame_b`, `default_motor_joint_def`, `create_motor_joint`, `default_mover_joint_def`, `create_mover_joint`, `mover_joint_set_linear_velocity`, `mover_joint_set_max_velocity_force`, `default_pogo_joint_def`, `create_pogo_joint`, `pogo_joint_set_spring_hertz`, `pogo_joint_set_spring_damping_ratio`, `pogo_joint_set_max_tension_force`, `pogo_joint_set_max_compression_force`, `pogo_joint_set_normal`, `pogo_joint_get_current_speed`, `pogo_joint_get_impulse` |

World creation and destruction touch the library's global world table: callers serialise them (`physics.create`
does).

## Tests (`tests/b3`)

One test per proc against the library (setters read back through the bindings' getters); every mirror's layout
against its binding, scalar by scalar; the conversions are the identity on the bits; and the golden trace that pins the
library's results (`GOLDEN`, a fixed scene hashed every 60 ticks: a library upgrade that changes it fails here first).
