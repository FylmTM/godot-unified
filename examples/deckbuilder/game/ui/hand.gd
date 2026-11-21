class_name Hand
extends Container
## The local hero's hand: its cards (DeckCard, children in slot order) fanned along the bottom of the table, centred,
## overlapping more as the hand grows so every card fits its width, each tilted a little away from the middle and
## dipped along an arc. A card draws its own lift under the mouse; this only places them.

## How far a card turns per place from the middle, in radians.
const TILT := 0.045
## How far a card dips per place from the middle squared, in px.
const ARC := 2.6


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		_fan()


func _get_minimum_size() -> Vector2:
	return Vector2(0, DeckCard.BIG.y)


func _fan() -> void:
	var cards: Array[Control] = []
	for child in get_children():
		var card := child as Control
		if card != null and card.visible:
			cards.append(card)
	var count := cards.size()
	if count == 0:
		return
	var card_size := DeckCard.BIG
	var step := card_size.x * 0.92
	if count > 1:
		step = minf(step, (size.x - card_size.x) / (count - 1))
	var width := card_size.x + step * (count - 1)
	var left := (size.x - width) * 0.5
	for i in count:
		var card := cards[i]
		var from_middle := i - (count - 1) * 0.5
		fit_child_in_rect(card, Rect2(Vector2(left + step * i, ARC * from_middle * from_middle), card_size))
		card.pivot_offset = Vector2(card_size.x * 0.5, card_size.y)
		card.rotation = TILT * from_middle
