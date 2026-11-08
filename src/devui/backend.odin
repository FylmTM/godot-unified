// Dear ImGui -> Godot: ImDrawData becomes RenderingServer canvas items (one pooled child item per draw command,
// clipped to its ClipRect), and ImGui 1.92's dynamic textures map to RenderingServer 2D textures.
// Godot traps (from the spike): canvas children sort by draw_index with an unstable sort, so each pooled item
// gets an explicit index; canvas_item_clear resets the clip flag, so it is set again after every clear.
package devui

import "base:runtime"
import "core:mem"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"
import imgui "unified:imgui"

@(private)
FONT_TTF :: #load("fonts/OpenSans-SemiBold.ttf")
@(private)
FONT_SIZE :: 17 // ImGui sizes fonts by line height

@(private)
Backend :: struct {
	rs:        gd.RenderingServer,
	root:      gd.RID,
	items:     [dynamic]gd.RID,
	used:      int,
	prev_used: int,
	// scratch arrays reused for every draw command (the RenderingServer copies them)
	indices:   gd.PackedInt32Array,
	points:    gd.PackedVector2Array,
	colors:    gd.PackedColorArray,
	uvs:       gd.PackedVector2Array,
	bones:     gd.PackedInt32Array,
	weights:   gd.PackedFloat32Array,
	clip_text: cstring,
}

@(private)
b: Backend

@(private)
backend_init :: proc() {
	imgui.CHECKVERSION()
	imgui.CreateContext()
	io := imgui.GetIO()
	io.IniFilename = nil
	io.ConfigFlags += {.DockingEnable}
	io.BackendFlags += {.RendererHasTextures, .RendererHasVtxOffset}
	io.BackendRendererName = "unified-godot"
	pio := imgui.GetPlatformIO()
	pio.PlatformSetClipboardTextFn = proc "c" (_: ^imgui.Context, text: cstring) {
		context = runtime.default_context()
		gd.DisplayServer_clipboard_set(gd.DisplayServer_singleton(), string(text))
	}
	pio.PlatformGetClipboardTextFn = proc "c" (_: ^imgui.Context) -> cstring {
		context = runtime.default_context()
		delete(b.clip_text)
		b.clip_text = strings.clone_to_cstring(gd.DisplayServer_clipboard_get(gd.DisplayServer_singleton()))
		return b.clip_text
	}
	// the atlas owns (and frees) its copy of the TTF
	data := imgui.MemAlloc(len(FONT_TTF))
	mem.copy(data, raw_data(FONT_TTF), len(FONT_TTF))
	imgui.FontAtlas_AddFontFromMemoryTTF(io.Fonts, data, i32(len(FONT_TTF)), FONT_SIZE)
	style_init()

	b.rs = gd.RenderingServer_singleton()
	b.root = gd.RenderingServer_canvas_item_create(b.rs)
	gd.RenderingServer_canvas_item_set_parent(b.rs, b.root, s.canvas)
	b.indices = gd.PackedInt32Array_new0()
	b.points = gd.PackedVector2Array_new0()
	b.colors = gd.PackedColorArray_new0()
	b.uvs = gd.PackedVector2Array_new0()
	b.bones = gd.PackedInt32Array_new0()
	b.weights = gd.PackedFloat32Array_new0()
}

@(private)
backend_shutdown :: proc() {
	for tex in textures() {
		if tex.TexID != 0 do gd.RenderingServer_free_rid(b.rs, transmute(gd.RID)tex.TexID)
	}
	imgui.DestroyContext()
	for it in b.items do gd.RenderingServer_free_rid(b.rs, it)
	gd.RenderingServer_free_rid(b.rs, b.root)
	delete(b.items)
	gd.PackedInt32Array_destroy(&b.indices)
	gd.PackedVector2Array_destroy(&b.points)
	gd.PackedColorArray_destroy(&b.colors)
	gd.PackedVector2Array_destroy(&b.uvs)
	gd.PackedInt32Array_destroy(&b.bones)
	gd.PackedFloat32Array_destroy(&b.weights)
	delete(b.clip_text)
	b = {}
}

@(private)
style_init :: proc() {
	imgui.StyleColorsDark()
	st := imgui.GetStyle()
	st.WindowRounding = 4
	st.FrameRounding = 3
	st.GrabRounding = 3
	st.WindowPadding = {8, 8}
	st.FramePadding = {6, 3}
	st.ItemSpacing = {6, 4}
	st.Colors[imgui.Col.WindowBg].w = 0.92
}

// Hidden: draw nothing (keeps the pooled items for the next show).
@(private)
backend_hide :: proc() {
	for i in 0 ..< b.prev_used do gd.RenderingServer_canvas_item_clear(b.rs, b.items[i])
	b.prev_used = 0
}

// ---- textures (ImGui 1.92: the backend creates/updates/destroys what the atlas asks for)

@(private)
textures :: proc() -> []^imgui.TextureData {
	t := &imgui.GetPlatformIO().Textures
	return t.Data[:t.Size]
}

@(private)
update_texture :: proc(tex: ^imgui.TextureData) {
	#partial switch tex.Status {
	case .WantCreate, .WantUpdates:
		// Re-upload the whole texture: it changes only when new glyphs are rasterised.
		n := int(tex.Width * tex.Height * tex.BytesPerPixel)
		bytes := gd.PackedByteArray_new0()
		defer gd.PackedByteArray_destroy(&bytes)
		gd.PackedByteArray_resize(&bytes, n)
		mem.copy(gdi.packed_byte_array_operator_index(&bytes, 0), tex.Pixels, n)
		format: gd.Image_Format = tex.Format == .RGBA32 ? .FORMAT_RGBA8 : .FORMAT_L8
		img := gd.Image_create_from_data(int(tex.Width), int(tex.Height), false, format, bytes)
		defer gd.unref(img)
		if tex.Status == .WantCreate {
			rid := gd.RenderingServer_texture_2d_create(b.rs, img)
			imgui.TextureData_SetTexID(tex, transmute(imgui.TextureID)rid)
		} else {
			gd.RenderingServer_texture_2d_update(b.rs, transmute(gd.RID)tex.TexID, img, 0)
		}
		imgui.TextureData_SetStatus(tex, .OK)
	case .WantDestroy:
		if tex.UnusedFrames > 0 {
			gd.RenderingServer_free_rid(b.rs, transmute(gd.RID)tex.TexID)
			imgui.TextureData_SetTexID(tex, 0)
			imgui.TextureData_SetStatus(tex, .Destroyed)
		}
	}
}

// ---- draw data -> canvas items

@(private)
next_item :: proc(clip: gd.Rect2) -> gd.RID {
	if b.used == len(b.items) {
		it := gd.RenderingServer_canvas_item_create(b.rs)
		gd.RenderingServer_canvas_item_set_parent(b.rs, it, b.root)
		gd.RenderingServer_canvas_item_set_draw_index(b.rs, it, len(b.items)) // keep submission order
		append(&b.items, it)
	}
	it := b.items[b.used]
	b.used += 1
	gd.RenderingServer_canvas_item_clear(b.rs, it) // also resets the clip flag
	gd.RenderingServer_canvas_item_set_clip(b.rs, it, true)
	gd.RenderingServer_canvas_item_set_custom_rect(b.rs, it, true, clip)
	return it
}

@(private)
render :: proc(dd: ^imgui.DrawData) {
	if dd.Textures != nil {
		for tex in dd.Textures.Data[:dd.Textures.Size] do if tex.Status != .OK do update_texture(tex)
	}
	fb := dd.FramebufferScale
	off := dd.DisplayPos
	b.used = 0
	for list in dd.CmdLists.Data[:dd.CmdLists.Size] {
		vtx := list.VtxBuffer.Data[:list.VtxBuffer.Size]
		idx := list.IdxBuffer.Data[:list.IdxBuffer.Size]
		for &cmd in list.CmdBuffer.Data[:list.CmdBuffer.Size] {
			if cmd.UserCallback != nil || cmd.ElemCount == 0 do continue
			c := cmd.ClipRect
			x0, y0 := (c.x - off.x) * fb.x, (c.y - off.y) * fb.y
			x1, y1 := (c.z - off.x) * fb.x, (c.w - off.y) * fb.y
			if x1 <= x0 || y1 <= y0 do continue
			// copy only the vertices this command uses, rebasing its indices
			ids := idx[cmd.IdxOffset:][:cmd.ElemCount]
			lo, hi := max(u32), u32(0)
			for i in ids {
				lo = min(lo, u32(i))
				hi = max(hi, u32(i))
			}
			verts := vtx[cmd.VtxOffset + lo:][:hi - lo + 1]
			gd.PackedInt32Array_resize(&b.indices, len(ids))
			gd.PackedVector2Array_resize(&b.points, len(verts))
			gd.PackedColorArray_resize(&b.colors, len(verts))
			gd.PackedVector2Array_resize(&b.uvs, len(verts))
			pi := ([^]i32)(gdi.packed_int32_array_operator_index(&b.indices, 0))
			pp := ([^]gd.Vector2)(gdi.packed_vector2_array_operator_index(&b.points, 0))
			pc := ([^]gd.Color)(gdi.packed_color_array_operator_index(&b.colors, 0))
			pu := ([^]gd.Vector2)(gdi.packed_vector2_array_operator_index(&b.uvs, 0))
			for i, j in ids do pi[j] = i32(u32(i) - lo)
			for v, j in verts {
				pp[j] = {(v.pos.x - off.x) * fb.x, (v.pos.y - off.y) * fb.y}
				pu[j] = {v.uv.x, v.uv.y}
				col := v.col
				pc[j] = {
					f32(col & 0xff) / 255,
					f32((col >> 8) & 0xff) / 255,
					f32((col >> 16) & 0xff) / 255,
					f32(col >> 24) / 255,
				}
			}
			item := next_item({{x0, y0}, {x1 - x0, y1 - y0}})
			tex := transmute(gd.RID)imgui.DrawCmd_GetTexID(&cmd)
			gd.RenderingServer_canvas_item_add_triangle_array(
				b.rs,
				item,
				b.indices,
				b.points,
				b.colors,
				b.uvs,
				b.bones,
				b.weights,
				tex,
				-1,
			)
		}
	}
	for i in b.used ..< b.prev_used do gd.RenderingServer_canvas_item_clear(b.rs, b.items[i])
	b.prev_used = b.used
}
