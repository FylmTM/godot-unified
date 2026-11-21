class_name Table
## What deckbuilder's tool scripts (ui_walk.gd, coop.gd) read off the table (game/table.tscn): its panel and buttons,
## the map's open nodes, the reward's cards, the local hand and the local hero.


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


## The map's first node the party may vote for (null: none).
static func open_lane(scene: Node) -> Button:
	var map := _node(scene, ^"%Body/Map") as MapView
	if map == null or map.is_queued_for_deletion():
		return null
	var open := map.open_nodes()
	return open[0] if not open.is_empty() else null


## The reward's first card (null: none on show).
static func first_offer(scene: Node) -> Button:
	var offers := _node(scene, ^"%Body/Offers")
	if offers == null or offers.is_queued_for_deletion() or offers.get_child_count() == 0:
		return null
	return offers.get_child(0) as Button


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
