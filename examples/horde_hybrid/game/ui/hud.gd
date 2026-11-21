class_name Hud
extends Control
## The HUD in Controls: the match line, the HP and XP bars, the level-up cards (buttons, or keys 1-3) and the
## match-over banner. Reads Unified.data.hud; a card sends a CommandPick.

signal pick(upgrade: int)

const UPGRADE_TEXT: Array[String] = [
	"+1 bolt", "+1 pierce", "faster bolts", "+1 chain", "bigger blasts", "faster feet", "+25 max HP"
]

var _offers: Array[int] = []

var _status: Label
var _fps: Label
var _hp: ProgressBar
var _xp: ProgressBar
var _level: Label
var _cards: HBoxContainer
var _banner: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var top := VBoxContainer.new()
	top.position = Vector2(16, 12)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top)
	_status = _label(top, 20)
	_fps = _label(top, 14)
	_level = _label(top, 16)
	_hp = _bar(top, Color(0.3, 0.9, 0.4))
	_xp = _bar(top, Color(0.3, 0.75, 1.0))
	_cards = HBoxContainer.new()
	_cards.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_cards.position = Vector2(-330, -170)
	_cards.add_theme_constant_override(&"separation", 16)
	add_child(_cards)
	_banner = _label(self, 40)
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.visible = false
	Unified.data.hud.changed.connect(_on_hud_changed)
	_on_hud_changed()


func _process(_delta: float) -> void:
	_fps.text = "%d fps  %.1f ms" % [Engine.get_frames_per_second(), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0]


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var index := key.keycode - KEY_1
	if index >= 0 and index < _offers.size():
		pick.emit(_offers[index])


## The match-over banner, from the confirmed event.
func show_over(wave: int, kills: int) -> void:
	_banner.text = "Overrun at wave %d, %d kills" % [wave + 1, kills]
	_banner.visible = true


func _on_hud_changed() -> void:
	var hud := Unified.data.hud
	_status.text = "Wave %d   %d:%02d   enemies %d   kills %d" % [hud.wave + 1, floori(hud.time_s / 60.0), int(hud.time_s) % 60, hud.enemies, hud.kills]
	_level.text = "Level %d" % hud.level
	_hp.max_value = maxi(hud.hp_max, 1)
	_hp.value = hud.hp
	_xp.max_value = maxi(hud.xp_next, 1)
	_xp.value = hud.xp
	if hud.phase == EnumPhase.OVER and not _banner.visible:
		show_over(hud.wave, hud.kills)  # no script events here: the phase says it
	elif hud.phase == EnumPhase.MATCH:
		_banner.visible = false
	var offers: Array[int] = []
	if hud.pending > 0:
		for offer: int in hud.offers:
			offers.append(offer)
	if offers != _offers:
		_offers = offers
		_build_cards()


func _build_cards() -> void:
	for child in _cards.get_children():
		child.queue_free()
	for i in _offers.size():
		var upgrade := _offers[i]
		var card := Button.new()
		card.custom_minimum_size = Vector2(200, 110)
		card.text = "%d\n%s" % [i + 1, UPGRADE_TEXT[upgrade]]
		card.add_theme_font_size_override(&"font_size", 20)
		card.pressed.connect(func() -> void: pick.emit(upgrade))
		_cards.add_child(card)


func _label(parent: Control, font_size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_constant_override(&"outline_size", 4)
	label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _bar(parent: Control, color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(260, 14)
	bar.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	bar.add_theme_stylebox_override(&"fill", fill)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0, 0, 0, 0.5)
	bar.add_theme_stylebox_override(&"background", back)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bar)
	return bar
