class_name Glyph
## The table's icons, drawn in code (no image assets): a card's art, an enemy's emblem and intent, a map node, a
## status. `draw` paints one on any CanvasItem from its _draw(), centred on `at`, `radius` pixels from the middle to
## its edge, in one colour with a darker outline. Each glyph is a few polygons in a unit box (-1..1, y down).

## Every glyph `draw` knows.
const KINDS: Array[StringName] = [&"sword", &"swords", &"axe", &"shield", &"heart", &"bolt", &"eye", &"skull", &"flag",
	&"cards", &"fang", &"drop", &"crown", &"flame", &"chest", &"star", &"chain", &"boots"]


## Paints `kind` centred on `at`, `radius` px to its edge, filled with `color` and outlined a shade darker.
static func draw(canvas: CanvasItem, kind: StringName, at: Vector2, radius: float, color: Color) -> void:
	var outline := color.darkened(0.6)
	outline.a = color.a
	for poly: PackedVector2Array in _shapes(kind):
		var points := PackedVector2Array()
		for p in poly:
			points.append(at + p * radius)
		canvas.draw_colored_polygon(points, color)
		points.append(points[0])
		canvas.draw_polyline(points, outline, maxf(1.0, radius * 0.07), true)


## The glyph of a card by its EnumCardId value: what it mostly does.
static func of_card(id: int) -> StringName:
	match id:
		EnumCardId.STRIKE, EnumCardId.HEAVY_BLOW:
			return &"sword"
		EnumCardId.TWIN_STRIKE:
			return &"swords"
		EnumCardId.CLEAVE, EnumCardId.EXECUTE:
			return &"axe"
		EnumCardId.DEFEND, EnumCardId.COVER, EnumCardId.BULWARK, EnumCardId.TAUNT:
			return &"shield"
		EnumCardId.LINKED_GUARD:
			return &"chain"
		EnumCardId.CHANNEL:
			return &"bolt"
		EnumCardId.EXPOSE:
			return &"eye"
		EnumCardId.HEX:
			return &"skull"
		EnumCardId.MEND:
			return &"heart"
		EnumCardId.SECOND_WIND:
			return &"boots"
		EnumCardId.BATTLE_CRY, EnumCardId.RALLY:
			return &"flag"
		EnumCardId.HAND_OFF:
			return &"cards"
	return &"star"


## The emblem of an enemy by its EnumEnemyKind value.
static func of_enemy(kind: int) -> StringName:
	match kind:
		EnumEnemyKind.GNASHER:
			return &"fang"
		EnumEnemyKind.SPITTER:
			return &"drop"
		EnumEnemyKind.BULWARK:
			return &"shield"
		EnumEnemyKind.HOLLOW_KING:
			return &"crown"
	return &"skull"


## The glyph of an enemy's intent by its EnumIntentKind value (&"" for none).
static func of_intent(intent: int) -> StringName:
	match intent:
		EnumIntentKind.ATTACK, EnumIntentKind.CRUSH:
			return &"sword"
		EnumIntentKind.ATTACK_ALL:
			return &"swords"
		EnumIntentKind.DEFEND, EnumIntentKind.FORTIFY:
			return &"shield"
		EnumIntentKind.WEAKEN:
			return &"drop"
		EnumIntentKind.MARK:
			return &"eye"
	return &""


## The glyph of a map node by its EnumNodeKind value (&"" for none).
static func of_node(node: int) -> StringName:
	match node:
		EnumNodeKind.FIGHT:
			return &"sword"
		EnumNodeKind.ELITE:
			return &"skull"
		EnumNodeKind.REST:
			return &"flame"
		EnumNodeKind.TREASURE:
			return &"chest"
		EnumNodeKind.BOSS:
			return &"crown"
	return &""


## A hero class's emblem by its EnumHeroClass value.
static func of_class(hero_class: int) -> StringName:
	return &"shield" if hero_class == EnumHeroClass.VANGUARD else &"star"


static func _shapes(kind: StringName) -> Array[PackedVector2Array]:
	match kind:
		&"sword":
			return _sword(0.0)
		&"swords":
			var both := _sword(-0.5)
			both.append_array(_sword(0.5))
			return both
		&"axe":
			return [
				_poly([-0.08, -0.95, 0.08, -0.95, 0.08, 0.95, -0.08, 0.95]),
				_poly([0.08, -0.85, 0.55, -0.95, 0.8, -0.55, 0.7, -0.1, 0.4, 0.05, 0.08, -0.15]),
			]
		&"shield":
			return [_poly([-0.75, -0.8, 0.0, -0.95, 0.75, -0.8, 0.7, 0.05, 0.45, 0.55, 0.0, 0.95, -0.45, 0.55, -0.7, 0.05])]
		&"heart":
			return [_poly([0.0, 0.9, -0.75, 0.15, -0.9, -0.3, -0.75, -0.7, -0.4, -0.85, 0.0, -0.55, 0.4, -0.85, 0.75, -0.7,
				0.9, -0.3, 0.75, 0.15])]
		&"bolt":
			return [_poly([0.15, -0.95, -0.55, 0.1, -0.05, 0.1, -0.2, 0.95, 0.55, -0.15, 0.05, -0.15, 0.3, -0.95])]
		&"eye":
			return [
				_poly([-0.95, 0.0, -0.5, -0.45, 0.0, -0.6, 0.5, -0.45, 0.95, 0.0, 0.5, 0.45, 0.0, 0.6, -0.5, 0.45]),
				_circle(Vector2.ZERO, 0.3, 10),
			]
		&"skull":
			return [
				_poly([-0.7, -0.2, -0.6, -0.7, -0.25, -0.92, 0.25, -0.92, 0.6, -0.7, 0.7, -0.2, 0.45, 0.2, 0.4, 0.55,
					-0.4, 0.55, -0.45, 0.2]),
				_circle(Vector2(-0.3, -0.25), 0.17, 8),
				_circle(Vector2(0.3, -0.25), 0.17, 8),
				_poly([-0.3, 0.6, 0.3, 0.6, 0.25, 0.9, -0.25, 0.9]),
			]
		&"flag":
			return [
				_poly([-0.7, -0.95, -0.55, -0.95, -0.55, 0.95, -0.7, 0.95]),
				_poly([-0.55, -0.9, 0.85, -0.65, 0.4, -0.3, 0.85, 0.05, -0.55, -0.1]),
			]
		&"cards":
			return [
				_poly([-0.85, -0.55, -0.15, -0.8, 0.2, 0.55, -0.5, 0.8]),
				_poly([-0.2, -0.75, 0.5, -0.75, 0.5, 0.75, -0.2, 0.75]),
			]
		&"fang":
			return [_poly([-0.9, -0.7, 0.9, -0.7, 0.55, -0.35, 0.35, 0.6, 0.15, -0.3, 0.0, 0.9, -0.15, -0.3, -0.35, 0.6,
				-0.55, -0.35])]
		&"drop":
			return [_poly([0.0, -0.95, 0.35, -0.35, 0.65, 0.15, 0.6, 0.55, 0.3, 0.85, -0.3, 0.85, -0.6, 0.55, -0.65, 0.15,
				-0.35, -0.35])]
		&"crown":
			return [_poly([-0.85, 0.6, -0.95, -0.55, -0.45, -0.05, 0.0, -0.85, 0.45, -0.05, 0.95, -0.55, 0.85, 0.6])]
		&"flame":
			return [_poly([0.0, -0.95, 0.35, -0.45, 0.25, -0.15, 0.55, -0.3, 0.7, 0.2, 0.5, 0.7, 0.0, 0.92, -0.5, 0.7,
				-0.7, 0.2, -0.45, -0.3, -0.3, 0.0])]
		&"chest":
			return [
				_poly([-0.85, -0.25, 0.85, -0.25, 0.85, 0.75, -0.85, 0.75]),
				_poly([-0.85, -0.3, -0.7, -0.7, 0.7, -0.7, 0.85, -0.3]),
				_poly([-0.15, -0.15, 0.15, -0.15, 0.15, 0.25, -0.15, 0.25]),
			]
		&"chain":  # two shields side by side: guard and guarded
			var pair: Array[PackedVector2Array] = []
			for x: float in [-0.38, 0.38]:
				pair.append(Transform2D(0.0, Vector2(0.62, 0.62), 0.0, Vector2(x, 0.1)) * _shapes(&"shield")[0])
			return pair
		&"boots":
			return [_poly([-0.5, -0.9, 0.1, -0.9, 0.1, 0.25, 0.85, 0.4, 0.85, 0.85, -0.5, 0.85])]
	return [_star()]


static func _sword(x: float) -> Array[PackedVector2Array]:
	var blade := _poly([0.0, -0.98, 0.14, -0.78, 0.12, 0.35, -0.12, 0.35, -0.14, -0.78])
	var guard := _poly([-0.42, 0.35, 0.42, 0.35, 0.42, 0.5, -0.42, 0.5])
	var grip := _poly([-0.08, 0.5, 0.08, 0.5, 0.08, 0.9, -0.08, 0.9])
	var shapes: Array[PackedVector2Array] = [blade, guard, grip]
	if x != 0.0:  # crossed: leaning left or right
		var turn := Transform2D(signf(x) * 0.5, Vector2(x * 0.45, 0.0))
		for i in shapes.size():
			shapes[i] = turn * shapes[i]
	return shapes


static func _star() -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in 10:
		var r := 0.95 if i % 2 == 0 else 0.4
		var a := -PI / 2.0 + i * PI / 5.0
		points.append(Vector2(cos(a), sin(a)) * r)
	return points


static func _circle(centre: Vector2, r: float, sides: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in sides:
		var a := i * TAU / sides
		points.append(centre + Vector2(cos(a), sin(a)) * r)
	return points


static func _poly(xy: Array[float]) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(0, xy.size(), 2):
		points.append(Vector2(xy[i], xy[i + 1]))
	return points
