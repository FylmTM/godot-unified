class_name Greybox
## Greybox visuals for level markers: primitive meshes with flat toon-ish materials, built in code so a
## marker's look follows its properties (in the editor too: the marker scripts are @tool).

const CRATE := Color(0.86, 0.62, 0.32)
const BALL := Color(0.98, 0.84, 0.22)
const CUBE := Color(0.3, 0.55, 0.95)
const KEY := Color(1.0, 0.85, 0.2)
const HEAVY := Color(0.9, 0.28, 0.25)
const TROPHY := Color(1.0, 0.78, 0.1)
const PLATFORM := Color(0.95, 0.75, 0.25)
const PAD := Color(0.3, 1.0, 0.6)
const PLATE := Color(0.55, 0.6, 0.7)
const BELL := Color(1.0, 0.8, 0.3)
const SWITCH := Color(0.9, 0.35, 0.9)
const BUMPER := Color(1.0, 0.4, 0.5)
const FLAG := Color(0.35, 0.9, 1.0)


static func material(c: Color, glow := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_TOON
	m.rim_enabled = true
	m.rim = 0.25
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = glow
	return m


## Replaces the node's generated visuals (children named "Greybox*") with one mesh.
static func set_mesh(n: Node3D, mesh: Mesh, c: Color, offset := Vector3.ZERO, glow := 0.0,
		name := "Greybox") -> MeshInstance3D:
	var old := n.get_node_or_null(NodePath(name))
	if old:
		n.remove_child(old)
		old.free()
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.material_override = material(c, glow)
	mi.position = offset
	n.add_child(mi)
	return mi


static func box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


static func sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	return s


static func cylinder(r: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	return c
