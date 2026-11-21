// Immediate mode (experimental: the render experiment, examples/horde_*): a game draws the shown tick itself, from the
// State, every rendered frame on the main thread (Glue.draw), with no views. It draws into layers (RenderingServer
// canvas items under the session's root, cleared every frame) and quad batches (one MultiMesh and shader each, whose
// buffer is written in one call per frame), moves the camera itself, reads the mouse and keys, and sends commands.
// Events come as the game's union (Glue.event), and Glue.no_script_events skips the GDScript object per event state.
//
// All of it is main-thread only, and nothing here makes a Godot object per frame: layers, batches and the scratch
// arrays live for the process.
package godot

import "base:runtime"
import "core:math"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"

// What Glue.draw gets: the shown tick's state and the tick before (the same state when none), how far the screen is
// between them, and the frame's real time.
Draw :: struct($G: typeid) {
	state:         ^sim.part(G, sim.GAME_STATE), // the newest predicted tick
	prev:          ^sim.part(G, sim.GAME_STATE), // the tick before it (after a rollback, the corrected one)
	tick:          u32,
	alpha:         f32, // 0..1: the screen's place between prev (0) and state (1); a locked view ignores it
	dt:            f32, // real seconds since the last frame
	time_s:        f64, // real seconds since the first draw (cosmetic animation)
	fresh:         bool, // a tick new since the last draw
	seed:          u64, // the session's seed (keyed rolls a view computes early)
	local_players: [LOCAL_MAX]sim.Player, // this client's at `tick`, by local index
	view_scale:    f32, // view units per sim unit (Glue.view_scale)
}

// What Glue.event gets beside the event: its tick, its id (the same in its Emitted and its Confirmed or Cancelled)
// and which state this is.
Event_Info :: struct {
	tick:  u32,
	id:    u64,
	state: Event_Action,
}

// A layer to draw into: a canvas item cleared every frame, drawn in its index's order (layer).
Layer :: distinct i32

// A batch of quads drawn by one shader in one MultiMesh (batch_create): one buffer upload per frame.
Batch :: distinct i32

// A Batch's instance stride: Transform2D (8), colour (4), custom (4).
@(private)
BATCH_STRIDE :: 16

@(private)
Canvas_Layer :: struct {
	item:   gd.RID,
	screen: bool, // drawn in screen pixels, whatever the camera
}

@(private)
Quad_Batch :: struct {
	item:      gd.RID, // its own canvas item (a canvas item has one material), a child of its layer's
	mesh:      gd.RID,
	multimesh: gd.RID,
	shader:    gd.RID,
	material:  gd.RID,
	data:      [dynamic]f32, // this frame's instances
	cap:       int, // instances allocated on the MultiMesh
	buffer:    gd.PackedFloat32Array,
}

@(private)
Canvas :: struct {
	ready:      bool,
	parent:     gd.RID, // the session root's canvas item
	viewport:   gd.Viewport,
	layers:     [dynamic]Canvas_Layer,
	batches:    [dynamic]Quad_Batch,
	font:       gd.Ref(gd.SystemFont),
	points:     gd.PackedVector2Array,
	colors:     gd.PackedColorArray,
	no_uvs:     gd.PackedVector2Array,
	camera:     gd.Transform2D, // the canvas transform set this frame
	time_s:     f64,
	mouse_prev: bit_set[0 ..< 8],
	mouse_now:  bit_set[0 ..< 8],
}

@(private)
canvas: Canvas

// The draw of one frame (api.draw): the canvas made on the first, every layer cleared, the game's draw, the batches
// uploaded, the screen layers held to the screen.
@(private)
immediate_draw :: proc(draw: proc(d: ^Draw($G)), pair: ^State_Pair($State), alpha, dt: f32, fresh: bool) {
	if !canvas_ready() do return
	rendering_server := gd.RenderingServer_singleton()
	for layer in canvas.layers do gd.RenderingServer_canvas_item_clear(rendering_server, layer.item)
	for &batch in canvas.batches do clear(&batch.data)
	canvas.time_s += f64(dt)
	canvas.mouse_prev = canvas.mouse_now
	canvas.mouse_now = {}
	input := gd.Input_singleton()
	for button in 1 ..< 8 {
		if gd.Input_is_mouse_button_pressed(input, gd.MouseButton(button)) do canvas.mouse_now += {button}
	}
	canvas.camera = gd.Viewport_get_canvas_transform(canvas.viewport)
	d := Draw(G) {
		state         = &pair.state,
		prev          = &pair.prev,
		tick          = pair.tick,
		alpha         = alpha,
		dt            = dt,
		time_s        = canvas.time_s,
		fresh         = fresh,
		seed          = pair.seed,
		local_players = pair.local_players,
		view_scale    = api.view_scale,
	}
	draw(&d)
	for &batch in canvas.batches do batch_upload(&batch)
	screen := transform_inverse(canvas.camera)
	for layer in canvas.layers {
		if layer.screen do gd.RenderingServer_canvas_item_set_transform(rendering_server, layer.item, screen)
	}
}

// Makes the canvas on the first draw: false while the session has no CanvasItem root to draw under.
@(private)
canvas_ready :: proc() -> bool {
	if canvas.ready do return true
	if active == nil do return false
	root := effective_root(active)
	item := gd.object_cast(gd.CanvasItem, root)
	if item.ptr == nil do return false
	context.allocator = runtime.heap_allocator()
	canvas.parent = gd.CanvasItem_get_canvas_item(item)
	canvas.viewport = gd.Node_get_viewport(root)
	canvas.font = gd.SystemFont_new()
	canvas.points = gd.PackedVector2Array_new0()
	canvas.colors = gd.PackedColorArray_new0()
	canvas.no_uvs = gd.PackedVector2Array_new0()
	canvas.ready = true
	return true
}

// The layer `index` (0 ..): layers draw in index order, above the root's own drawing; `screen`: in screen pixels
// (a HUD), else in the world under the camera. Made on first use, cleared every frame.
layer :: proc(index: int, screen := false) -> Layer {
	assert(index >= 0 && index < 64, "godot.layer: 0 ..< 64")
	rendering_server := gd.RenderingServer_singleton()
	for len(canvas.layers) <= index {
		context.allocator = runtime.heap_allocator()
		item := gd.RenderingServer_canvas_item_create(rendering_server)
		gd.RenderingServer_canvas_item_set_parent(rendering_server, item, canvas.parent)
		gd.RenderingServer_canvas_item_set_draw_index(rendering_server, item, len(canvas.layers))
		append(&canvas.layers, Canvas_Layer{item = item})
	}
	canvas.layers[index].screen = screen
	if screen do gd.RenderingServer_canvas_item_set_z_index(rendering_server, canvas.layers[index].item, 1000)
	return Layer(index)
}

// A filled rectangle (view units).
rect :: proc(layer: Layer, pos, size: [2]f32, color: Color) {
	gd.RenderingServer_canvas_item_add_rect(
		gd.RenderingServer_singleton(),
		canvas.layers[layer].item,
		{{pos.x, pos.y}, {size.x, size.y}},
		transmute(gd.Color)color,
	)
}

// A filled circle.
circle :: proc(layer: Layer, center: [2]f32, radius: f32, color: Color) {
	gd.RenderingServer_canvas_item_add_circle(
		gd.RenderingServer_singleton(),
		canvas.layers[layer].item,
		{center.x, center.y},
		radius,
		transmute(gd.Color)color,
	)
}

// A line `width` wide.
line :: proc(layer: Layer, from, to: [2]f32, color: Color, width: f32 = 1) {
	gd.RenderingServer_canvas_item_add_line(
		gd.RenderingServer_singleton(),
		canvas.layers[layer].item,
		{from.x, from.y},
		{to.x, to.y},
		transmute(gd.Color)color,
		width,
	)
}

// A polyline through `points`, `width` wide.
polyline :: proc(layer: Layer, points: [][2]f32, color: Color, width: f32 = 1) {
	if len(points) < 2 do return
	fill_points(points)
	gd.PackedColorArray_resize(&canvas.colors, 1)
	(([^]gd.Color)(gdi.packed_color_array_operator_index(&canvas.colors, 0)))[0] = transmute(gd.Color)color
	gd.RenderingServer_canvas_item_add_polyline(
		gd.RenderingServer_singleton(),
		canvas.layers[layer].item,
		canvas.points,
		canvas.colors,
		width,
	)
}

// A filled convex or concave polygon.
polygon :: proc(layer: Layer, points: [][2]f32, color: Color) {
	if len(points) < 3 do return
	fill_points(points)
	gd.PackedColorArray_resize(&canvas.colors, 1)
	(([^]gd.Color)(gdi.packed_color_array_operator_index(&canvas.colors, 0)))[0] = transmute(gd.Color)color
	gd.RenderingServer_canvas_item_add_polygon(
		gd.RenderingServer_singleton(),
		canvas.layers[layer].item,
		canvas.points,
		canvas.colors,
		canvas.no_uvs,
		{},
	)
}

@(private)
fill_points :: proc(points: [][2]f32) {
	gd.PackedVector2Array_resize(&canvas.points, len(points))
	flat := ([^][2]f32)(gdi.packed_vector2_array_operator_index(&canvas.points, 0))
	copy(flat[:len(points)], points)
}

// Text in the system font, its baseline's left end at `pos`.
text :: proc(layer: Layer, pos: [2]f32, text: string, size: int, color: Color) {
	gd.Font_draw_string(
		canvas.font,
		canvas.layers[layer].item,
		{pos.x, pos.y},
		text,
		font_size = size,
		modulate = transmute(gd.Color)color,
	)
}

// One character in the system font (no shaping: cheaper than text for a digit); its advance.
glyph :: proc(layer: Layer, pos: [2]f32, char: rune, size: int, color: Color) -> f32 {
	return gd.Font_draw_char(
		canvas.font,
		canvas.layers[layer].item,
		{pos.x, pos.y},
		int(char),
		size,
		transmute(gd.Color)color,
	)
}

// How wide `text` is at `size`.
text_width :: proc(text: string, size: int) -> f32 {
	return gd.Font_get_string_size(canvas.font, text, font_size = size).x
}

// A batch of quads in `layer`: each a quad `half` view units each way (UV 0..1) drawn by `shader_code` (a Godot
// canvas_item shader: INSTANCE_CUSTOM and COLOR are each quad's; VERTEX already holds the instance transform in
// vertex()). Made once: keep the Batch.
batch_create :: proc(layer: Layer, shader_code: string, half: [2]f32) -> Batch {
	context.allocator = runtime.heap_allocator()
	rendering_server := gd.RenderingServer_singleton()
	batch: Quad_Batch
	batch.item = gd.RenderingServer_canvas_item_create(rendering_server)
	gd.RenderingServer_canvas_item_set_parent(rendering_server, batch.item, canvas.layers[layer].item)
	batch.shader = gd.RenderingServer_shader_create(rendering_server)
	gd.RenderingServer_shader_set_code(rendering_server, batch.shader, shader_code)
	batch.material = gd.RenderingServer_material_create(rendering_server)
	gd.RenderingServer_material_set_shader(rendering_server, batch.material, batch.shader)
	gd.RenderingServer_canvas_item_set_material(rendering_server, batch.item, batch.material)
	batch.mesh = quad_mesh(half)
	batch.multimesh = gd.RenderingServer_multimesh_create(rendering_server)
	gd.RenderingServer_multimesh_set_mesh(rendering_server, batch.multimesh, batch.mesh)
	batch.buffer = gd.PackedFloat32Array_new0()
	gd.RenderingServer_canvas_item_add_multimesh(rendering_server, batch.item, batch.multimesh, {})
	append(&canvas.batches, batch)
	return Batch(len(canvas.batches) - 1)
}

// Sets a batch's shader uniform `name` to a list of colours (a `uniform vec4 name[n]`).
batch_colors :: proc(batch: Batch, name: string, colors: []Color) {
	packed := gd.PackedColorArray_new0()
	defer gd.PackedColorArray_destroy(&packed)
	gd.PackedColorArray_resize(&packed, len(colors))
	flat := ([^]gd.Color)(gdi.packed_color_array_operator_index(&packed, 0))
	for color, i in colors do flat[i] = transmute(gd.Color)color
	value := gd.to_variant(packed)
	defer gd.variant_destroy(&value)
	gd.RenderingServer_material_set_param(
		gd.RenderingServer_singleton(),
		canvas.batches[batch].material,
		gd.sn(name),
		value,
	)
}

// Sets a batch's float uniform `name`.
batch_float :: proc(batch: Batch, name: string, value: f32) {
	variant := gd.to_variant(value)
	defer gd.variant_destroy(&variant)
	gd.RenderingServer_material_set_param(
		gd.RenderingServer_singleton(),
		canvas.batches[batch].material,
		gd.sn(name),
		variant,
	)
}

// One quad of a batch this frame: at `pos`, turned `turns` (+x toward +y: clockwise on screen, Godot's y being
// down), scaled per axis, with its colour and custom data (the shader's COLOR and INSTANCE_CUSTOM).
quad :: proc(
	batch: Batch,
	pos: [2]f32,
	turns: f32 = 0,
	scale: [2]f32 = {1, 1},
	color: Color = {1, 1, 1, 1},
	custom: [4]f32 = {},
) {
	sin, cos := math.sincos(turns * math.TAU)
	data := &canvas.batches[batch].data
	append(
		data,
		cos * scale.x,
		-sin * scale.y,
		0,
		pos.x,
		sin * scale.x,
		cos * scale.y,
		0,
		pos.y,
		color.r,
		color.g,
		color.b,
		color.a,
		custom[0],
		custom[1],
		custom[2],
		custom[3],
	)
}

// Hands a batch's instances to its MultiMesh: room grown when needed, the buffer in one call.
@(private)
batch_upload :: proc(batch: ^Quad_Batch) {
	rendering_server := gd.RenderingServer_singleton()
	count := len(batch.data) / BATCH_STRIDE
	if count > batch.cap {
		batch.cap = max(count, batch.cap * 2, 256)
		gd.RenderingServer_multimesh_allocate_data(
			rendering_server,
			batch.multimesh,
			batch.cap,
			.MULTIMESH_TRANSFORM_2D,
			color_format = true,
			custom_data_format = true,
		)
		gd.RenderingServer_multimesh_set_custom_aabb(
			rendering_server,
			batch.multimesh,
			{{-1e7, -1e7, -1}, {2e7, 2e7, 2}}, // never culled: the quads move every frame
		)
		gd.PackedFloat32Array_resize(&batch.buffer, batch.cap * BATCH_STRIDE)
	}
	if count > 0 {
		flat := ([^]f32)(gdi.packed_float32_array_operator_index(&batch.buffer, 0))
		copy(flat[:len(batch.data)], batch.data[:])
		gd.RenderingServer_multimesh_set_buffer(rendering_server, batch.multimesh, batch.buffer)
	}
	gd.RenderingServer_multimesh_set_visible_instances(rendering_server, batch.multimesh, count)
}

// A quad from -half to +half, UV 0..1, as a mesh RID.
@(private)
quad_mesh :: proc(half: [2]f32) -> gd.RID {
	rendering_server := gd.RenderingServer_singleton()
	mesh := gd.RenderingServer_mesh_create(rendering_server)
	vertices := gd.PackedVector2Array_new0()
	defer gd.PackedVector2Array_destroy(&vertices)
	uvs := gd.PackedVector2Array_new0()
	defer gd.PackedVector2Array_destroy(&uvs)
	a, b := -half, half
	corners := [6][2]f32{a, {b.x, a.y}, b, a, b, {a.x, b.y}}
	corner_uvs := [6][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 1}}
	gd.PackedVector2Array_resize(&vertices, 6)
	gd.PackedVector2Array_resize(&uvs, 6)
	copy(([^][2]f32)(gdi.packed_vector2_array_operator_index(&vertices, 0))[:6], corners[:])
	copy(([^][2]f32)(gdi.packed_vector2_array_operator_index(&uvs, 0))[:6], corner_uvs[:])
	arrays := gd.array_new()
	defer gd.Array_destroy(&arrays)
	gd.Array_resize(&arrays, int(gd.RenderingServer_ArrayType.ARRAY_MAX))
	vertex_variant, uv_variant := gd.to_variant(vertices), gd.to_variant(uvs)
	gd.Array_set(&arrays, int(gd.RenderingServer_ArrayType.ARRAY_VERTEX), vertex_variant)
	gd.Array_set(&arrays, int(gd.RenderingServer_ArrayType.ARRAY_TEX_UV), uv_variant)
	gd.variant_destroy(&vertex_variant)
	gd.variant_destroy(&uv_variant)
	blend_shapes := gd.array_new()
	defer gd.Array_destroy(&blend_shapes)
	lods := gd.dict_new()
	defer gd.Dictionary_destroy(&lods)
	gd.RenderingServer_mesh_add_surface_from_arrays(
		rendering_server,
		mesh,
		.PRIMITIVE_TRIANGLES,
		arrays,
		blend_shapes,
		lods,
	)
	return mesh
}

// Puts `center` (view units) at the middle of the screen at `zoom`, plus a screen-space `offset` (a shake): the
// world layers' camera. Without a call the viewport's canvas transform stays (a Camera2D's, say).
camera :: proc(center: [2]f32, zoom: f32 = 1, offset: [2]f32 = {}) {
	size := gd.Viewport_get_visible_rect(canvas.viewport).size
	canvas.camera = {
		x      = {zoom, 0},
		y      = {0, zoom},
		origin = {size.x / 2 - center.x * zoom + offset.x, size.y / 2 - center.y * zoom + offset.y},
	}
	gd.Viewport_set_canvas_transform(canvas.viewport, canvas.camera)
}

// The screen's size in view units (the stretched viewport's).
screen_size :: proc() -> [2]f32 {
	size := gd.Viewport_get_visible_rect(canvas.viewport).size
	return {size.x, size.y}
}

// The mouse in screen pixels (the viewport's).
mouse_screen :: proc() -> [2]f32 {
	pos := gd.Viewport_get_mouse_position(canvas.viewport)
	return {pos.x, pos.y}
}

// Whether mouse button `button` (1 left, 2 right, 3 middle) is held.
mouse_down :: proc(button: int) -> bool {
	return button in canvas.mouse_now
}

// Whether mouse button `button` went down this frame.
mouse_pressed :: proc(button: int) -> bool {
	return button in canvas.mouse_now && button not_in canvas.mouse_prev
}

// Whether key `keycode` (Godot's Key: 'A', KEY_1 = 49) is held.
key_down :: proc(keycode: int) -> bool {
	return gd.Input_is_key_pressed(gd.Input_singleton(), gd.Key(keycode))
}

// Sends one of the game's commands as local player `local`, from Odin (false: no session, or a full queue).
send :: proc(d: ^Draw($G), command: $T, local := 0) -> bool {
	if !api.installed || !api.running() do return false
	return api.send(sim.command_make(sim.part(G, sim.GAME_COMMAND), command), local)
}

// The command line's user arguments (after `--`), temp-allocated: a game's own flags (os.args is empty in an
// extension: a shared library never runs Odin's start-up).
user_args :: proc() -> []string {
	list := gd.OS_get_cmdline_user_args(gd.OS_singleton())
	defer gd.PackedStringArray_destroy(&list)
	count := int(gd.PackedStringArray_size(&list))
	args := make([]string, count, context.temp_allocator)
	for i in 0 ..< count {
		args[i] = gd.string_to_odin(cast(^gd.String)gdi.packed_string_array_operator_index(&list, i64(i)))
	}
	return args
}

// The inverse of an affine 2D transform.
@(private)
transform_inverse :: proc(xform: gd.Transform2D) -> gd.Transform2D {
	det := xform.x.x * xform.y.y - xform.x.y * xform.y.x
	if det == 0 do return xform
	inv_det := 1 / det
	x := gd.Vector2{xform.y.y * inv_det, -xform.x.y * inv_det}
	y := gd.Vector2{-xform.y.x * inv_det, xform.x.x * inv_det}
	origin := gd.Vector2 {
		-(x.x * xform.origin.x + y.x * xform.origin.y),
		-(x.y * xform.origin.x + y.y * xform.origin.y),
	}
	return {x = x, y = y, origin = origin}
}

// Frees every layer, batch and scratch array (main thread), when the session node leaves the tree or the extension
// unloads; the next draw makes them again.
@(private)
immediate_clear :: proc() {
	if !canvas.ready do return
	rendering_server := gd.RenderingServer_singleton()
	for &batch in canvas.batches {
		for rid in ([]gd.RID{batch.item, batch.multimesh, batch.mesh, batch.material, batch.shader}) {
			gd.RenderingServer_free_rid(rendering_server, rid)
		}
		gd.PackedFloat32Array_destroy(&batch.buffer)
		delete(batch.data)
	}
	for layer in canvas.layers do gd.RenderingServer_free_rid(rendering_server, layer.item)
	delete(canvas.batches)
	delete(canvas.layers)
	gd.PackedVector2Array_destroy(&canvas.points)
	gd.PackedColorArray_destroy(&canvas.colors)
	gd.PackedVector2Array_destroy(&canvas.no_uvs)
	if canvas.font.ptr != nil do gd.unref(canvas.font)
	canvas = {}
}
