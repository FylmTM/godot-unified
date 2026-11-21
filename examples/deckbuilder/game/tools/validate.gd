extends UnifiedValidate
## deckbuilder's project check (the library's UnifiedValidate) and what its scripts assume: the play scene is the table
## (the main scene is the menu), and every card the table can draw has its rules text and a glyph of its own kind, from
## the sim's constants (a reward's or a rest's card has no view: its face is drawn from them alone).

const TABLE_SCENE := "res://game/table.tscn"


func _play_scene() -> String:
	return TABLE_SCENE


func _check_contract() -> String:
	var constants := Unified.constants
	for id in range(1, EnumCardId.names().size()):
		var card: DataCardText = constants.cards[id]
		if card.text == "" or card.upgraded == "":
			log_capture.add("card %s has no rules text" % EnumCardId.name(id), TABLE_SCENE)
		if Glyph.of_card(id) not in Glyph.KINDS:
			log_capture.add("card %s has no glyph" % EnumCardId.name(id), TABLE_SCENE)
	for kind in EnumEnemyKind.names().size():
		if Glyph.of_enemy(kind) not in Glyph.KINDS:
			log_capture.add("enemy %s has no emblem" % EnumEnemyKind.name(kind), TABLE_SCENE)
	if constants.floors <= 0 or constants.lanes <= 0:
		log_capture.add("the map has no floors or lanes", TABLE_SCENE)
	return "ok"
