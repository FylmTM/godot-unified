extends PanelContainer
# A data-only view (its root is a Control: the host never poses it): a thing's card, spawned in the hand's container
# (its marker's parent_path), which lays it out.

## Every card made since the hand check cleared it: a record each that outlives its card, kept up to date by it
## ({key, holder, life_sets, despawns, events}), so a card that lived between two of the check's frames still counts.
static var made: Array[Dictionary] = []

var processed := 0
var life_at_first_process := -1
var despawns := 0
var events: Array[Array] = []  # [event, state, despawns when it came]

# View_Card (ext/ext.odin): set by the host before _ready, and anew each time its bytes change.
var data: ViewCard:
	set(value):
		if data == null or value.life != data.life:
			life_sets += 1
			record.life_sets = life_sets
			if is_node_ready():
				($Life as Label).text = str(value.life)
		record.holder = value.holder
		data = value
var life_sets := 0
var record := {life_sets = 0, holder = 0, despawns = 0}

@onready var marker: UnifiedView = $UnifiedView


func _ready() -> void:
	($Life as Label).text = str(data.life)
	record.key = marker.key
	record.events = events
	made.append(record)


func _process(_delta: float) -> void:
	processed += 1
	if processed == 1:
		life_at_first_process = data.life


func _sim_despawned() -> void:
	despawns += 1
	record.despawns = despawns


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	events.append([event, state, despawns])
