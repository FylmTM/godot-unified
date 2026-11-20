class_name DeckCard
extends PanelContainer
## A card in a hand (the `card` view: a Control, so the host sets its data and never poses it). It spawns under the
## board's Hands node (its marker's parent_path) and moves itself into its holder's hand: the local hero's big hand,
## or an ally's small one (hands are open). Its place there follows its slot. A click goes to the table (main.gd).

const SMALL := Vector2(64, 38)
const BIG := Vector2(112, 156)
const ATTACK_COLOR := Color(0.55, 0.28, 0.24)
const SKILL_COLOR := Color(0.27, 0.34, 0.58)

# Card_View (simulation/extension/frame.odin), set by the host on spawn and when a field changes.
var id := 0:
	set(value):
		id = value
		_refresh()
var upgraded := false:
	set(value):
		upgraded = value
		_refresh()
var hero := 0:
	set(value):
		hero = value
		_place.call_deferred()
var slot := 0:
	set(value):
		slot = value
		_place.call_deferred()
var cost := 0:
	set(value):
		cost = value
		_refresh()
var target := 0
var playable := false:
	set(value):
		playable = value
		_refresh()
var held := false:
	set(value):
		held = value
		_refresh()
var selected := false:
	set(value):
		selected = value
		_refresh()

var _style := StyleBoxFlat.new()
var _gone := false

@onready var marker: UnifiedView = $UnifiedView
@onready var _cost: Label = %Cost
@onready var _name: Label = %Name
@onready var _text: Label = %Text


func _ready() -> void:
	_style.set_corner_radius_all(6)
	_style.set_content_margin_all(5)
	_style.set_border_width_all(2)
	add_theme_stylebox_override(&"panel", _style)
	gui_input.connect(_on_gui_input)
	_refresh()
	_place()


## The card's key (its handle's): what a play names it by.
func key() -> int:
	return marker.key


## Whether the local hero holds it.
func is_local() -> bool:
	return hero == Unified.data.run.local_hero


## Into its holder's hand, at its slot: the local hero's hand is the big one.
func _place() -> void:
	if _gone or not is_inside_tree():
		return
	var hand := get_tree().get_first_node_in_group(&"hand_local" if is_local() else StringName("hand_%d" % hero))
	if hand == null:
		return
	if get_parent() != hand:
		reparent(hand, false)
	hand.move_child(self, mini(slot, hand.get_child_count() - 1))
	custom_minimum_size = BIG if is_local() else SMALL
	_refresh()


func _refresh() -> void:
	if not is_node_ready():
		return
	var info: DataCardText = Unified.constants.cards[id]
	var big := is_local()
	_cost.text = str(cost)
	_name.text = EnumCardId.name(id).capitalize() + ("+" if upgraded else "")
	_text.text = info.upgraded if upgraded else info.text
	_text.visible = big
	_cost.visible = big
	_name.add_theme_font_size_override(&"font_size", 13 if big else 10)
	var attack := target == EnumTargetKind.ENEMY or target == EnumTargetKind.ALL_ENEMIES
	_style.bg_color = (ATTACK_COLOR if attack else SKILL_COLOR).darkened(0.0 if playable or not big else 0.45)
	_style.border_color = Color.GOLD if selected else (Color.YELLOW if held else Color(0.1, 0.1, 0.12))
	_style.set_border_width_all(4 if selected or held else 2)


func _on_gui_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if press != null and press.pressed and press.button_index == MOUSE_BUTTON_LEFT:
		get_tree().call_group(&"table", &"card_clicked", self)


## Played or discarded: it fades as it lingers (an event can still come: a refusal brings it back).
func _sim_despawned() -> void:
	_gone = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tween := create_tween()
	tween.tween_property(self, ^"modulate:a", 0.0, 0.3)


func _sim_revived() -> void:
	_gone = false
	modulate.a = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventPlayRefused and state == UnifiedSession.EVENT_CONFIRMED:
		var tween := create_tween()
		for x: float in [6.0, -6.0, 3.0, 0.0]:
			tween.tween_property(self, ^"position:x", position.x + x, 0.04)
	elif event is EventCardPlayed and state == UnifiedSession.EVENT_EMITTED:
		modulate = Color(1.4, 1.4, 1.2)
