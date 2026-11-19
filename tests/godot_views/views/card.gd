extends PanelContainer
# A data-only view (its root is a Control: the host never poses it): a thing's card, spawned in the hand's container
# (its marker's parent_path), which lays it out.

var processed := 0
var life_at_first_process := -1
var despawns := 0
var events: Array[Array] = []  # [event, state, despawns when it came]

# Card_Data (ext/ext.odin), set by the host on spawn and when a field's bytes change.
var life := 0:
	set(v):
		life = v
		life_sets += 1
		if is_node_ready():
			($Life as Label).text = str(v)
var life_sets := 0
var shape := 0
var holder := 0

@onready var marker: UnifiedView = $UnifiedView


func _process(_delta: float) -> void:
	processed += 1
	if processed == 1:
		life_at_first_process = life


func _sim_despawned() -> void:
	despawns += 1


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	events.append([event, state, despawns])
