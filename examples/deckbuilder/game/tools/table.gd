class_name Table
## What deckbuilder's tool scripts (ui_walk.gd, coop.gd) read off the table (game/main.tscn): its panel and buttons,
## the local hand and the local hero.


## The phase panel's title ("" while the panel is hidden or the table isn't loaded).
static func title(scene: Node) -> String:
	var overlay := _node(scene, ^"%Overlay") as Control
	return (_node(scene, ^"%Title") as Label).text if overlay != null and overlay.visible else ""


## The first button in the phase's panel whose text starts with `prefix` (null: none).
static func button(scene: Node, prefix: String) -> Button:
	for found: Button in _buttons(scene):
		if found.text.begins_with(prefix):
			return found
	return null


## The map's first lane the party may vote for (null: none).
static func open_lane(scene: Node) -> Button:
	for found: Button in _buttons(scene):
		if found.get_parent() is GridContainer and not found.disabled:
			return found
	return null


## The local hand's cards (a played or discarded card fading out included).
static func hand(scene: Node) -> Array[Node]:
	var local_hand := _node(scene, ^"%LocalHand")
	return local_hand.get_children() if local_hand != null else []


## The local hand's first card playable now at `target` (an EnumTargetKind value; null: none).
static func playable(scene: Node, target: int) -> DeckCard:
	for node: Node in hand(scene):
		var card := node as DeckCard
		if card != null and card.data.playable and card.data.target == target and card.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			return card
	return null


## The local hero's row (null: none, at the camp or watching).
static func local_row() -> DataHeroRow:
	var local: int = Unified.data.run.local_hero
	return Unified.data.heroes.heroes[local] as DataHeroRow if local >= 0 else null


static func _buttons(scene: Node) -> Array[Button]:
	var out: Array[Button] = []
	var body := _node(scene, ^"%Body")
	if body != null:
		for node: Node in body.find_children("*", "Button", true, false):
			if not node.is_queued_for_deletion():
				out.append(node as Button)
	return out


static func _node(scene: Node, path: NodePath) -> Node:
	return scene.get_node_or_null(path) if scene != null else null
