class_name DeckEnemy
extends PanelContainer
## An enemy of the fight (the `enemy` view: a Control in the enemies' row): its HP, block, statuses and intent, and
## which heroes aim at it (their Input, live). A hit flashes on EMITTED (a rollback that cancels it lets it fade); a
## click goes to the table (main.gd).

const HERO_COLORS: Array[Color] = [Color(1, 0.45, 0.4), Color(0.5, 1, 0.45), Color(0.4, 0.85, 1), Color(0.85, 0.5, 1)]

# Enemy_View (simulation/extension/frame.odin).
var kind := 0
var weak := 0
var vulnerable := 0
var intent := 0
var intent_target := 0
var aimed := 0
var index := 0
var hp := 0
var max_hp := 0
var block := 0
var intent_amount := 0

var _style := StyleBoxFlat.new()

@onready var marker: UnifiedView = $UnifiedView
@onready var _intent: Label = %Intent
@onready var _name: Label = %Name
@onready var _hp: ProgressBar = %HP
@onready var _stats: Label = %Stats
@onready var _hit: Label = %Hit


func _ready() -> void:
	_style.bg_color = Color(0.18, 0.16, 0.2)
	_style.set_corner_radius_all(8)
	_style.set_content_margin_all(8)
	add_theme_stylebox_override(&"panel", _style)
	_hp.add_theme_stylebox_override(&"fill", Bars.fill(Color(0.8, 0.25, 0.2)))
	_hp.add_theme_stylebox_override(&"background", Bars.fill(Color(0.1, 0.1, 0.1)))
	add_to_group(&"enemies")
	gui_input.connect(_on_gui_input)
	mouse_entered.connect(func() -> void: get_tree().call_group(&"table", &"enemy_hovered", self))


## Every field is set before any node's _process, so one redraw a frame shows them all.
func _process(_delta: float) -> void:
	_name.text = EnumEnemyKind.name(kind).capitalize()
	_hp.max_value = maxi(max_hp, 1)
	_hp.value = hp
	var stats := "%d / %d HP" % [hp, max_hp]
	if block > 0:
		stats += "   %d block" % block
	if weak > 0:
		stats += "\nWeak %d" % weak
	if vulnerable > 0:
		stats += "\nVulnerable %d" % vulnerable
	_stats.text = stats
	_intent.text = _intent_text()
	_style.border_color = Color(0.1, 0.1, 0.1)
	_style.set_border_width_all(2)
	for hero in 4:
		if aimed & (1 << hero):
			_style.border_color = HERO_COLORS[hero]
			_style.set_border_width_all(5)


## The table's name for a hero: "you" for the local one.
func hero_name(hero: int) -> String:
	if hero == Unified.data.run.local_hero:
		return "you"
	var row: DataHeroRow = Unified.data.heroes.heroes[hero]
	var player_name := Unified.session.get_player_name(row.player)
	return player_name if player_name != "" else "hero %d" % (hero + 1)


func _intent_text() -> String:
	var at := "everyone" if intent_target == 255 else hero_name(intent_target)
	match intent:
		EnumIntentKind.ATTACK, EnumIntentKind.CRUSH:
			return "attacks %s: %d" % [at, intent_amount]
		EnumIntentKind.ATTACK_ALL:
			return "attacks everyone: %d" % intent_amount
		EnumIntentKind.DEFEND, EnumIntentKind.FORTIFY:
			return "defends: %d" % intent_amount
		EnumIntentKind.WEAKEN:
			return "weakens %s" % at
		EnumIntentKind.MARK:
			return "marks %s" % at
	return ""


func _on_gui_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if press != null and press.pressed and press.button_index == MOUSE_BUTTON_LEFT:
		get_tree().call_group(&"table", &"enemy_clicked", self)


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_EMITTED:
		return
	if event is EventEnemyHit:
		var hit := event as EventEnemyHit
		_hit.text = "-%d" % hit.amount if hit.amount > 0 else "blocked"
		_hit.modulate.a = 1.0
		create_tween().tween_property(_hit, ^"modulate:a", 0.0, 0.6)
		modulate = Color(1.6, 0.8, 0.8)
		create_tween().tween_property(self, ^"modulate", Color.WHITE, 0.25)
	elif event is EventEnemyActed:
		var tween := create_tween()
		tween.tween_property(self, ^"scale", Vector2(1.08, 1.08), 0.1)
		tween.tween_property(self, ^"scale", Vector2.ONE, 0.15)


func _sim_despawned() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	create_tween().tween_property(self, ^"modulate:a", 0.0, 0.5)


func _sim_revived() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	modulate.a = 1.0
