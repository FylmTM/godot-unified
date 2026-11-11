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
	n := &s.insp
	n.tree = gd.Tree_new()
	gd.Control_set_focus_mode(n.tree, .FOCUS_NONE)
	gd.Tree_set_columns(n.tree, 2)
	gd.Tree_set_hide_root(n.tree, true)
	gd.Tree_set_column_expand_ratio(n.tree, 0, 3)
	gd.Tree_set_column_expand_ratio(n.tree, 1, 2)
	gd.Tree_set_column_clip_content(n.tree, 0, true)
	gd.Tree_set_column_clip_content(n.tree, 1, true)
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
	for &node in n.nodes do delete(node.children)
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
	i := new_node(n.top, 0, data.id, name)
	n.roots[root].node = i
	gd.TreeItem_set_collapsed(n.nodes[i].item, false)
	build_children(i)
}

@(private)
inspector_end_frame :: proc() {
	for &r in s.insp.roots {
		if !r.seen do r.data = nil
		r.seen = false
	}
}

// Builds the rows of the items expanded since the last frame.
@(private)
inspector_build_pending :: proc() {
	n := &s.insp
	for i in n.pending do if n.nodes[i].kind != .Dead && !gd.TreeItem_is_collapsed(n.nodes[i].item) do build_children(i)
	clear(&n.pending)
}

@(private)
inspector_refresh :: proc() {
	n := &s.insp
	n.dirty = false
	for r in n.roots do if r.data != nil do refresh(r.node, uintptr(r.data))
}

@(private)
refresh :: proc(i: int, base: uintptr) {
	n := &s.insp.nodes[i]
	addr := base + n.rel
	switch n.kind {
	case .Dead:
	case .Leaf:
		buf: [64]u8
		set_value(i, format_value(buf[:], any{rawptr(addr), n.type}))
	case .Group:
		if !n.built || gd.TreeItem_is_collapsed(n.item) do return
		for k in 0 ..< len(n.children) do refresh(s.insp.nodes[i].children[k], addr)
	case .List:
		live := list_live(n.list, addr)
		set_value(i, fmt.tprintf("%d of %d", live, n.list.count))
		if !n.built || gd.TreeItem_is_collapsed(n.item) do return
		list_sync(i, addr)
		items := addr + s.insp.nodes[i].list.items
		for k in 0 ..< len(s.insp.nodes[i].children) do refresh(s.insp.nodes[i].children[k], items)
	}
}

// The value column, set only when it changed.
@(private)
set_value :: proc(i: int, text: string) {
	n := &s.insp.nodes[i]
	if text == string(n.text[:n.text_len]) do return
	n.text_len = u8(copy(n.text[:], text))
	gd.TreeItem_set_text(n.item, 1, text)
}

@(private)
is_live :: proc(l: List_Info, addr: uintptr, idx: int) -> bool {
	if l.table do return (^bool)(addr + l.slots + uintptr(idx * l.slot_size) + l.alive)^
	bytes := ([^]u8)(rawptr(addr + l.items + uintptr(idx * l.elem_size)))[:l.elem_size]
	for b in bytes do if b != 0 do return true
	return false
}

@(private)
list_live :: proc(l: List_Info, addr: uintptr) -> (n: int) {
	for idx in 0 ..< l.count do if is_live(l, addr, idx) do n += 1
	return
}

// The list's rows follow its live elements (the first LIST_MAX): rows of elements that died go, new ones are
// inserted in index order, the others stay (and keep their expanded rows).
@(private)
list_sync :: proc(i: int, addr: uintptr) {
	n := &s.insp
	l := n.nodes[i].list
	r := 0 // the next existing row
	shown := 0
	for idx in 0 ..< l.count {
		if shown == LIST_MAX do break
		if !is_live(l, addr, idx) do continue
		for r < len(n.nodes[i].children) && n.nodes[n.nodes[i].children[r]].idx < idx {
			row_remove(i, r)
		}
		if r < len(n.nodes[i].children) && n.nodes[n.nodes[i].children[r]].idx == idx {
			r += 1
			shown += 1
			continue
		}
		c := new_node(n.nodes[i].item, uintptr(idx * l.elem_size), l.elem, fmt.tprintf("[%d]", idx), r)
		if c < 0 do return // the tree refused (inside its mouse handling): next refresh
		n.nodes[c].idx = idx
		inject_at(&n.nodes[i].children, r, c)
		r += 1
		shown += 1
	}
	for r < len(n.nodes[i].children) do row_remove(i, r)
}

@(private)
row_remove :: proc(i, r: int) {
	n := &s.insp
	c := n.nodes[i].children[r]
	item := n.nodes[c].item
	forget(c)
	gdi.object_destroy(item.ptr) // its child rows with it
	ordered_remove(&n.nodes[i].children, r)
}

// A removed row and everything under it: out of the item map, marked dead.
@(private)
forget :: proc(i: int) {
	n := &s.insp
	for c in n.nodes[i].children do forget(c)
	delete_key(&n.by_item, n.nodes[i].item.ptr)
	delete(n.nodes[i].children)
	n.nodes[i] = {
		kind = .Dead,
	}
}

// A node and its tree row (at `position` among its siblings, -1: last); a group or list gets a placeholder child
// so it shows the expand arrow. -1 when the tree refuses the row.
@(private)
new_node :: proc(parent: gd.TreeItem, rel: uintptr, type: typeid, label: string, position := -1) -> int {
	n := &s.insp
	kind, list := classify(type)
	item := gd.Tree_create_item(n.tree, parent, position)
	if item.ptr == nil do return -1
	gd.TreeItem_set_text(item, 0, label)
	gd.TreeItem_set_selectable(item, 0, false)
	gd.TreeItem_set_selectable(item, 1, false)
	if kind != .Leaf {
		gd.Tree_create_item(n.tree, item)
		gd.TreeItem_set_collapsed(item, true)
		gd.TreeItem_set_custom_color(item, 1, DIM)
	} else {
		gd.TreeItem_set_custom_color(item, 0, DIM)
		gd.TreeItem_set_custom_font(item, 1, s.mono)
	}
	i := len(n.nodes)
	append(&n.nodes, Insp_Node{item = item, rel = rel, type = type, kind = kind, list = list})
	n.by_item[item.ptr] = i
	return i
}

@(private)
classify :: proc(type: typeid) -> (kind: Insp_Kind, list: List_Info) {
	ti := runtime.type_info_base(type_info_of(type))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Struct:
		if l, ok := table_info(type); ok do return .List, l
		return .Group, {}
	case runtime.Type_Info_Array:
		if small_vector(info.elem, info.count) do return .Leaf, {}
		return .List, {elem = info.elem.id, elem_size = info.elem_size, count = info.count}
	case runtime.Type_Info_Enumerated_Array:
		if small_vector(info.elem, info.count) do return .Leaf, {}
		return .Group, {}
	}
	return .Leaf, {}
}

// A sim.Table: `items: [N]T` and `slots: [N]sim.Slot` (matched by name: importing sim here would make vet flag sim's
// imports that only its generics use).
@(private)
table_info :: proc(type: typeid) -> (l: List_Info, ok: bool) {
	items := reflect.struct_field_by_name(type, "items")
	slots := reflect.struct_field_by_name(type, "slots")
	if items.type == nil || slots.type == nil do return
	it, ok1 := runtime.type_info_base(items.type).variant.(runtime.Type_Info_Array)
	st, ok2 := runtime.type_info_base(slots.type).variant.(runtime.Type_Info_Array)
	named, ok3 := st.elem.variant.(runtime.Type_Info_Named)
	if !ok1 || !ok2 || !ok3 || named.name != "Slot" || named.pkg != "sim" || st.count != it.count do return
	alive := reflect.struct_field_by_name(st.elem.id, "alive")
	if alive.type == nil do return
	return {
			items = items.offset,
			elem = it.elem.id,
			elem_size = it.elem_size,
			count = it.count,
			table = true,
			slots = slots.offset,
			slot_size = st.elem_size,
			alive = alive.offset,
		},
		true
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
build_children :: proc(i: int) {
	n := &s.insp
	if n.nodes[i].built || n.nodes[i].kind == .Dead do return
	node := n.nodes[i]
	// drop the placeholder row
	if ph := gd.TreeItem_get_first_child(node.item); ph.ptr != nil do gdi.object_destroy(ph.ptr)
	n.nodes[i].built = true
	n.dirty = true
	if node.kind != .Group do return // a list's rows come with the next refresh
	ti := runtime.type_info_base(type_info_of(node.type))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Struct:
		for f in reflect.struct_fields_zipped(node.type) {
			c := new_node(node.item, f.offset, f.type.id, f.name)
			if c >= 0 do append(&n.nodes[i].children, c)
		}
	case runtime.Type_Info_Enumerated_Array:
		for e in 0 ..< info.count {
			name := fmt.tprintf("[%d]", e)
			if en, ok := runtime.type_info_base(info.index).variant.(runtime.Type_Info_Enum); ok && e < len(en.names) do name = en.names[e]
			c := new_node(node.item, uintptr(e * info.elem_size), info.elem.id, name)
			if c >= 0 do append(&n.nodes[i].children, c)
		}
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
		if _, is_float := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Float);
		   is_float && info.elem.size == 4 {
			return fmt.bprintf(buf, "%.3f", ([^]f32)(v.data)[:info.count])
		}
	}
	return fmt.bprint(buf, v)
}
