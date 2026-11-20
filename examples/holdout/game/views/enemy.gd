extends Node3D
## An enemy: posed at its feet, facing where it walks; its body and head sized from the sim's own spec for its kind
## (Unified.constants.enemy_sizes), so a shot that looks like a headshot is one. A hit flashes it (at once, EMITTED);
## killed, it sinks and shrinks while it lingers (the marker's linger_s).

const KIND_COLORS: Array[Color] = [Color(0.95, 0.35, 0.2), Color(0.45, 0.25, 0.6), Color(0.45, 0.8, 0.25)]

## View_Enemy (simulation/extension): set by the host before _ready, and anew each time it changes.
var data: ViewEnemy:
	set(value):
		var reshaped := data == null or value.kind != data.kind
		data = value
		if reshaped and is_node_ready():
			_shape()

var _flash := 0.0
var _dying := false

@onready var _body: MeshInstance3D = $Body
@onready var _head: MeshInstance3D = $Head
@onready var _material: StandardMaterial3D = _body.material_override


func _ready() -> void:
	_shape()


func _process(delta: float) -> void:
	_flash = move_toward(_flash, 0.0, delta * 6.0)
	_material.emission_energy_multiplier = _flash * 3.0
	if _dying:
		position.y -= delta * 1.5
		scale = scale.move_toward(Vector3.ONE * 0.2, delta * 1.8)


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventEnemyHit and state == UnifiedSession.EVENT_EMITTED:
		_flash = 1.0 if (event as EventEnemyHit).headshot else 0.6


func _sim_despawned() -> void:
	_dying = true


## The body (a capsule from the feet) and the head (a sphere on top) of its kind's size, in its colour.
func _shape() -> void:
	var size: DataEnemySize = Unified.constants.enemy_sizes[data.kind]
	var capsule := _body.mesh as CapsuleMesh
	capsule.radius = size.radius
	capsule.height = 2 * (size.radius + size.half_height)
	_body.position.y = size.radius + size.half_height
	var sphere := _head.mesh as SphereMesh
	sphere.radius = size.head_radius
	sphere.height = 2 * size.head_radius
	_head.position.y = 2 * (size.radius + size.half_height) + size.head_radius * 0.7
	_material.albedo_color = KIND_COLORS[data.kind]
