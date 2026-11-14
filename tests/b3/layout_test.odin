// unified:b3 (src/b3/SPEC.md) against the library, black-box: every struct it mirrors has the bindings' layout scalar
// for scalar (so its conversions are a transmute or a pointer cast, free), one test per wrapper proc (api_test.odin),
// and the golden trace that pins the library's results (golden_test.odin).
package test_b3

import "base:runtime"
import "core:fmt"
import "core:testing"

import box3d "box3d:bindings"
import "unified:b3"

// Every mirrored struct and the binding it stands for. `prefix`: ours is a leading part of theirs (Ray_Result leaves out
// `hit`, its last field).
Pair :: struct {
	ours, theirs: typeid,
	prefix:       bool,
}

PAIRS := []Pair {
	{[3]f32, box3d.Vec3, false},
	{[4]f32, box3d.Quat, false},
	{b3.Transform, box3d.Transform, false},
	{b3.AABB, box3d.AABB, false},
	{b3.Body_Type, box3d.BodyType, false},
	{b3.Motion_Locks, box3d.MotionLocks, false},
	{b3.Capacity, box3d.Capacity, false},
	{b3.World_Def, box3d.WorldDef, false},
	{b3.Body_Def, box3d.BodyDef, false},
	{b3.Surface_Material, box3d.SurfaceMaterial, false},
	{b3.Filter, box3d.Filter, false},
	{b3.Shape_Def, box3d.ShapeDef, false},
	{b3.Query_Filter, box3d.QueryFilter, false},
	{b3.Sphere, box3d.Sphere, false},
	{b3.Capsule, box3d.Capsule, false},
	{b3.Joint_Def, box3d.JointDef, false},
	{b3.Motor_Joint_Def, box3d.MotorJointDef, false},
	{b3.Mover_Joint_Def, box3d.MoverJointDef, false},
	{b3.Pogo_Joint_Def, box3d.PogoJointDef, false},
	{b3.Ray_Result, box3d.RayResult, true},
	{b3.Tree_Stats, box3d.TreeStats, false},
	{b3.Contact_Begin_Touch_Event, box3d.ContactBeginTouchEvent, false},
	{b3.Contact_End_Touch_Event, box3d.ContactEndTouchEvent, false},
	{b3.Contact_Hit_Event, box3d.ContactHitEvent, false},
}

// One scalar of a flattened layout: its offset and its kind ("f4", "i4", "u8", "b1", "p8", ...).
Scalar :: struct {
	offset: int,
	kind:   string,
}

flatten :: proc(type_info: ^runtime.Type_Info, base: int, out: ^[dynamic]Scalar) {
	#partial switch variant in type_info.variant {
	case runtime.Type_Info_Named:
		flatten(variant.base, base, out)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(variant.field_count) {
			flatten(variant.types[i], base + int(variant.offsets[i]), out)
		}
	case runtime.Type_Info_Array:
		for k in 0 ..< variant.count {
			flatten(variant.elem, base + k * variant.elem_size, out)
		}
	case runtime.Type_Info_Enum:
		flatten(variant.base, base, out)
	case runtime.Type_Info_Float:
		append(out, Scalar{base, fmt.tprintf("f%d", type_info.size)})
	case runtime.Type_Info_Integer:
		append(out, Scalar{base, fmt.tprintf("%s%d", variant.signed ? "i" : "u", type_info.size)})
	case runtime.Type_Info_Boolean:
		append(out, Scalar{base, fmt.tprintf("b%d", type_info.size)})
	case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer, runtime.Type_Info_Procedure:
		append(out, Scalar{base, fmt.tprintf("p%d", type_info.size)})
	case runtime.Type_Info_String:
		// cstring
		append(out, Scalar{base, fmt.tprintf("p%d", type_info.size)})
	case:
		append(out, Scalar{base, fmt.tprintf("? %variant", type_info.id)})
	}
}

// Each mirror has its binding's size and alignment and the same scalars at the same offsets, nested structs and arrays
// included: a conversion reinterprets the bytes and changes nothing.
@(test)
mirrors_match_the_bindings :: proc(t: ^testing.T) {
	for pair in PAIRS {
		ours := type_info_of(pair.ours)
		theirs := type_info_of(pair.theirs)
		our_scalars := make([dynamic]Scalar, context.temp_allocator)
		their_scalars := make([dynamic]Scalar, context.temp_allocator)
		flatten(ours, 0, &our_scalars)
		flatten(theirs, 0, &their_scalars)
		if pair.prefix {
			testing.expectf(t, ours.size <= theirs.size, "%v is larger than %v", pair.ours, pair.theirs)
			if len(their_scalars) > len(our_scalars) do resize(&their_scalars, len(our_scalars))
		} else {
			testing.expectf(
				t,
				ours.size == theirs.size,
				"%v: size %d, %v: %d",
				pair.ours,
				ours.size,
				pair.theirs,
				theirs.size,
			)
		}
		testing.expectf(
			t,
			ours.align == theirs.align,
			"%v: align %d, %v: %d",
			pair.ours,
			ours.align,
			pair.theirs,
			theirs.align,
		)
		if !testing.expectf(t, len(our_scalars) == len(their_scalars), "%v: %d scalars, %v: %d", pair.ours, len(our_scalars), pair.theirs, len(their_scalars)) do continue
		for scalar, i in our_scalars {
			testing.expectf(
				t,
				scalar == their_scalars[i],
				"%v scalar %d: %v, %v: %v",
				pair.ours,
				i,
				scalar,
				pair.theirs,
				their_scalars[i],
			)
		}
	}
}

// The conversions are the identity on the bits: [3]f32 is (x, y, z), [4]f32 is (x, y, z, w) with w Box3D's `s`,
// a Transform is (p, q), and the enum values are the library's.
@(test)
conversions_are_free :: proc(t: ^testing.T) {
	vec := [3]f32{1, -2, 3.5}
	box_vec := transmute(box3d.Vec3)vec
	testing.expect_value(t, box_vec, box3d.Vec3{1, -2, 3.5})
	quat := [4]f32{0.1, 0.2, 0.3, 0.9}
	box_quat := transmute(box3d.Quat)quat
	testing.expect_value(t, box_quat, box3d.Quat{{0.1, 0.2, 0.3}, 0.9})
	transform := b3.Transform{{1, 2, 3}, {0, 0, 0, 1}}
	box_transform := transmute(box3d.Transform)transform
	testing.expect_value(t, box_transform, box3d.Transform{{1, 2, 3}, {{0, 0, 0}, 1}})
	testing.expect_value(t, i32(b3.Body_Type.Static_Body), i32(box3d.BodyType.staticBody))
	testing.expect_value(t, i32(b3.Body_Type.Kinematic_Body), i32(box3d.BodyType.kinematicBody))
	testing.expect_value(t, i32(b3.Body_Type.Dynamic_Body), i32(box3d.BodyType.dynamicBody))
	// A def through the wrapper reads as the library's own.
	box_body_def := box3d.DefaultBodyDef()
	ours := b3.default_body_def()
	testing.expect_value(t, ours.rotation, transmute([4]f32)box_body_def.rotation)
	testing.expect_value(t, ours.gravity_scale, box_body_def.gravityScale)
	testing.expect_value(t, ours.sleep_threshold, box_body_def.sleepThreshold)
	testing.expect_value(t, ours.enable_sleep, box_body_def.enableSleep)
	testing.expect_value(t, ours.internal_value, box_body_def.internalValue)
}
