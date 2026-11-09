// The windows: menu bar, overlay (stats and graphs), RTTI inspector, netsim, event log, F3 note.
package devui

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:time"
import gd "unified:gdext"
import imgui "unified:imgui"

@(private)
draw_panels :: proc() {
	if imgui.BeginMainMenuBar() {
		imgui.TextUnformatted("unified dev  (F1 hide, F3 note)")
		imgui.Separator()
		imgui.MenuItemBoolPtr("Inspector", nil, &s.show.inspector)
		imgui.MenuItemBoolPtr("Netsim", nil, &s.show.netsim)
		imgui.MenuItemBoolPtr("Events", nil, &s.show.events)
		imgui.MenuItemBoolPtr("ImGui demo", nil, &s.show.demo)
		imgui.EndMainMenuBar()
	}
	overlay()
	if s.show.inspector do inspector()
	if s.show.netsim do netsim_panel()
	if s.show.events do event_log()
	note_panel()
	if s.show.demo do imgui.ShowDemoWindow(&s.show.demo)
}

@(private)
place :: proc(r: [4]f32) {
	imgui.SetNextWindowPos({r.x, r.y}, .FirstUseEver)
	imgui.SetNextWindowSize({r.z, r.w}, .FirstUseEver)
}

@(private)
overlay :: proc() {
	place({8, 30, 300, 0})
	flags: imgui.WindowFlags = {.NoTitleBar, .NoResize, .NoScrollbar, .NoSavedSettings, .AlwaysAutoResize}
	defer imgui.End()
	if !imgui.Begin("Overlay", nil, flags) do return
	imgui.TextUnformatted(fmt.ctprintf("frame %.1f ms  ui %.2f ms", s.frame_ms, s.ui_ms))
	for line in s.stats do imgui.TextUnformatted(fmt.ctprint(line))
	w := max(imgui.GetContentRegionAvail().x, 200)
	for &g in s.graphs {
		vals: [GRAPH_LEN]f32
		for i in 0 ..< GRAPH_LEN do vals[i] = g.values[(g.head + i) % GRAPH_LEN]
		lo, hi := g.min, g.max
		if lo == hi do lo, hi = max(f32), max(f32) // auto scale
		label := fmt.ctprintf("%s %.1f", g.name, g.last)
		imgui.PlotLines(fmt.ctprintf("##%s", g.name), &vals[0], GRAPH_LEN, 0, label, lo, hi, {w, 36})
	}
}

// ---- inspector: a generic editor driven by Odin RTTI

@(private)
inspector :: proc() {
	place({8, 200, 360, 460})
	defer imgui.End()
	if !imgui.Begin("Inspector", &s.show.inspector) do return
	if len(s.inspected) == 0 do imgui.TextUnformatted("nothing to inspect (devui.inspect)")
	for &it in s.inspected {
		imgui.SetNextItemOpen(true, .Once)
		if imgui.TreeNode(fmt.ctprint(it.name)) {
			imgui.BeginDisabled(!it.editable)
			edit_value(it.data, "")
			imgui.EndDisabled()
			imgui.TreePop()
		}
	}
}

// Arrays longer than this show their elements through a list clipper, one tree node each.
@(private)
BIG_ARRAY :: 16

@(private)
edit_value :: proc(v: any, name: string) {
	imgui.PushIDPtr(v.data)
	defer imgui.PopID()
	label := fmt.ctprint(name)
	ti := runtime.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Struct:
		if name != "" {
			if !imgui.TreeNode(label) do return
			defer imgui.TreePop()
		}
		for f in reflect.struct_fields_zipped(v.id) {
			edit_value(any{rawptr(uintptr(v.data) + f.offset), f.type.id}, f.name)
		}
	case runtime.Type_Info_Array:
		edit_array(v.data, info.elem, info.elem_size, info.count, name)
	case runtime.Type_Info_Enumerated_Array:
		edit_array(v.data, info.elem, info.elem_size, info.count, name)
	case runtime.Type_Info_Float:
		imgui.SetNextItemWidth(-120)
		if ti.size == 4 do imgui.DragFloat(label, (^f32)(v.data), 0.05)
		else do imgui.TextUnformatted(fmt.ctprintf("%s  %v", name, v))
	case runtime.Type_Info_Integer:
		imgui.SetNextItemWidth(-120)
		x := i32(reflect.as_i64(v) or_else 0)
		if imgui.DragInt(label, &x) do set_int(v, i64(x))
	case runtime.Type_Info_Boolean:
		imgui.Checkbox(label, (^bool)(v.data))
	case runtime.Type_Info_Enum:
		imgui.SetNextItemWidth(-120)
		cur := reflect.as_i64(v) or_else 0
		if imgui.BeginCombo(label, fmt.ctprint(enum_name(v))) {
			for e, j in info.values {
				if imgui.Selectable(fmt.ctprint(info.names[j]), i64(e) == cur) {
					set_int(any{v.data, info.base.id}, i64(e))
				}
			}
			imgui.EndCombo()
		}
	case:
		imgui.TextUnformatted(fmt.ctprintf("%s  %v", name, v))
	}
}

@(private)
edit_array :: proc(data: rawptr, elem: ^runtime.Type_Info, elem_size, count: int, name: string) {
	base := runtime.type_info_base(elem)
	// small vectors of scalars: one line
	if count <= 4 {
		if _, is_f := base.variant.(runtime.Type_Info_Float); is_f && base.size == 4 {
			imgui.SetNextItemWidth(-120)
			label := fmt.ctprint(name)
			switch count {
			case 2:
				imgui.DragFloat2(label, (^[2]f32)(data), 0.05)
			case 3:
				imgui.DragFloat3(label, (^[3]f32)(data), 0.05)
			case 4:
				imgui.DragFloat4(label, (^[4]f32)(data), 0.05)
			case:
				imgui.DragFloat(label, (^f32)(data), 0.05)
			}
			return
		}
	}
	if !imgui.TreeNode(fmt.ctprintf("%s [%d]", name, count)) do return
	defer imgui.TreePop()
	clip: imgui.ListClipper
	imgui.ListClipper_Begin(&clip, i32(count))
	defer imgui.ListClipper_End(&clip)
	for imgui.ListClipper_Step(&clip) {
		for i in clip.DisplayStart ..< clip.DisplayEnd {
			p := rawptr(uintptr(data) + uintptr(int(i) * elem_size))
			edit_value(any{p, elem.id}, fmt.tprintf("[%d]", i))
		}
	}
}

@(private)
enum_name :: proc(v: any) -> string {
	if n, ok := reflect.enum_name_from_value_any(v); ok do return n
	return fmt.tprint(reflect.as_i64(v) or_else 0)
}

@(private)
set_int :: proc(v: any, x: i64) {
	switch type_info_of(v.id).size {
	case 1:
		(^i8)(v.data)^ = i8(x)
	case 2:
		(^i16)(v.data)^ = i16(x)
	case 4:
		(^i32)(v.data)^ = i32(x)
	case 8:
		(^i64)(v.data)^ = x
	}
}

// ---- netsim

@(private)
netsim_panel :: proc() {
	place({380, 30, 300, 200})
	defer imgui.End()
	if !imgui.Begin("Netsim", &s.show.netsim) do return
	n := &netsim
	before := n^
	imgui.PushItemWidth(-100)
	imgui.Checkbox("enabled", &n.enabled)
	imgui.SliderFloat("latency", &n.latency_ms, 0, 300, "%.0f ms")
	imgui.SliderFloat("jitter", &n.jitter_ms, 0, 50, "%.0f ms")
	imgui.SliderFloat("loss", &n.loss_pct, 0, 20, "%.1f %%")
	imgui.PopItemWidth()
	if imgui.Button("LAN") do n^ = {true, 2, 1, 0}
	imgui.SameLine()
	if imgui.Button("WAN") do n^ = {true, 60, 10, 1}
	imgui.SameLine()
	if imgui.Button("Bad Wi-Fi") do n^ = {true, 140, 40, 6}
	imgui.SameLine()
	if imgui.Button("Off") do n.enabled = false
	if n^ != before do netsim_changed = true
}

// ---- event log

@(private)
event_log :: proc() {
	place({8, 670, 520, 220})
	defer imgui.End()
	if !imgui.Begin("Events", &s.show.events) do return
	imgui.Checkbox("follow", &s.log_follow)
	imgui.SameLine()
	imgui.TextUnformatted(fmt.ctprintf("%d events", s.log_n))
	flags: imgui.TableFlags = {.ScrollY, .RowBg, .BordersOuterH, .BordersOuterV, .BordersInnerV, .Resizable}
	if !imgui.BeginTable("log", 2, flags) do return
	defer imgui.EndTable()
	imgui.TableSetupScrollFreeze(0, 1)
	imgui.TableSetupColumn("tick", {.WidthFixed}, 60)
	imgui.TableSetupColumn("event")
	imgui.TableHeadersRow()
	n := min(s.log_n, LOG_ROWS)
	first := s.log_n - n
	clip: imgui.ListClipper
	imgui.ListClipper_Begin(&clip, i32(n))
	for imgui.ListClipper_Step(&clip) {
		for i in clip.DisplayStart ..< clip.DisplayEnd {
			r := &s.logs[(first + int(i)) % LOG_ROWS]
			imgui.TableNextRow()
			imgui.TableNextColumn()
			imgui.TextUnformatted(fmt.ctprint(r.tick))
			imgui.TableNextColumn()
			imgui.TextUnformatted(fmt.ctprint(string(r.msg[:r.len])))
		}
	}
	imgui.ListClipper_End(&clip)
	if s.log_follow && imgui.GetScrollY() < imgui.GetScrollMaxY() do imgui.SetScrollHereY(1)
}

// ---- F3 feedback note

@(private)
Note :: struct {
	open:    bool,
	focus:   bool,
	text:    [1024]u8,
	tag_bug: bool,
	sent:    int,
	png:     string, // screenshot of this note, in the temp dir until sent
	tex:     gd.Ref(gd.ImageTexture),
	rid:     gd.RID,
	w, h:    int,
}

@(private)
note_open :: proc() {
	n := &s.note
	// Capture before the UI covers the frame (the viewport still shows last frame's UI, if any).
	tex: gd.Ref(gd.ViewportTexture) = gd.Viewport_get_texture(s.root)
	defer gd.unref(tex)
	img := gd.Texture2D_get_image(tex)
	defer gd.unref(img)
	if img.ptr == nil do return
	delete(n.png)
	n.png = fmt.aprintf("%s/devui-f3-%d.png", gd.OS_get_cache_dir(gd.OS_singleton()), time.now()._nsec)
	gd.Image_save_png(img, n.png)
	w := gd.Image_get_width(img)
	h := gd.Image_get_height(img)
	n.w = 320
	n.h = 320 * h / max(w, 1)
	gd.Image_resize(img, n.w, n.h)
	if n.tex.ptr == nil {
		n.tex = gd.ImageTexture_create_from_image(img)
	} else {
		gd.ImageTexture_set_image(n.tex, img)
	}
	n.rid = gd.Resource_get_rid(n.tex)
	n.open = true
	n.focus = true
	visible = true
}

@(private)
note_shutdown :: proc() {
	if s.note.tex.ptr != nil do gd.unref(s.note.tex)
	delete(s.note.png)
}

@(private)
note_panel :: proc() {
	n := &s.note
	if !n.open do return
	place({s.size.x / 2 - 180, 80, 360, 0})
	defer imgui.End()
	if !imgui.Begin("Feedback (F3)", &n.open, {.AlwaysAutoResize}) do return
	if n.tex.ptr != nil do imgui.Image({_TexID = transmute(imgui.TextureID)n.rid}, {f32(n.w), f32(n.h)})
	imgui.TextUnformatted("What happened? (Enter sends, Ctrl+Enter = new line)")
	if n.focus {
		imgui.SetKeyboardFocusHere()
		n.focus = false
	}
	if imgui.InputTextMultiline(
		"##note",
		cstring(&n.text[0]),
		len(n.text),
		{320, 80},
		{.EnterReturnsTrue, .CtrlEnterForNewLine},
	) {
		note_send()
	}
	imgui.Checkbox("tag as bug", &n.tag_bug)
	if imgui.Button("Send", {100, 0}) do note_send()
	imgui.SameLine()
	if imgui.Button("Cancel", {100, 0}) do n.open = false
	if n.sent > 0 {
		imgui.SameLine()
		imgui.TextUnformatted(fmt.ctprintf("sent: %d", n.sent))
	}
}

@(private)
note_send :: proc() {
	n := &s.note
	text := string(cstring(&n.text[0]))
	stamp := time.now()
	y, mo, d := time.date(stamp)
	hh, mm, ss := time.clock(stamp)
	dir := fmt.tprintf("%s/%04d%02d%02d-%02d%02d%02d", s.cfg.feedback_dir, y, int(mo), d, hh, mm, ss)
	if err := os.make_directory_all(dir); err != nil {
		gd.print_error(fmt.tprintf("devui: cannot create %s: %v", dir, err))
		return
	}
	if n.png != "" do os.rename(n.png, fmt.tprintf("%s/screenshot.png", dir))
	body := fmt.tprintf("%s\n%s", n.tag_bug ? "[bug]" : "[note]", text)
	_ = os.write_entire_file(fmt.tprintf("%s/note.txt", dir), transmute([]u8)body)
	if s.cfg.on_feedback != nil do s.cfg.on_feedback(dir, text, n.tag_bug, s.cfg.user)
	gd.print(fmt.tprintf("devui: feedback saved to %s", dir))
	n.sent += 1
	n.text = {}
	n.open = false
	delete(n.png)
	n.png = ""
}
