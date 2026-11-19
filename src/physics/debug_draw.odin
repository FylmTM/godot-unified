// Debug drawing of the physics world from tick code (src/physics/README.md, Debug draw): every shape, and Box3D's own
// debug draw of joints, contacts, bounds, mass, sleep and islands, into the tick's debug draws (sim.debug_sink), one
// draw group per flag. Drawing never changes what `hash`, a save or an image holds: shapes are walked through
// read-only queries, and Box3D's draw is bracketed by a snapshot save and restore for any flag outside
// DEBUG_DRAW_PURE (tests/physics hold every flag to it).
package physics

import "base:runtime"

import box3d "box3d:bindings"
import "unified:sim"

// What debug_draw can draw: Box3D's b3DebugDraw options, by their names (drawSleep: .Sleep).
Debug_Draw_Flag :: enum u8 {
	Shapes, // every shape, drawn by physics (Box3D draws shapes only through host objects kept in the world)
	Joints,
	Joint_Extras,
	Bounds,
	Mass,
	Sleep,
	Body_Names,
	Contacts,
	Graph_Colors,
	Contact_Features,
	Contact_Normals,
	Contact_Forces,
	Islands,
}

// The flags a game offers (debug_draw): each is a draw group the dev UI toggles.
Debug_Draw_Flags :: bit_set[Debug_Draw_Flag;u16]

// The flags Box3D draws without writing to the world (measured by tests/physics: a flag that writes is drawn between
// a snapshot save and restore). `.Joint_Extras` reads joint torques through a getter that caches joint axes, which the
// whole-world hash and the image cover.
DEBUG_DRAW_PURE :: ~Debug_Draw_Flags{.Joint_Extras}

// The draw group of each flag (sim.debug_sink).
DEBUG_DRAW_GROUPS :: [Debug_Draw_Flag]string {
	.Shapes           = "physics_shapes",
	.Joints           = "physics_joints",
	.Joint_Extras     = "physics_joint_extras",
	.Bounds           = "physics_bounds",
	.Mass             = "physics_mass",
	.Sleep            = "physics_sleep",
	.Body_Names       = "physics_body_names",
	.Contacts         = "physics_contacts",
	.Graph_Colors     = "physics_graph_colors",
	.Contact_Features = "physics_contact_features",
	.Contact_Normals  = "physics_contact_normals",
	.Contact_Forces   = "physics_contact_forces",
	.Islands          = "physics_islands",
}

// Draws the world into the tick's debug draws: of the flags offered, those whose group the host shows (none shown: a
// few loads). Call it from tick code, typically after physics.step. Never changes the simulation.
debug_draw :: proc(world: ^World, t: ^sim.Tick($G), flags: Debug_Draw_Flags) {
	when !sim.DEV do return
	sinks: [Debug_Draw_Flag]sim.Debug_Sink
	shown: Debug_Draw_Flags
	names := DEBUG_DRAW_GROUPS
	for flag in flags {
		sink, on := sim.debug_sink(t, names[flag])
		if !on do continue
		sinks[flag] = sink
		shown += {flag}
	}
	if shown != {} do draw_world(world, &sinks, shown)
}

@(private)
Draw_Ctx :: struct {
	ctx:  runtime.Context,
	sink: sim.Debug_Sink,
	ids:  ^[dynamic]box3d.ShapeId,
}

@(private)
draw_world :: proc(world: ^World, sinks: ^[Debug_Draw_Flag]sim.Debug_Sink, shown: Debug_Draw_Flags) {
	if .Shapes in shown do draw_shapes(world, sinks[.Shapes])
	boxed := shown - {.Shapes}
	if boxed == {} do return
	bracket := boxed - DEBUG_DRAW_PURE != {}
	if bracket do box3d.World_SaveSnapshot(world.id, &world.scratch)
	for flag in boxed do draw_box3d(world, flag, sinks[flag])
	if bracket do box3d.World_RestoreSnapshot(world.id, &world.scratch)
}

// Shape colours, by body state (Box3D's own scheme).
@(private)
COLOR_STATIC :: 0x808080
@(private)
COLOR_KINEMATIC :: 0x4d4dc0
@(private)
COLOR_AWAKE :: 0xe6b380
@(private)
COLOR_ASLEEP :: 0x708090
@(private)
COLOR_SENSOR :: 0xf5deb3

// Every shape of the world, as spheres, capsules and hull edges; a mesh, height field or compound as its bounds.
@(private)
draw_shapes :: proc(world: ^World, sink: sim.Debug_Sink) {
	ids := make([dynamic]box3d.ShapeId, context.temp_allocator)
	draw := Draw_Ctx{context, sink, &ids}
	everything := box3d.AABB{{-1e30, -1e30, -1e30}, {1e30, 1e30, 1e30}}
	box3d.World_OverlapAABB(world.id, everything, box3d.DefaultQueryFilter(), collect_shape, &draw)
	for id in ids {
		body := box3d.Shape_GetBody(id)
		pose := box3d.Body_GetTransform(body)
		color: u32 = COLOR_AWAKE
		switch {
		case box3d.Shape_IsSensor(id):
			color = COLOR_SENSOR
		case box3d.Body_GetType(body) == .staticBody:
			color = COLOR_STATIC
		case box3d.Body_GetType(body) == .kinematicBody:
			color = COLOR_KINEMATIC
		case !box3d.Body_IsAwake(body):
			color = COLOR_ASLEEP
		}
		at :: proc(pose: box3d.Transform, local: box3d.Vec3) -> [3]f32 {
			return transmute([3]f32)box3d.TransformPoint(pose, local)
		}
		#partial switch box3d.Shape_GetType(id) {
		case .sphereShape:
			sphere := box3d.Shape_GetSphere(id)
			sim.sink_sphere(sink, at(pose, sphere.center), sphere.radius, color)
		case .capsuleShape:
			capsule := box3d.Shape_GetCapsule(id)
			sim.sink_capsule(sink, at(pose, capsule.center1), at(pose, capsule.center2), capsule.radius, color)
		case .hullShape:
			hull := box3d.Shape_GetHull(id)
			points, edges := box3d.GetHullPoints(hull), box3d.GetHullEdges(hull)
			for i in 0 ..< int(hull.edgeCount) {
				edge := edges[i]
				if int(edge.twin) < i do continue // each edge once
				a, b := points[edge.origin], points[edges[edge.twin].origin]
				sim.sink_line(sink, at(pose, a), at(pose, b), color)
			}
		case:
			bounds := box3d.Shape_GetAABB(id)
			low, high := transmute([3]f32)bounds.lowerBound, transmute([3]f32)bounds.upperBound
			sim.sink_box(sink, (low + high) / 2, (high - low) / 2, {0, 0, 0, 1}, color)
		}
	}
}

@(private)
collect_shape :: proc "c" (shape: box3d.ShapeId, user: rawptr) -> bool {
	draw := (^Draw_Ctx)(user)
	context = draw.ctx
	append(draw.ids, shape)
	return true
}

// Box3D's own draw of one flag, into its group.
@(private)
draw_box3d :: proc(world: ^World, flag: Debug_Draw_Flag, sink: sim.Debug_Sink) {
	draw := Draw_Ctx {
		ctx  = context,
		sink = sink,
	}
	debug := box3d.DefaultDebugDraw()
	debug.drawingBounds = {{-1e30, -1e30, -1e30}, {1e30, 1e30, 1e30}}
	debug.context_ = &draw
	debug.DrawShapeFcn = proc "c" (_: rawptr, _: box3d.WorldTransform, _: box3d.HexColor, _: rawptr) {}
	debug.DrawSegmentFcn = proc "c" (a, b: box3d.Pos, color: box3d.HexColor, user: rawptr) {
		draw := (^Draw_Ctx)(user)
		context = draw.ctx
		sim.sink_line(draw.sink, transmute([3]f32)a, transmute([3]f32)b, u32(color))
	}
	debug.DrawTransformFcn = proc "c" (pose: box3d.WorldTransform, user: rawptr) {
		draw := (^Draw_Ctx)(user)
		context = draw.ctx
		origin := transmute([3]f32)pose.p
		AXES :: [3]box3d.Vec3{{0.5, 0, 0}, {0, 0.5, 0}, {0, 0, 0.5}}
		colors := [3]u32{0xff4040, 0x40e040, 0x4080ff}
		for axis, i in AXES {
			sim.sink_line(draw.sink, origin, transmute([3]f32)box3d.TransformPoint(pose, axis), colors[i])
		}
	}
	debug.DrawPointFcn = proc "c" (point: box3d.Pos, size: f32, color: box3d.HexColor, user: rawptr) {
		draw := (^Draw_Ctx)(user)
		context = draw.ctx
		sim.sink_point(draw.sink, transmute([3]f32)point, size * 0.01, u32(color)) // Box3D's size is in pixels
	}
	debug.DrawSphereFcn = proc "c" (centre: box3d.Pos, radius: f32, color: box3d.HexColor, _: f32, user: rawptr) {
		draw := (^Draw_Ctx)(user)
		context = draw.ctx
		sim.sink_sphere(draw.sink, transmute([3]f32)centre, radius, u32(color))
	}
	debug.DrawCapsuleFcn = proc "c" (a, b: box3d.Pos, radius: f32, color: box3d.HexColor, _: f32, user: rawptr) {
		draw := (^Draw_Ctx)(user)
		context = draw.ctx
		sim.sink_capsule(draw.sink, transmute([3]f32)a, transmute([3]f32)b, radius, u32(color))
	}
	debug.DrawBoundsFcn = proc "c" (bounds: box3d.AABB, color: box3d.HexColor, user: rawptr) {
		draw := (^Draw_Ctx)(user)
		context = draw.ctx
		low, high := transmute([3]f32)bounds.lowerBound, transmute([3]f32)bounds.upperBound
		sim.sink_box(draw.sink, (low + high) / 2, (high - low) / 2, {0, 0, 0, 1}, u32(color))
	}
	debug.DrawBoxFcn = proc "c" (
		extents: box3d.Vec3,
		pose: box3d.WorldTransform,
		color: box3d.HexColor,
		user: rawptr,
	) {
		draw := (^Draw_Ctx)(user)
		context = draw.ctx
		rot := [4]f32{pose.q.v.x, pose.q.v.y, pose.q.v.z, pose.q.s}
		sim.sink_box(draw.sink, transmute([3]f32)pose.p, transmute([3]f32)extents, rot, u32(color))
	}
	debug.DrawStringFcn = proc "c" (point: box3d.Pos, text: cstring, color: box3d.HexColor, user: rawptr) {
		draw := (^Draw_Ctx)(user)
		context = draw.ctx
		sim.sink_text(draw.sink, transmute([3]f32)point, string(text), u32(color))
	}
	switch flag {
	case .Shapes:
	case .Joints:
		debug.drawJoints = true
	case .Joint_Extras:
		debug.drawJoints, debug.drawJointExtras = true, true
	case .Bounds:
		debug.drawBounds = true
	case .Mass:
		debug.drawMass = true
	case .Sleep:
		debug.drawSleep = true
	case .Body_Names:
		debug.drawBodyNames = true
	case .Contacts:
		debug.drawContacts = true
	case .Graph_Colors:
		debug.drawGraphColors = true
	case .Contact_Features:
		debug.drawContactFeatures = true
	case .Contact_Normals:
		debug.drawContactNormals = true
	case .Contact_Forces:
		debug.drawContactForces = true
	case .Islands:
		debug.drawIslands = true
	}
	box3d.World_Draw(world.id, &debug, max(u64))
}
