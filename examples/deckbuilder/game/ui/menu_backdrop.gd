extends Control
## The main menu's backdrop: the table's felt with a hand of cards fanned on the right, each bobbing gently, and an
## enemy's medallion looming behind them. No session runs here: the faces are drawn from the sim's constants alone.

const CARDS: Array[int] = [EnumCardId.DEFEND, EnumCardId.HEX, EnumCardId.HEAVY_BLOW, EnumCardId.MEND, EnumCardId.CLEAVE]
const CARD_SIZE := Vector2(150, 211)

var _faces: Array[CardFace] = []
var _time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in CARDS.size():
		var face := CardFace.new()
		face.size = CARD_SIZE
		face.pivot_offset = Vector2(CARD_SIZE.x * 0.5, CARD_SIZE.y * 1.6)
		add_child(face)
		face.show_card(CARDS[i], i == 2)
		_faces.append(face)
	resized.connect(_place)
	_place()


func _process(delta: float) -> void:
	_time += delta
	for i in _faces.size():
		_faces[i].position.y = _rest_y(i) + sin(_time * 1.3 + i * 0.9) * 5.0
	queue_redraw()


func _place() -> void:
	var middle := size.x * 0.68
	for i in _faces.size():
		var from_middle := i - (_faces.size() - 1) * 0.5
		var face := _faces[i]
		face.position = Vector2(middle + from_middle * 92.0 - CARD_SIZE.x * 0.5, _rest_y(i))
		face.rotation = from_middle * 0.16


func _rest_y(i: int) -> float:
	var from_middle := i - (_faces.size() - 1) * 0.5
	return size.y * 0.52 + from_middle * from_middle * 9.0


func _draw() -> void:
	# a medallion over the hand: the Hollow King watching the table
	var at := Vector2(size.x * 0.68, size.y * 0.27)
	var radius := 74.0 + sin(_time * 0.8) * 2.0
	for i in 5:
		draw_circle(at, radius + 30.0 - i * 6.0, Color(0.55, 0.36, 0.82, 0.03 + i * 0.02))
	draw_circle(at, radius, Color("2a1f17"))
	draw_circle(at, radius - 5, Color("8e5bd0").darkened(0.6))
	draw_arc(at, radius - 2, 0, TAU, 56, Color("b8893a"), 3.0, true)
	Glyph.draw(self, &"crown", at, radius * 0.55, Color("c58bf0"))
