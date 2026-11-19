// The sim's debug draws on screen (dev UI builds; src/godot/README.md, Debug draws): the shown tick's shapes as one
// line mesh under view_root (3D: a RenderingServer instance with an unshaded, always-on-top material, texts as Label3D
// billboards; 2D: a canvas item on top, texts drawn with a system font), rebuilt on every fresh frame, in view space.
// Which groups are kept is the union of the dev UI's toggles and UnifiedSession.debug_draw (`--draw`); the mask goes
// to the session thread (draw_mask), which applies it to the sim before each step.
#+private
package godot

import "base:runtime"
import "core:math"
import "core:strings"
import "core:sync"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"

when DEVUI {
	Draw_View :: struct {
		root_id:   u64, // the view_root drawn under (0: none)
		mode:      Root_Mode,
		mesh:      gd.RID, // 3D
		instance:  gd.RID,
		shader:    gd.RID,
		material:  gd.RID,
		canvas:    gd.RID, // 2D
		font:      gd.Ref(gd.SystemFont),
		labels:    [dynamic]Draw_Label, // the 3D texts' billboards under the root, reused
		count:     int, // shapes shown (UnifiedSession.debug_draw_count)
		names:     [sim.DEBUG_GROUPS]string, // the groups' names, the main thread's copy
		names_seq: u32,
		wanted:    string, // UnifiedSession.debug_draw
	}

	Draw_Label :: struct {
		node: gd.Label3D,
		id:   u64,
	}

	draw_view: Draw_View

	DRAW_SHADER :: "shader_type spatial;\nrender_mode unshaded, depth_test_disabled, cull_disabled;\nvoid fragment() {\n\tALBEDO = COLOR.rgb;\n}\n"
	CIRCLE_SEGMENTS :: 24
	DRAW_FONT_SIZE :: 12

	// Main thread, every frame: the groups to keep (to the session thread) and, on a fresh frame, the shown tick's
	// draws under `root`.
	debug_draw_sync :: proc(root: gd.Node, frame: ^Frame_Data, fresh: bool) {
		draw_mask_update()
		if root.ptr == nil || frame == nil {
			debug_draw_clear()
			return
		}
		root_id := gdi.object_get_instance_id(root.ptr)
		if root_id != draw_view.root_id {
			debug_draw_clear()
			draw_view.root_id = root_id
			switch {
			case gd.object_cast(gd.Node3D, root).ptr != nil:
				draw_view.mode = .Node3D
			case gd.object_cast(gd.Node2D, root).ptr != nil:
				draw_view.mode = .Node2D
			case:
				draw_view.mode = .Other
			}
		}
		if !fresh || draw_view.mode == .Other do return
		shapes := frame.draws[:frame.n_draws]
		if len(shapes) == 0 && draw_view.count == 0 do return
		draw_view.count = len(shapes)
		lines := make([dynamic][3]f32, context.temp_allocator)
		colors := make([dynamic]gd.Color, context.temp_allocator)
		texts := make([dynamic]sim.Debug_Shape, context.temp_allocator)
		for shape in shapes {
			if shape.kind == .Text {
				append(&texts, shape)
				continue
			}
			before := len(lines)
			shape_lines(&lines, shape, draw_view.mode == .Node2D)
			color := color_of(shape.color)
			for _ in before ..< len(lines) do append(&colors, color)
		}
		for &point in lines do point = to_view_units(point)
		if draw_view.mode == .Node3D {
			draw_3d(gd.cast_to(gd.Node3D, root), lines[:], colors[:], texts[:], frame.draw_text[:frame.n_draw_text])
		} else {
			draw_2d(root, lines[:], colors[:], texts[:], frame.draw_text[:frame.n_draw_text])
		}
	}

	// Frees what the draws hold (a new view_root, the session's end, the extension unloading).
	debug_draw_clear :: proc() {
		rendering_server := gd.RenderingServer_singleton()
		for &rid in ([]^gd.RID{&draw_view.instance, &draw_view.mesh, &draw_view.material, &draw_view.shader, &draw_view.canvas}) {
			if rid^ != {} do gd.RenderingServer_free_rid(rendering_server, rid^)
			rid^ = {}
		}
		for label in draw_view.labels do if alive(label.id) do gd.Node_queue_free(label.node)
		delete(draw_view.labels)
		draw_view.labels = nil
		if draw_view.font.ptr != nil do gd.unref(draw_view.font)
		draw_view.font = {}
		draw_view.root_id, draw_view.count = 0, 0
	}

	// The line segments (pairs of points, sim units) that draw a shape.
	shape_lines :: proc(lines: ^[dynamic][3]f32, shape: sim.Debug_Shape, flat: bool) {
		segment :: proc(lines: ^[dynamic][3]f32, a, b: [3]f32) {append(lines, a, b)}
		circle :: proc(lines: ^[dynamic][3]f32, centre, u, v: [3]f32, radius: f32) {
			previous := centre + u * radius
			for i in 1 ..= CIRCLE_SEGMENTS {
				angle := f32(i) * math.TAU / CIRCLE_SEGMENTS
				next := centre + (u * math.cos(angle) + v * math.sin(angle)) * radius
				segment(lines, previous, next)
				previous = next
			}
		}
		X, Y, Z :: [3]f32{1, 0, 0}, [3]f32{0, 1, 0}, [3]f32{0, 0, 1}
		switch shape.kind {
		case .Line:
			segment(lines, shape.a, shape.b)
		case .Point:
			half := max(shape.size, 0.02) / 2
			segment(lines, shape.a - X * half, shape.a + X * half)
			segment(lines, shape.a - Y * half, shape.a + Y * half)
			if !flat do segment(lines, shape.a - Z * half, shape.a + Z * half)
		case .Sphere:
			circle(lines, shape.a, X, Y, shape.size)
			if !flat {
				circle(lines, shape.a, X, Z, shape.size)
				circle(lines, shape.a, Y, Z, shape.size)
			}
		case .Capsule:
			axis := shape.b - shape.a
			length := math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
			if length < 1e-6 {
				shape := shape
				shape.kind = .Sphere
				shape_lines(lines, shape, flat)
				return
			}
			dir := axis / length
			side := abs(dir.y) < 0.9 ? Y : X
			u := normalize3(cross3(dir, side))
			v := cross3(dir, u)
			if flat do u, v = normalize3({-dir.y, dir.x, 0}), {}
			for end in ([2][3]f32{shape.a, shape.b}) {
				circle(lines, end, u, flat ? dir : v, shape.size)
				if !flat do circle(lines, end, u, dir, shape.size)
			}
			for offset in ([]([3]f32){u, -u, v, -v}) {
				if offset == {} do continue
				segment(lines, shape.a + offset * shape.size, shape.b + offset * shape.size)
			}
		case .Box:
			rot := shape.rot == {} ? IDENTITY : shape.rot
			corner :: proc(centre, half: [3]f32, rot: [4]f32, signs: [3]f32) -> [3]f32 {
				return centre + rotate(rot, half * signs)
			}
			if flat {
				signs := [4][3]f32{{-1, -1, 0}, {1, -1, 0}, {1, 1, 0}, {-1, 1, 0}}
				for i in 0 ..< 4 {
					segment(
						lines,
						corner(shape.a, shape.b, rot, signs[i]),
						corner(shape.a, shape.b, rot, signs[(i + 1) % 4]),
					)
				}
				return
			}
			for i in 0 ..< 8 {
				signs := [3]f32{i & 1 == 0 ? -1 : 1, i & 2 == 0 ? -1 : 1, i & 4 == 0 ? -1 : 1}
				for axis in 0 ..< 3 {
					if signs[axis] > 0 do continue // each edge once, from its lower end
					other := signs
					other[axis] = 1
					segment(lines, corner(shape.a, shape.b, rot, signs), corner(shape.a, shape.b, rot, other))
				}
			}
		case .Text:
		}
	}

	cross3 :: proc(a, b: [3]f32) -> [3]f32 {
		return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
	}

	normalize3 :: proc(vec: [3]f32) -> [3]f32 {
		size := length(vec)
		return size > 1e-9 ? vec / size : {}
	}

	// A vector turned by a unit quaternion.
	rotate :: proc(q: [4]f32, vec: [3]f32) -> [3]f32 {
		u := [3]f32{q.x, q.y, q.z}
		t := 2 * cross3(u, vec)
		return vec + q.w * t + cross3(u, t)
	}

	color_of :: proc(rgb: u32) -> gd.Color {
		return {f32((rgb >> 16) & 0xff) / 255, f32((rgb >> 8) & 0xff) / 255, f32(rgb & 0xff) / 255, 1}
	}

	draw_3d :: proc(root: gd.Node3D, lines: [][3]f32, colors: []gd.Color, texts: []sim.Debug_Shape, text_bytes: []u8) {
		rendering_server := gd.RenderingServer_singleton()
		if draw_view.mesh == {} {
			draw_view.mesh = gd.RenderingServer_mesh_create(rendering_server)
			draw_view.shader = gd.RenderingServer_shader_create(rendering_server)
			gd.RenderingServer_shader_set_code(rendering_server, draw_view.shader, DRAW_SHADER)
			draw_view.material = gd.RenderingServer_material_create(rendering_server)
			gd.RenderingServer_material_set_shader(rendering_server, draw_view.material, draw_view.shader)
			draw_view.instance = gd.RenderingServer_instance_create(rendering_server)
			gd.RenderingServer_instance_set_base(rendering_server, draw_view.instance, draw_view.mesh)
			gd.RenderingServer_instance_geometry_set_material_override(
				rendering_server,
				draw_view.instance,
				draw_view.material,
			)
			world := gd.Node3D_get_world_3d(root)
			if world.ptr != nil {
				gd.RenderingServer_instance_set_scenario(
					rendering_server,
					draw_view.instance,
					gd.World3D_get_scenario(world),
				)
				gd.unref(world)
			}
		}
		gd.RenderingServer_instance_set_transform(
			rendering_server,
			draw_view.instance,
			gd.Node3D_get_global_transform(root),
		)
		gd.RenderingServer_mesh_clear(rendering_server, draw_view.mesh)
		if len(lines) > 0 {
			vertices := gd.PackedVector3Array_new0()
			defer gd.PackedVector3Array_destroy(&vertices)
			gd.PackedVector3Array_resize(&vertices, len(lines))
			copy(([^][3]f32)(gdi.packed_vector3_array_operator_index(&vertices, 0))[:len(lines)], lines)
			packed_colors := gd.PackedColorArray_new0()
			defer gd.PackedColorArray_destroy(&packed_colors)
			gd.PackedColorArray_resize(&packed_colors, len(colors))
			copy(([^]gd.Color)(gdi.packed_color_array_operator_index(&packed_colors, 0))[:len(colors)], colors)
			arrays := gd.array_new()
			defer gd.Array_destroy(&arrays)
			gd.Array_resize(&arrays, int(gd.RenderingServer_ArrayType.ARRAY_MAX))
			vertex_variant, color_variant := gd.to_variant(vertices), gd.to_variant(packed_colors)
			gd.Array_set(&arrays, int(gd.RenderingServer_ArrayType.ARRAY_VERTEX), vertex_variant)
			gd.Array_set(&arrays, int(gd.RenderingServer_ArrayType.ARRAY_COLOR), color_variant)
			gd.variant_destroy(&vertex_variant)
			gd.variant_destroy(&color_variant)
			blend_shapes := gd.array_new()
			defer gd.Array_destroy(&blend_shapes)
			lods := gd.dict_new()
			defer gd.Dictionary_destroy(&lods)
			gd.RenderingServer_mesh_add_surface_from_arrays(
				rendering_server,
				draw_view.mesh,
				.PRIMITIVE_LINES,
				arrays,
				blend_shapes,
				lods,
			)
		}
		// texts: a pool of billboards under the root, always on top
		for i in 0 ..< max(len(texts), len(draw_view.labels)) {
			if i >= len(draw_view.labels) {
				label := gd.Label3D_new()
				gd.Label3D_set_billboard_mode(label, 1) // BILLBOARD_ENABLED
				gd.Label3D_set_draw_flag(label, .FLAG_DISABLE_DEPTH_TEST, true)
				gd.Label3D_set_draw_flag(label, .FLAG_FIXED_SIZE, true)
				gd.Label3D_set_pixel_size(label, 0.0015)
				gd.Label3D_set_font_size(label, DRAW_FONT_SIZE * 2)
				gd.Label3D_set_outline_size(label, 4)
				gd.Node_add_child(root, label, false, .INTERNAL_MODE_FRONT)
				append(&draw_view.labels, Draw_Label{label, gdi.object_get_instance_id(label.ptr)})
			}
			entry := draw_view.labels[i]
			if !alive(entry.id) do continue
			label := entry.node
			if i >= len(texts) {
				gd.Node3D_set_visible(label, false)
				continue
			}
			text := texts[i]
			gd.Label3D_set_text(label, string(text_bytes[text.text[1]:][:text.text[0]]))
			gd.Label3D_set_modulate(label, color_of(text.color))
			pos := to_view_units(text.a)
			gd.Node3D_set_position(label, {pos.x, pos.y, pos.z})
			gd.Node3D_set_visible(label, true)
		}
	}

	draw_2d :: proc(root: gd.Node, lines: [][3]f32, colors: []gd.Color, texts: []sim.Debug_Shape, text_bytes: []u8) {
		rendering_server := gd.RenderingServer_singleton()
		if draw_view.canvas == {} {
			draw_view.canvas = gd.RenderingServer_canvas_item_create(rendering_server)
			gd.RenderingServer_canvas_item_set_parent(
				rendering_server,
				draw_view.canvas,
				gd.CanvasItem_get_canvas_item(gd.cast_to(gd.CanvasItem, root)),
			)
			gd.RenderingServer_canvas_item_set_z_index(rendering_server, draw_view.canvas, 4000)
			draw_view.font = gd.SystemFont_new()
		}
		gd.RenderingServer_canvas_item_clear(rendering_server, draw_view.canvas)
		if len(lines) > 0 {
			points := gd.PackedVector2Array_new0()
			defer gd.PackedVector2Array_destroy(&points)
			gd.PackedVector2Array_resize(&points, len(lines))
			flat := ([^]gd.Vector2)(gdi.packed_vector2_array_operator_index(&points, 0))
			for point, i in lines do flat[i] = {point.x, point.y}
			packed_colors := gd.PackedColorArray_new0()
			defer gd.PackedColorArray_destroy(&packed_colors)
			gd.PackedColorArray_resize(&packed_colors, len(colors) / 2)
			// canvas_item_add_multiline takes one colour per segment
			per_segment := ([^]gd.Color)(gdi.packed_color_array_operator_index(&packed_colors, 0))
			for i in 0 ..< len(colors) / 2 do per_segment[i] = colors[2 * i]
			gd.RenderingServer_canvas_item_add_multiline(rendering_server, draw_view.canvas, points, packed_colors)
		}
		for text in texts {
			pos := to_view_units(text.a)
			gd.Font_draw_string(
				draw_view.font,
				draw_view.canvas,
				{pos.x, pos.y},
				string(text_bytes[text.text[1]:][:text.text[0]]),
				font_size = DRAW_FONT_SIZE,
				modulate = color_of(text.color),
			)
		}
	}

	// UnifiedSession.debug_draw.
	debug_draw_wanted :: proc() -> string {return draw_view.wanted}
	debug_draw_want :: proc(groups: string) {
		delete(draw_view.wanted, runtime.heap_allocator())
		draw_view.wanted = strings.clone(groups, runtime.heap_allocator())
	}
	// UnifiedSession.debug_draw_count.
	debug_draw_count :: proc() -> int {return draw_view.count}

	// The groups to keep: the dev UI's toggles and UnifiedSession.debug_draw ("all", or group names, comma-separated),
	// to the session thread.
	draw_mask_update :: proc() {
		if seq := sync.atomic_load(&draw_groups.seq); seq != draw_view.names_seq {
			draw_view.names_seq = seq
			sync.guard(&draw_groups.mu)
			for &name, i in draw_view.names {
				if name == draw_groups.names[i] do continue
				delete(name, runtime.heap_allocator())
				name = strings.clone(draw_groups.names[i], runtime.heap_allocator())
			}
		}
		mask := dev_draw_toggles(draw_view.names[:])
		if draw_view.wanted != "" {
			for want in strings.split(draw_view.wanted, ",", context.temp_allocator) {
				name := strings.trim_space(want)
				for group, i in draw_view.names {
					if group != "" && (name == "all" || name == group) do mask |= 1 << uint(i)
				}
			}
		}
		sync.atomic_store(&draw_mask, mask)
	}
} else {
	_ :: runtime
	_ :: math
	_ :: strings
	_ :: sync
	_ :: gdi
	_ :: sim

	debug_draw_sync :: proc(root: gd.Node, frame: ^Frame_Data, fresh: bool) {}
	debug_draw_wanted :: proc() -> string {return ""}
	debug_draw_want :: proc(groups: string) {}
	debug_draw_count :: proc() -> int {return 0}
	debug_draw_clear :: proc() {}
}
