// The mirrors of src/b3/types_more.odin against the bindings, scalar for scalar (layout_test.odin's method), and
// Shape_Type's members, by name and value.
package test_b3

import "base:runtime"
import "core:testing"

import box3d "box3d:bindings"
import "unified:b3"

MORE_PAIRS := []Pair {
	{b3.Shape_Type, box3d.ShapeType, false},
	{b3.Matrix3, box3d.Matrix3, false},
	{b3.Mass_Data, box3d.MassData, false},
	{b3.Plane, box3d.Plane, false},
	{b3.Explosion_Def, box3d.ExplosionDef, false},
	{b3.Manifold_Point, box3d.ManifoldPoint, false},
	{b3.Manifold, box3d.Manifold, false},
	{b3.Contact_Data, box3d.ContactData, false},
	{b3.Body_Move_Event, box3d.BodyMoveEvent, false},
	{b3.Joint_Event, box3d.JointEvent, false},
	{b3.Mesh_Def, box3d.MeshDef, false},
	{b3.Mesh, box3d.Mesh, false},
	{b3.Height_Field_Def, box3d.HeightFieldDef, false},
	{b3.Compound_Capsule_Def, box3d.CompoundCapsuleDef, false},
	{b3.Compound_Hull_Def, box3d.CompoundHullDef, false},
	{b3.Compound_Mesh_Def, box3d.CompoundMeshDef, false},
	{b3.Compound_Sphere_Def, box3d.CompoundSphereDef, false},
	{b3.Compound_Def, box3d.CompoundDef, false},
	{b3.Cast_Output, box3d.CastOutput, true},
	{b3.Body_Cast_Result, box3d.BodyCastResult, true},
	{b3.Plane_Result, box3d.PlaneResult, false},
	{b3.Body_Plane_Result, box3d.BodyPlaneResult, false},
	{b3.Body_TOI_Result, box3d.BodyTOIResult, false},
}

@(test)
more_mirrors_match_the_bindings :: proc(t: ^testing.T) {
	for pair in MORE_PAIRS {
		ours := type_info_of(pair.ours)
		theirs := type_info_of(pair.theirs)
		our_scalars := make([dynamic]Scalar, context.temp_allocator)
		their_scalars := make([dynamic]Scalar, context.temp_allocator)
		flatten(ours, 0, &our_scalars)
		flatten(theirs, 0, &their_scalars)
		if pair.prefix {
			// Ours leaves out `hit`, the binding's last field.
			testing.expectf(t, ours.size <= theirs.size, "%v is larger than %v", pair.ours, pair.theirs)
			testing.expectf(
				t,
				len(their_scalars) == len(our_scalars) + 1,
				"%v: one scalar fewer than %v",
				pair.ours,
				pair.theirs,
			)
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

// Shape_Type's members are the library's, by name (camelCase to Ada_Case) and value, but its last (shapeTypeCount, a
// count, not a shape type).
@(test)
shape_type_members_match :: proc(t: ^testing.T) {
	ours := runtime.type_info_base(type_info_of(b3.Shape_Type)).variant.(runtime.Type_Info_Enum)
	theirs := runtime.type_info_base(type_info_of(box3d.ShapeType)).variant.(runtime.Type_Info_Enum)
	if !testing.expect_value(t, len(ours.names), len(theirs.names) - 1) do return
	testing.expect_value(t, theirs.names[len(theirs.names) - 1], "shapeTypeCount")
	for name, i in theirs.names[:len(ours.names)] {
		ada := make([dynamic]u8, context.temp_allocator)
		for char, k in transmute([]u8)name {
			if k == 0 {
				append(&ada, char - 'a' + 'A')
			} else if char >= 'A' && char <= 'Z' {
				append(&ada, '_', char)
			} else {
				append(&ada, char)
			}
		}
		testing.expect_value(t, ours.names[i], string(ada[:]))
		testing.expect_value(t, ours.values[i], theirs.values[i])
	}
}
