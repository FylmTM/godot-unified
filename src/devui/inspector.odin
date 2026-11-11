// The inspector: any value as a Godot Tree, walked by Odin RTTI. Built lazily: a struct or array gets its rows
// when first expanded (until then one placeholder row gives it the expand arrow), arrays longer than CHUNK in
// chunks of CHUNK. Values update at 10 Hz, and only rows under expanded items are read and formatted; a row's
// text is set only when it changed. Nodes address values by offset from the inspected value, so the host may
// pass a different pointer every frame.
package devui

import "base:runtime"
import "core:fmt"
import "core:reflect"
import gd "unified:gdext"
import "unified:gdext/gdi"

@(private)
CHUNK :: 64

@(private)
Insp_Kind :: enum u8 {
	Leaf,
	Group, // struct or array: children are fields or elements (or chunks)
	Chunk, // CHUNK elements of a long array
}

@(private)
Insp_Node :: struct {
	item:     gd.TreeItem,
	root:     int,
	offset:   uintptr, // from the inspected value
	type:     typeid, // Chunk: the element type
	kind:     Insp_Kind,
	built:    bool,
	first:    int, // children: nodes[first:][:count], contiguous
	count:    int,
	lo, hi:   int, // Chunk: elements lo ..< hi
	text_len: u8,
	text:     [63]u8,
}

@(private)
Insp_Root :: struct {
	name: string,
	data: rawptr, // nil when not inspected this frame
	type: typeid,
	node: int,
	seen: bool,
}

@(private)
Inspector :: struct {
	tree:    gd.Tree,
	top:     gd.TreeItem,
	empty:   gd.TreeItem, // "nothing to inspect", until a root exists
	roots:   [dynamic]Insp_Root,
	nodes:   [dynamic]Insp_Node,
	by_item: map[rawptr]int,
	dirty:   bool, // refresh next frame (rows were just built)
	pending: [dynamic]int, // expanded by a click: built next frame (a Tree refuses new rows inside its own mouse handling)
}

@(private)
build_inspector :: proc() {
	n := &s.insp
	n.tree = gd.Tree_new()
	gd.Control_set_focus_mode(n.tree, .FOCUS_NONE)
	gd.Tree_set_columns(n.tree, 2)
	gd.Tree_set_hide_root(n.tree, true)
	gd.Tree_set_column_expand_ratio(n.tree, 0, 3)
	gd.Tree_set_column_expand_ratio(n.tree, 1, 2)
	gd.Tree_set_column_clip_content(n.tree, 1, true)
	gd.Tree_set_column_clip_content(n.tree, 0, true)
	n.top = gd.Tree_create_item(n.tree)
	n.empty = gd.Tree_create_item(n.tree, n.top)
	gd.TreeItem_set_text(n.empty, 0, "nothing to inspect")
	on(n.tree, "item_collapsed", proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
		obj, _ := gd.from_variant(gd.Object, args[0])
		if i, ok := s.insp.by_item[obj.ptr]; ok && !gd.TreeItem_is_collapsed(s.insp.nodes[i].item) {
			append(&s.insp.pending, i)
		}
		return {}
	})
	panel_make(.Inspector, "Inspector", {8, 8, 330, 420}, n.tree)
}

@(private)
inspector_shutdown :: proc() {
	n := &s.insp
	for r in n.roots do delete(r.name)
	delete(n.roots)
	delete(n.nodes)
	delete(n.by_item)
	delete(n.pending)
}

@(private)
inspector_set :: proc(name: string, data: any) {
	n := &s.insp
	for &r in n.roots {
		if r.name == name && r.type == data.id {
			r.data = data.data
			r.seen = true
			return
		}
	}
	if n.empty.ptr != nil {
		gdi.object_destroy(n.empty.ptr)
		n.empty = {}
	}
	root := len(n.roots)
	append(&n.roots, Insp_Root{name = fmt.aprint(name), data = data.data, type = data.id, seen = true})
	n.roots[root].node = new_node(n.top, root, 0, data.id, name)
	gd.TreeItem_set_collapsed(n.nodes[n.roots[root].node].item, false)
	build_children(n.roots[root].node)
}

@(private)
inspector_end_frame :: proc() {
	for &r in s.insp.roots {
		if !r.seen do r.data = nil
		r.seen = false
	}
}

@(private)
inspector_refresh :: proc() {
	n := &s.insp
	n.dirty = false
	for r in n.roots do if r.data != nil do refresh(r.node, r.data)
}

@(private)
refresh :: proc(i: int, base: rawptr) {
	n := &s.insp.nodes[i]
	if n.kind != .Leaf {
		if !n.built || gd.TreeItem_is_collapsed(n.item) do return
		for c in n.first ..< n.first + n.count do refresh(c, base)
		return
	}
	buf: [64]u8
	text := format_value(buf[:], any{rawptr(uintptr(base) + n.offset), n.type})
	if text == string(n.text[:n.text_len]) do return
	k := copy(n.text[:], text)
	n.text_len = u8(k)
	gd.TreeItem_set_text(n.item, 1, text)
}

// A node and its tree row; a group gets a placeholder child so it shows the expand arrow.
@(private)
new_node :: proc(parent: gd.TreeItem, root: int, offset: uintptr, type: typeid, label: string) -> int {
	n := &s.insp
	kind := classify(type)
	item := gd.Tree_create_item(n.tree, parent)
	gd.TreeItem_set_text(item, 0, label)
	gd.TreeItem_set_selectable(item, 0, false)
	gd.TreeItem_set_selectable(item, 1, false)
	if kind != .Leaf {
		gd.Tree_create_item(n.tree, item)
		gd.TreeItem_set_collapsed(item, true)
	} else {
		gd.TreeItem_set_custom_color(item, 0, DIM)
		gd.TreeItem_set_custom_font(item, 1, s.mono)
	}
	i := len(n.nodes)
	append(&n.nodes, Insp_Node{item = item, root = root, offset = offset, type = type, kind = kind})
	n.by_item[item.ptr] = i
	return i
}

@(private)
classify :: proc(type: typeid) -> Insp_Kind {
	ti := runtime.type_info_base(type_info_of(type))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Struct:
		return .Group
	case runtime.Type_Info_Array:
		return small_vector(info.elem, info.count) ? .Leaf : .Group
	case runtime.Type_Info_Enumerated_Array:
		return small_vector(info.elem, info.count) ? .Leaf : .Group
	}
	return .Leaf
}

@(private)
small_vector :: proc(elem: ^runtime.Type_Info, count: int) -> bool {
	_, is_float := runtime.type_info_base(elem).variant.(runtime.Type_Info_Float)
	return is_float && count <= 4
}

@(private)
build_children :: proc(i: int) {
	n := &s.insp
	if n.nodes[i].built do return
	node := n.nodes[i]
	// drop the placeholder row
	if ph := gd.TreeItem_get_first_child(node.item); ph.ptr != nil do gdi.object_destroy(ph.ptr)
	first := len(n.nodes)
	if node.kind == .Chunk {
		size := uintptr(type_info_of(node.type).size)
		for e in node.lo ..< node.hi {
			new_node(node.item, node.root, node.offset + uintptr(e) * size, node.type, fmt.tprintf("[%d]", e))
		}
	} else {
		ti := runtime.type_info_base(type_info_of(node.type))
		#partial switch info in ti.variant {
		case runtime.Type_Info_Struct:
			for f in reflect.struct_fields_zipped(node.type) {
				new_node(node.item, node.root, node.offset + f.offset, f.type.id, f.name)
			}
		case runtime.Type_Info_Array:
			array_children(i, info.elem, info.count)
		case runtime.Type_Info_Enumerated_Array:
			array_children(i, info.elem, info.count)
		}
	}
	n.nodes[i].built = true
	n.nodes[i].first = first
	n.nodes[i].count = len(n.nodes) - first
	n.dirty = true
}

@(private)
array_children :: proc(i: int, elem: ^runtime.Type_Info, count: int) {
	n := &s.insp
	node := n.nodes[i]
	gd.TreeItem_set_text(node.item, 1, fmt.tprintf("[%d]", count))
	if count <= CHUNK {
		for e in 0 ..< count {
			new_node(node.item, node.root, node.offset + uintptr(e * elem.size), elem.id, fmt.tprintf("[%d]", e))
		}
		return
	}
	for lo := 0; lo < count; lo += CHUNK {
		hi := min(lo + CHUNK, count)
		item := gd.Tree_create_item(n.tree, node.item)
		gd.TreeItem_set_text(item, 0, fmt.tprintf("[%d .. %d]", lo, hi - 1))
		gd.Tree_create_item(n.tree, item)
		gd.TreeItem_set_collapsed(item, true)
		c := len(n.nodes)
		append(
			&n.nodes,
			Insp_Node {
				item = item,
				root = node.root,
				offset = node.offset,
				type = elem.id,
				kind = .Chunk,
				lo = lo,
				hi = hi,
			},
		)
		n.by_item[item.ptr] = c
	}
}

@(private)
format_value :: proc(buf: []u8, v: any) -> string {
	ti := runtime.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Float:
		return fmt.bprintf(buf, "%.3f", v)
	case runtime.Type_Info_Enum:
		if name, ok := reflect.enum_name_from_value_any(v); ok do return fmt.bprint(buf, name)
	case runtime.Type_Info_Array:
		if info.count <= 4 && info.elem.size == 4 {
			f := ([^]f32)(v.data)[:info.count]
			return fmt.bprintf(buf, "%.3f", f)
		}
	}
	return fmt.bprint(buf, v)
}

// SPIKE: expands rows of the first inspected value along `path` (row labels; "*" = every child), for the stress
// measurement in games/survivor/game/tools/devui_spike.gd.
debug_expand :: proc(path: []string) {
	if len(s.insp.roots) == 0 do return
	expand_path(s.insp.roots[0].node, path)
}

@(private)
expand_path :: proc(i: int, path: []string) {
	if s.insp.nodes[i].kind == .Leaf do return
	build_children(i)
	gd.TreeItem_set_collapsed(s.insp.nodes[i].item, false)
	if len(path) == 0 do return
	first, count := s.insp.nodes[i].first, s.insp.nodes[i].count
	for c in first ..< first + count {
		if path[0] == "*" || gd.TreeItem_get_text(s.insp.nodes[c].item, 0) == path[0] do expand_path(c, path[1:])
	}
}

// Builds the rows of the items expanded since the last frame.
@(private)
inspector_build_pending :: proc() {
	n := &s.insp
	for i in n.pending do if !gd.TreeItem_is_collapsed(n.nodes[i].item) do build_children(i)
	clear(&n.pending)
}
