class_name DeckEnemy
extends Control
## An enemy of the fight (the `enemy` view: a Control in the enemies' row), drawn in code: its intent on a badge above
## (what it does next, how much, at whom), a medallion with its kind's emblem (Glyph.of_enemy), its block on a shield
## at the medallion's foot, its name, its HP bar and its statuses. Each hero aiming at it (their Input, live) rings the
## medallion in their colour; while the local player holds up a card for an enemy, it pulses gold under the mouse. A hit
## shakes and flashes it with the damage rising off it (on EMITTED: a rollback that cancels it lets it fade); acting,
## it lunges at the heroes; killed, it sinks and fades as it lingers. A click goes to the table (table.gd).

const KIND_COLORS: Array[Color] = [Color("c0603a"), Color("6aa84f"), Color("7a8aa0"), Color("8e5bd0")]
const SIZE := Vector2(176, 236)
const MEDALLION := Vector2(88, 108)
const RADIUS := 56.0

# View_Enemy (simulation/extension/frame.odin): set by the host before _ready, and anew each time it changes.
var data: ViewEnemy:
	set(value):
		data = value
		queue_redraw()
## The local player holds up a card that can be played at it (the table sets it).
var targetable := false:
	set(value):
		targetable = value
		queue_redraw()

var _hovered := false
var _flash := 0.0
var _shake := 0.0
var _lunge := 0.0
var _time := 0.0
var _font: Font = UiTheme.serif(700)
var _body_font: Font = ThemeDB.fallback_font

@onready var marker: UnifiedView = $UnifiedView


func _ready() -> void:
	custom_minimum_size = SIZE
	add_to_group(&"enemies")
	gui_input.connect(_on_gui_input)
	mouse_entered.connect(func() -> void:
		_hovered = true
		get_tree().call_group(&"table", &"enemy_hovered", self))
	mouse_exited.connect(func() -> void: _hovered = false)


func _process(delta: float) -> void:
	_time += delta
	_flash = move_toward(_flash, 0.0, delta * 4.0)
	_shake = move_toward(_shake, 0.0, delta * 3.0)
	_lunge = move_toward(_lunge, 0.0, delta * 3.5)
	if _flash > 0.0 or _shake > 0.0 or _lunge > 0.0 or targetable:
		queue_redraw()


## The table's name for a hero: "you" for the local one.
func hero_name(hero: int) -> String:
	if hero == Unified.data.run.local_hero:
		return "you"
	var row: DataHeroRow = Unified.data.heroes.heroes[hero]
	var player_name := Unified.session.get_player_name(row.player)
	return player_name if player_name != "" else "hero %d" % (hero + 1)


func _draw() -> void:
	if data == null:
		return
	var color := KIND_COLORS[data.kind]
	var jolt := Vector2(sin(_time * 70.0) * 7.0 * _shake, sin(_lunge * PI) * 16.0)
	var at := MEDALLION + jolt
	# the intent's badge, and whom it is at
	var intent := Glyph.of_intent(data.intent)
	if intent != &"":
		var tone := _intent_color()
		var badge := Rect2(Vector2(SIZE.x * 0.5 - 40, 2), Vector2(80, 30))
		draw_style_box(UiTheme.box(Color("1a130e", 0.9), 15, 0, tone, 2), badge)
		Glyph.draw(self, intent, badge.position + Vector2(22, 15), 11.0, tone)
		var amount := str(data.intent_amount) if data.intent_amount > 0 else ""
		draw_string(_font, badge.position + Vector2(36, 22), amount, HORIZONTAL_ALIGNMENT_LEFT, 40, 19, UiTheme.TEXT)
		var at_whom := _intent_target()
		if at_whom != "":
			draw_string(_body_font, Vector2(0, 46), at_whom, HORIZONTAL_ALIGNMENT_CENTER, SIZE.x, 12, UiTheme.TEXT_DIM)
	# the aims on it: an arc per hero in their colour; the local card's target pulses gold
	var aimers: Array[int] = []
	for hero in 4:
		if data.aimed & (1 << hero):
			aimers.append(hero)
	for i in aimers.size():
		var from := -PI / 2.0 + TAU * i / aimers.size()
		draw_arc(at, RADIUS + 9, from, from + TAU / aimers.size() - 0.08, 40, UiTheme.player_color(aimers[i]), 5.0, true)
	if targetable:
		var pulse := 0.5 + 0.5 * sin(_time * 6.0)
		var ring := Color(UiTheme.GOLD, 0.35 + 0.5 * pulse if _hovered else 0.25)
		draw_arc(at, RADIUS + 4, 0, TAU, 48, ring, 4.0 if _hovered else 2.0, true)
	# the medallion and its emblem
	draw_circle(at + Vector2(0, 5), RADIUS, Color(0, 0, 0, 0.45))
	draw_circle(at, RADIUS, Color("2a1f17"))
	draw_circle(at, RADIUS - 4, color.darkened(0.55).lerp(Color.WHITE, _flash * 0.7))
	draw_arc(at, RADIUS - 2, 0, TAU, 48, Color("b8893a"), 3.0, true)
	Glyph.draw(self, Glyph.of_enemy(data.kind), at, RADIUS * 0.58, color.lightened(0.15 + _flash * 0.6))
	if data.block > 0:
		var shield := at + Vector2(RADIUS * 0.72, RADIUS * 0.72)
		Glyph.draw(self, &"shield", shield, 17.0, Color("8fb3d9"))
		draw_string(_font, shield + Vector2(-20, 6), str(data.block), HORIZONTAL_ALIGNMENT_CENTER, 40, 16, Color("10202f"))
	# its name, HP and statuses
	var name_y := MEDALLION.y + RADIUS + 22
	draw_string(_font, Vector2(0, name_y), EnumEnemyKind.name(data.kind).capitalize(), HORIZONTAL_ALIGNMENT_CENTER,
		SIZE.x, 17, UiTheme.TEXT)
	var bar := Rect2(Vector2(18, name_y + 8), Vector2(SIZE.x - 36, 16))
	draw_style_box(UiTheme.box(Color("120c09"), 8, 0, Color("5a4026"), 1), bar)
	var fraction := clampf(float(data.hp) / maxf(data.max_hp, 1), 0.0, 1.0)
	if fraction > 0.0:
		draw_style_box(UiTheme.box(Color("b8382f"), 7, 0), Rect2(bar.position + Vector2(2, 2),
			Vector2(maxf((bar.size.x - 4) * fraction, 8.0), bar.size.y - 4)))
	draw_string(_body_font, bar.position + Vector2(0, 13), "%d / %d" % [data.hp, data.max_hp], HORIZONTAL_ALIGNMENT_CENTER,
		bar.size.x, 12, Color.WHITE)
	var chips: Array[Array] = []
	if data.weak > 0:
		chips.append([&"drop", Color("8bc36a"), data.weak])
	if data.vulnerable > 0:
		chips.append([&"eye", Color("d08be0"), data.vulnerable])
	var x := SIZE.x * 0.5 - chips.size() * 22.0
	for chip in chips:
		var glyph_name: StringName = chip[0]
		var tint: Color = chip[1]
		Glyph.draw(self, glyph_name, Vector2(x + 12, bar.end.y + 14), 9.0, tint)
		draw_string(_body_font, Vector2(x + 23, bar.end.y + 19), str(chip[2]), HORIZONTAL_ALIGNMENT_LEFT, 20, 13, tint)
		x += 44.0


func _intent_color() -> Color:
	match data.intent:
		EnumIntentKind.ATTACK, EnumIntentKind.ATTACK_ALL, EnumIntentKind.CRUSH:
			return Color("e2574c")
		EnumIntentKind.DEFEND, EnumIntentKind.FORTIFY:
			return Color("8fb3d9")
		EnumIntentKind.WEAKEN:
			return Color("8bc36a")
	return Color("d08be0")


func _intent_target() -> String:
	match data.intent:
		EnumIntentKind.ATTACK_ALL:
			return "at everyone"
		EnumIntentKind.DEFEND:
			return "defends"
		EnumIntentKind.FORTIFY:
			return "fortifies"
		EnumIntentKind.WEAKEN:
			return "weakens " + hero_name(data.intent_target)
		EnumIntentKind.MARK:
			return "marks " + hero_name(data.intent_target)
		EnumIntentKind.ATTACK, EnumIntentKind.CRUSH:
			return "at everyone" if data.intent_target == 255 else "at " + hero_name(data.intent_target)
	return ""


func _on_gui_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if press != null and press.pressed and press.button_index == MOUSE_BUTTON_LEFT:
		get_tree().call_group(&"table", &"enemy_clicked", self)
		accept_event()


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_EMITTED:
		return
	if event is EventEnemyHit:
		var hit := event as EventEnemyHit
		_flash = 1.0
		_shake = 1.0 if hit.amount > 0 else 0.4
		_float_text("-%d" % hit.amount if hit.amount > 0 else "Blocked",
			Color("ff7a5c") if hit.amount > 0 else Color("8fb3d9"))
	elif event is EventEnemyActed:
		_lunge = 1.0


## A number rising off the medallion and fading.
func _float_text(text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override(&"font", _font)
	label.add_theme_font_size_override(&"font_size", 34)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override(&"outline_size", 8)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.size = Vector2(SIZE.x, 40)
	label.position = Vector2(0, MEDALLION.y - 20)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	var tween := label.create_tween().set_parallel()
	tween.tween_property(label, ^"position:y", label.position.y - 60, 0.9).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(label, ^"modulate:a", 0.0, 0.9).set_delay(0.35)
	tween.chain().tween_callback(label.queue_free)


func _sim_despawned() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tween := create_tween().set_parallel()
	tween.tween_property(self, ^"modulate:a", 0.0, 0.55)
	tween.tween_property(self, ^"scale", Vector2(0.85, 0.85), 0.55)


func _sim_revived() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	modulate.a = 1.0
	scale = Vector2.ONE
