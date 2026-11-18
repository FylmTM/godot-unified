// `Unified.level_markers(root)`: a level's markers in the order its .level file holds them (src/level/SPEC.md), so a
// view keyed by a marker index finds that marker's node. The rule is the exporter's (src/godot/tools/level_export.gd
// `_collect` and `_kind`), which keeps its own GDScript copy (it runs in projects without the extension);
// tests/godot_views/markers_check.gd proves the two agree.
#+private
package godot

import gd "unified:gdext"
import "unified:gdext/gdi"

// The nodes under `root` (itself included) that declare a marker kind, depth-first, parents before children: an
// Array[Node] the caller owns.
level_markers :: proc(root: gd.Node) -> gd.Array {
	markers := gd.array_new()
	gd.array_set_typed(&markers, .OBJECT, "Node")
	walk :: proc(node: gd.Node, markers: ^gd.Array) {
		if marker_kind(node) != "" do gd.array_push(markers, node)
		for i in 0 ..< gd.Node_get_child_count(node, false) do walk(gd.Node_get_child(node, i, false), markers)
	}
	if root.ptr != nil do walk(root, &markers)
	return markers
}

// The marker kind a node declares ("": none), the first of: its script's `UNIFIED_KIND` constant, a `unified_kind`
// property, `unified_kind` metadata; as GDScript's str() reads it.
marker_kind :: proc(node: gd.Node) -> string {
	KIND :: "unified_kind"
	script_variant := gd.Object_get_script(node)
	defer gd.variant_destroy(&script_variant)
	if script, _ := gd.from_variant(gd.Object, &script_variant); script.ptr != nil {
		constants_variant := gd.Object_call(script, "get_script_constant_map")
		defer gd.variant_destroy(&constants_variant)
		if constants, ok := gd.from_variant(gd.Dictionary, &constants_variant); ok {
			defer gd.Dictionary_destroy(&constants)
			key := gd.to_variant("UNIFIED_KIND")
			defer gd.variant_destroy(&key)
			if gd.Dictionary_has(&constants, key) {
				value := gd.Dictionary_get(&constants, key, gd.variant_nil())
				defer gd.variant_destroy(&value)
				return variant_text(&value)
			}
		}
	}
	// `"unified_kind" in node`: a property the object (its class or script) answers
	node_variant := gd.to_variant(node)
	defer gd.variant_destroy(&node_variant)
	value: gd.Variant
	valid: gdi.Bool
	gdi.variant_get_named(&node_variant, gd.sn(KIND), &value, &valid)
	defer gd.variant_destroy(&value)
	if valid != 0 do return variant_text(&value)
	if gd.Object_has_meta(node, gd.sn(KIND)) {
		meta := gd.Object_get_meta(node, gd.sn(KIND), gd.variant_nil())
		defer gd.variant_destroy(&meta)
		return variant_text(&meta)
	}
	return ""
}

// A Variant as GDScript's str() writes it (temp allocator).
variant_text :: proc(value: ^gd.Variant) -> string {
	text: gd.String
	gdi.variant_stringify(value, &text)
	defer gd.String_destroy(&text)
	return gd.string_to_odin(&text)
}
