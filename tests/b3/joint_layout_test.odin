// The joint mirrors (src/b3/joint_types.odin) beyond their layouts (layout_test.odin's PAIRS): Joint_Type's members
// are the library's, by name and value, and a default def through b3 reads as the library's own.
package test_b3

import "base:runtime"
import "core:mem"
import "core:testing"

import box3d "box3d:bindings"
import "unified:b3"


@(test)
joint_type_members_match :: proc(t: ^testing.T) {
	ours := runtime.type_info_base(type_info_of(b3.Joint_Type)).variant.(runtime.Type_Info_Enum)
	theirs := runtime.type_info_base(type_info_of(box3d.JointType)).variant.(runtime.Type_Info_Enum)
	if !testing.expect_value(t, len(ours.names), len(theirs.names)) do return
	for name, i in theirs.names {
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

// Each scalar of a default def made through b3 equals the library's default (scalar by scalar: padding bytes are
// unspecified).
@(test)
joint_default_defs_are_the_librarys :: proc(t: ^testing.T) {
	expect_same_scalars :: proc(t: ^testing.T, ours: ^$Ours, theirs: ^$Theirs) {
		scalars := make([dynamic]Scalar, context.temp_allocator)
		flatten(type_info_of(Ours), 0, &scalars)
		our_bytes := ([^]u8)(ours)
		their_bytes := ([^]u8)(theirs)
		for scalar in scalars {
			size := int(scalar.kind[1] - '0')
			testing.expectf(
				t,
				mem.compare(our_bytes[scalar.offset:][:size], their_bytes[scalar.offset:][:size]) == 0,
				"%v: the scalar at %d differs",
				typeid_of(Ours),
				scalar.offset,
			)
		}
	}
	{
		ours, theirs := b3.default_distance_joint_def(), box3d.DefaultDistanceJointDef()
		expect_same_scalars(t, &ours, &theirs)
	}
	{
		ours, theirs := b3.default_filter_joint_def(), box3d.DefaultFilterJointDef()
		expect_same_scalars(t, &ours, &theirs)
	}
	{
		ours, theirs := b3.default_parallel_joint_def(), box3d.DefaultParallelJointDef()
		expect_same_scalars(t, &ours, &theirs)
	}
	{
		ours, theirs := b3.default_prismatic_joint_def(), box3d.DefaultPrismaticJointDef()
		expect_same_scalars(t, &ours, &theirs)
	}
	{
		ours, theirs := b3.default_revolute_joint_def(), box3d.DefaultRevoluteJointDef()
		expect_same_scalars(t, &ours, &theirs)
	}
	{
		ours, theirs := b3.default_spherical_joint_def(), box3d.DefaultSphericalJointDef()
		expect_same_scalars(t, &ours, &theirs)
	}
	{
		ours, theirs := b3.default_weld_joint_def(), box3d.DefaultWeldJointDef()
		expect_same_scalars(t, &ours, &theirs)
	}
	{
		ours, theirs := b3.default_wheel_joint_def(), box3d.DefaultWheelJointDef()
		expect_same_scalars(t, &ours, &theirs)
	}
}
