// The inspector: any value as a Godot Tree, walked by Odin RTTI. Built lazily: a struct gets its rows when first
// expanded (until then one placeholder row gives it the expand arrow). Values update at 10 Hz, only under expanded
// rows; a row's text is set only when it changed.
//
// Arrays are lists of their live elements: a sim.Table (found by RTTI: `items` and `slots` of sim.Slot) shows the items whose
// slot is alive, any other array the elements that aren't all zero (a despawned table item is zeroed too). Rows are
// keyed by element index, so an expanded entity stays expanded while others come and go; LIST_MAX rows at most.
// Small arrays of numbers (up to 4) are one value, like a vector.
//
// Every row addresses its value relative to its parent's, so the host may pass a different pointer every frame and
// a list row can follow its element.
package devui

import "base:runtime"
import "core:fmt"
import "core:reflect"
import gd "unified:gdext"
import "unified:gdext/gdi"

@(private)
LIST_MAX :: 256

@(private)
Insp_Kind :: enum u8 {
	Leaf,
	Group, // a struct or an enumerated array: fixed children
	List, // an array or a sim.Table: its live elements
	Dead, // its row was removed
}

@(private)
List_Info :: struct {
	items:     uintptr, // the items' offset in the value (0 for a plain array)
	elem:      typeid,
	elem_size: int,
	count:     int,
	table:     bool, // a sim.Table: alive by its slots
	slots:     uintptr,
	slot_size: int,
	alive:     uintptr, // the `alive` flag's offset in sim.Slot
}

@(private)
Insp_Node :: struct {
	item:     gd.TreeItem,
	rel:      uintptr, // from the parent's address (a list row: from the list's items)
	type:     typeid,
	kind:     Insp_Kind,
	built:    bool,
	children: [dynamic]int, // Group: in order; List: rows by element index, ascending
	idx:      int, // a list row: its element
	list:     List_Info,
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
	pending: [dynamic]int, // expanded by a click: built next frame (a Tree refuses new rows inside its mouse handling)
	dirty:   bool, // refresh next frame (rows were just built)
}

@(private)
build_inspector :: proc() {
	inspector := &s.insp
	inspector.tree = gd.Tree_new()
	gd.Control_set_focus_mode(inspector.tree, .FOCUS_NONE)
	gd.Tree_set_columns(inspector.tree, 2)
	gd.Tree_set_hide_root(inspector.tree, true)
	gd.Tree_set_column_expand_ratio(inspector.tree, 0, 3)
	gd.Tree_set_column_expand_ratio(inspector.tree, 1, 2)
	gd.Tree_set_column_clip_content(inspector.tree, 0, true)
	gd.Tree_set_column_clip_content(inspector.tree, 1, true)
	inspector.top = gd.Tree_create_item(inspector.tree)
	inspector.empty = gd.Tree_create_item(inspector.tree, inspector.top)
	gd.TreeItem_set_text(inspector.empty, 0, "nothing to inspect")
	on(inspector.tree, "item_collapsed", proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
		obj, _ := gd.from_variant(gd.Object, args[0])
		if i, ok := s.insp.by_item[obj.ptr]; ok && !gd.TreeItem_is_collapsed(s.insp.nodes[i].item) {
			append(&s.insp.pending, i)
		}
		return {}
	})
	panel_make(.Inspector, "Inspector", {8, 8, 330, 420}, inspector.tree)
}

@(private)
inspector_shutdown :: proc() {
	inspector := &s.insp
	for root in inspector.roots do delete(root.name)
	for &node in inspector.nodes do delete(node.children)
	delete(inspector.roots)
	delete(inspector.nodes)
	delete(inspector.by_item)
	delete(inspector.pending)
}

@(private)
inspector_set :: proc(name: string, data: any) {
	inspector := &s.insp
	for &root in inspector.roots {
		if root.name == name && root.type == data.id {
			root.data = data.data
			root.seen = true
			return
		}
	}
	if inspector.empty.ptr != nil {
		gdi.object_destroy(inspector.empty.ptr)
		inspector.empty = {}
	}
	root := len(inspector.roots)
	append(&inspector.roots, Insp_Root {
		name = fmt.aprint(name),
		data = data.data,
		type = data.id,
		seen = true,
	})
	node_index := new_node(inspector.top, 0, data.id, name)
	inspector.roots[root].node = node_index
	gd.TreeItem_set_collapsed(inspector.nodes[node_index].item, false)
	build_children(node_index)
}

@(private)
inspector_end_frame :: proc() {
	for &root in s.insp.roots {
		if !root.seen do root.data = nil
		root.seen = false
	}
}

// Builds the rows of the items expanded since the last frame.
@(private)
inspector_build_pending :: proc() {
	inspector := &s.insp
	for i in inspector.pending do if inspector.nodes[i].kind != .Dead && !gd.TreeItem_is_collapsed(inspector.nodes[i].item) do build_children(i)
	clear(&inspector.pending)
}

@(private)
inspector_refresh :: proc() {
	inspector := &s.insp
	inspector.dirty = false
	for root in inspector.roots do if root.data != nil do refresh(root.node, uintptr(root.data))
}

@(private)
refresh :: proc(node_index: int, base: uintptr) {
	node := &s.insp.nodes[node_index]
	addr := base + node.rel
	switch node.kind {
	case .Dead:
	case .Leaf:
		buf: [64]u8
		set_value(node_index, format_value(buf[:], any{rawptr(addr), node.type}))
	case .Group:
		if !node.built || gd.TreeItem_is_collapsed(node.item) do return
		for k in 0 ..< len(node.children) do refresh(s.insp.nodes[node_index].children[k], addr)
	case .List:
		live := list_live(node.list, addr)
		set_value(node_index, fmt.tprintf("%d of %d", live, node.list.count))
		if !node.built || gd.TreeItem_is_collapsed(node.item) do return
		list_sync(node_index, addr)
		items := addr + s.insp.nodes[node_index].list.items
		for k in 0 ..< len(s.insp.nodes[node_index].children) do refresh(s.insp.nodes[node_index].children[k], items)
	}
}

// The value column, set only when it changed.
@(private)
set_value :: proc(node_index: int, text: string) {
	node := &s.insp.nodes[node_index]
	if text == string(node.text[:node.text_len]) do return
	node.text_len = u8(copy(node.text[:], text))
	gd.TreeItem_set_text(node.item, 1, text)
}

@(private)
is_live :: proc(list: List_Info, addr: uintptr, index: int) -> bool {
	if list.table do return (^bool)(addr + list.slots + uintptr(index * list.slot_size) + list.alive)^
	bytes := ([^]u8)(rawptr(addr + list.items + uintptr(index * list.elem_size)))[:list.elem_size]
	for byte in bytes do if byte != 0 do return true
	return false
}

@(private)
list_live :: proc(list: List_Info, addr: uintptr) -> (live: int) {
	for index in 0 ..< list.count do if is_live(list, addr, index) do live += 1
	return
}

// The list's rows follow its live elements (the first LIST_MAX): rows of elements that died go, new ones are
// inserted in index order, the others stay (and keep their expanded rows).
@(private)
list_sync :: proc(node_index: int, addr: uintptr) {
	inspector := &s.insp
	list := inspector.nodes[node_index].list
	row := 0 // the next existing row
	shown := 0
	for index in 0 ..< list.count {
		if shown == LIST_MAX do break
		if !is_live(list, addr, index) do continue
		for row < len(inspector.nodes[node_index].children) &&
		    inspector.nodes[inspector.nodes[node_index].children[row]].idx < index {
			row_remove(node_index, row)
		}
		if row < len(inspector.nodes[node_index].children) &&
		   inspector.nodes[inspector.nodes[node_index].children[row]].idx == index {
			row += 1
			shown += 1
			continue
		}
		child := new_node(
			inspector.nodes[node_index].item,
			uintptr(index * list.elem_size),
			list.elem,
			fmt.tprintf("[%d]", index),
			row,
		)
		if child < 0 do return // the tree refused (inside its mouse handling): next refresh
		inspector.nodes[child].idx = index
		inject_at(&inspector.nodes[node_index].children, row, child)
		row += 1
		shown += 1
	}
	for row < len(inspector.nodes[node_index].children) do row_remove(node_index, row)
}

@(private)
row_remove :: proc(node_index, row: int) {
	inspector := &s.insp
	child := inspector.nodes[node_index].children[row]
	item := inspector.nodes[child].item
	forget(child)
	gdi.object_destroy(item.ptr) // its child rows with it
	ordered_remove(&inspector.nodes[node_index].children, row)
}

// A removed row and everything under it: out of the item map, marked dead.
@(private)
forget :: proc(node_index: int) {
	inspector := &s.insp
	for child in inspector.nodes[node_index].children do forget(child)
	delete_key(&inspector.by_item, inspector.nodes[node_index].item.ptr)
	delete(inspector.nodes[node_index].children)
	inspector.nodes[node_index] = {
		kind = .Dead,
	}
}

// A node and its tree row (at `position` among its siblings, -1: last); a group or list gets a placeholder child
// so it shows the expand arrow. -1 when the tree refuses the row.
@(private)
new_node :: proc(parent: gd.TreeItem, rel: uintptr, type: typeid, label: string, position := -1) -> int {
	inspector := &s.insp
	kind, list := classify(type)
	item := gd.Tree_create_item(inspector.tree, parent, position)
	if item.ptr == nil do return -1
	gd.TreeItem_set_text(item, 0, label)
	gd.TreeItem_set_selectable(item, 0, false)
	gd.TreeItem_set_selectable(item, 1, false)
	if kind != .Leaf {
		gd.Tree_create_item(inspector.tree, item)
		gd.TreeItem_set_collapsed(item, true)
		gd.TreeItem_set_custom_color(item, 1, DIM)
	} else {
		gd.TreeItem_set_custom_color(item, 0, DIM)
		gd.TreeItem_set_custom_font(item, 1, s.mono)
	}
	node_index := len(inspector.nodes)
	append(&inspector.nodes, Insp_Node {
		item = item,
		rel  = rel,
		type = type,
		kind = kind,
		list = list,
	})
	inspector.by_item[item.ptr] = node_index
	return node_index
}

@(private)
classify :: proc(type: typeid) -> (kind: Insp_Kind, list: List_Info) {
	base := runtime.type_info_base(type_info_of(type))
	#partial switch info in base.variant {
	case runtime.Type_Info_Struct:
		if table, ok := table_info(type); ok do return .List, table
		return .Group, {}
	case runtime.Type_Info_Array:
		if small_vector(info.elem, info.count) do return .Leaf, {}
		return .List, {
			elem      = info.elem.id,
			elem_size = info.elem_size,
			count     = info.count,
		}
	case runtime.Type_Info_Enumerated_Array:
		if small_vector(info.elem, info.count) do return .Leaf, {}
		return .Group, {}
	}
	return .Leaf, {}
}

// A sim.Table: `items: [N]T` and `slots: [N]sim.Slot` (matched by name: importing sim here would make vet flag sim's
// imports that only its generics use).
@(private)
table_info :: proc(type: typeid) -> (list: List_Info, ok: bool) {
	items := reflect.struct_field_by_name(type, "items")
	slots := reflect.struct_field_by_name(type, "slots")
	if items.type == nil || slots.type == nil do return
	items_array, items_ok := runtime.type_info_base(items.type).variant.(runtime.Type_Info_Array)
	slots_array, slots_ok := runtime.type_info_base(slots.type).variant.(runtime.Type_Info_Array)
	named, named_ok := slots_array.elem.variant.(runtime.Type_Info_Named)
	if !items_ok || !slots_ok || !named_ok || named.name != "Slot" || named.pkg != "sim" || slots_array.count != items_array.count do return
	alive := reflect.struct_field_by_name(slots_array.elem.id, "alive")
	if alive.type == nil do return
	return {
			items     = items.offset,
			elem      = items_array.elem.id,
			elem_size = items_array.elem_size,
			count     = items_array.count,
			table     = true,
			slots     = slots.offset,
			slot_size = slots_array.elem_size,
			alive     = alive.offset,
		}, true
}

// Up to 4 numbers or booleans: shown as one value.
@(private)
small_vector :: proc(elem: ^runtime.Type_Info, count: int) -> bool {
	if count > 4 do return false
	#partial switch _ in runtime.type_info_base(elem).variant {
	case runtime.Type_Info_Float, runtime.Type_Info_Integer, runtime.Type_Info_Boolean:
		return true
	}
	return false
}

@(private)
build_children :: proc(node_index: int) {
	inspector := &s.insp
	if inspector.nodes[node_index].built || inspector.nodes[node_index].kind == .Dead do return
	node := inspector.nodes[node_index]
	// drop the placeholder row
	if placeholder := gd.TreeItem_get_first_child(node.item); placeholder.ptr != nil do gdi.object_destroy(placeholder.ptr)
	inspector.nodes[node_index].built = true
	inspector.dirty = true
	if node.kind != .Group do return // a list's rows come with the next refresh
	base := runtime.type_info_base(type_info_of(node.type))
	#partial switch info in base.variant {
	case runtime.Type_Info_Struct:
		for field in reflect.struct_fields_zipped(node.type) {
			child := new_node(node.item, field.offset, field.type.id, field.name)
			if child >= 0 do append(&inspector.nodes[node_index].children, child)
		}
	case runtime.Type_Info_Enumerated_Array:
		for index in 0 ..< info.count {
			name := fmt.tprintf("[%d]", index)
			if enum_info, ok := runtime.type_info_base(info.index).variant.(runtime.Type_Info_Enum); ok && index < len(enum_info.names) do name = enum_info.names[index]
			child := new_node(node.item, uintptr(index * info.elem_size), info.elem.id, name)
			if child >= 0 do append(&inspector.nodes[node_index].children, child)
		}
	}
}

@(private)
format_value :: proc(buf: []u8, value: any) -> string {
	base := runtime.type_info_base(type_info_of(value.id))
	#partial switch info in base.variant {
	case runtime.Type_Info_Float:
		return fmt.bprintf(buf, "%.3f", value)
	case runtime.Type_Info_Enum:
		if name, ok := reflect.enum_name_from_value_any(value); ok do return fmt.bprint(buf, name)
	case runtime.Type_Info_Array:
		if _, is_float := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Float);
		   is_float && info.elem.size == 4 {
			return fmt.bprintf(buf, "%.3f", ([^]f32)(value.data)[:info.count])
		}
	}
	return fmt.bprint(buf, value)
}
