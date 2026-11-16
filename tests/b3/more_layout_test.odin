// The mirrors of src/b3/types_more.odin beyond their layouts (layout_test.odin's PAIRS): Shape_Type's members, by
// name and value.
package test_b3

import "base:runtime"
import "core:testing"

import box3d "box3d:bindings"
import "unified:b3"


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
