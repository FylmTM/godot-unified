class_name DeckCard
extends Control
## A card in a hand (the `card` view: a Control, so the host sets its data and never poses it). It spawns under the
## table's Hands node (its marker's parent_path) and moves itself into its holder's hand: the local hero's fanned hand
## (a Hand), or an ally's small open one on their hero panel. Its place there follows its slot. Its face (a CardFace)
## lifts, straightens and grows under the mouse; held up (the aim) it stays lifted with a gold edge; a playable card
## glows faintly, one the local hero can't play now is dimmed. A click goes to the table (table.gd); it is drawn and
## played with a short slide, and a refused play shakes it. It names no autoload (the tools read it): the table makes
## its sounds.

const BIG := Vector2(128, 180)
const SMALL := Vector2(23, 32)
const LIFT := 34.0
const HOVER_SCALE := 1.18

# View_Card (simulation/extension/frame.odin): set by the host before _ready, and anew each time it changes.
var data: ViewCard:
	set(value):
		var moved := data == null or value.hero != data.hero or value.slot != data.slot
		data = value
		if moved:
			_place.call_deferred()
		_refresh()
var selected := false:
	set(value):
		selected = value
		_refresh()

var _face: CardFace
var _hovered := false
var _gone := false
var _lift := 0.0  # 0..1: how far the face is raised and straightened
var _shake := 0.0  # a refused play's sideways shake, px

@onready var marker: UnifiedView = $UnifiedView


func _ready() -> void:
	_face = CardFace.new()
	_face.name = &"Face"
	add_child(_face)
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(_on_gui_input)
	mouse_entered.connect(func() -> void:
		_hovered = true
		get_tree().call_group(&"table", &"card_hovered", self))
	mouse_exited.connect(func() -> void: _hovered = false)
	_refresh()
	_place()
	_face.modulate.a = 0.0  # dealt: it slides up into the hand
	_face.position.y = 60.0


func _process(delta: float) -> void:
	var big := custom_minimum_size == BIG
	var want := 1.0 if big and not _gone and (_hovered or selected) else 0.0
	_lift = move_toward(_lift, want, delta * 9.0)
	var eased := ease(_lift, -2.0)
	_face.size = size
	_face.pivot_offset = Vector2(size.x * 0.5, size.y)
	_face.position.x = _shake
	_face.position.y = lerpf(_face.position.y, -LIFT * eased, minf(1.0, delta * 18.0))
	_face.rotation = -rotation * eased  # straightened against the fan
	_face.scale = Vector2.ONE * lerpf(1.0, HOVER_SCALE, eased)
	if not _gone:
		_face.modulate.a = move_toward(_face.modulate.a, 1.0, delta * 6.0)
	z_index = 10 if _lift > 0.05 else 0


## The card's key (its handle's): what a play names it by.
func key() -> int:
	return marker.key


## Whether the local hero holds it.
func is_local() -> bool:
	return data.hero == Unified.data.run.local_hero


## Into its holder's hand, at its slot: the local hero's hand is the big one.
func _place() -> void:
	if _gone or not is_inside_tree():
		return
	var hand := get_tree().get_first_node_in_group(&"hand_local" if is_local() else StringName("hand_%d" % data.hero))
	if hand == null:
		return
	if get_parent() != hand:
		reparent(hand, false)
	hand.move_child(self, mini(data.slot, hand.get_child_count() - 1))
	custom_minimum_size = BIG if is_local() else SMALL
	size = custom_minimum_size
	_refresh()


func _refresh() -> void:
	if not is_node_ready():
		return
	var big := is_local()
	_face.compact = not big
	_face.show_card(data.id, data.upgraded, data.cost)
	_face.highlighted = selected or data.held
	var info: DataCardText = Unified.constants.cards[data.id]
	tooltip_text = "" if big else "%s: %s" % [EnumCardId.name(data.id).capitalize(),
		info.upgraded if data.upgraded else info.text]
	if big and not data.playable:
		_face.self_modulate = Color(0.55, 0.52, 0.5)
	else:
		_face.self_modulate = Color.WHITE


func _on_gui_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if press != null and press.pressed and press.button_index == MOUSE_BUTTON_LEFT:
		get_tree().call_group(&"table", &"card_clicked", self)
		accept_event()


## Played or discarded: it flies up and fades as it lingers (an event can still come: a refusal brings it back).
func _sim_despawned() -> void:
	_gone = true
	_hovered = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tween := create_tween().set_parallel()
	tween.tween_property(_face, ^"modulate:a", 0.0, 0.3)
	tween.tween_property(_face, ^"position:y", _face.position.y - 90.0, 0.3).set_ease(Tween.EASE_OUT)


func _sim_revived() -> void:
	_gone = false
	_face.modulate.a = 1.0
	_face.position.y = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventPlayRefused and state == UnifiedSession.EVENT_CONFIRMED:
		var tween := create_tween()
		for x: float in [8.0, -8.0, 4.0, 0.0]:
			tween.tween_property(self, ^"_shake", x, 0.04)
	elif event is EventCardPlayed and state == UnifiedSession.EVENT_EMITTED:
		_face.modulate = Color(1.5, 1.4, 1.1)
