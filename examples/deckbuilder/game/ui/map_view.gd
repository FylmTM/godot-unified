class_name MapView
extends Control
## The act's map on the map panel: its floors bottom to top, a node per lane that has one (a MapNode button with its
## kind's glyph), the paths between them (a node leads to the next floor's nodes in its lane and the lanes beside it),
## the party's node ringed, the next floor's nodes the party may vote for lit and clickable, and each hero's vote as a
## dot in their colour. A click votes (the `voted` signal); the table sends the command.

signal voted(lane: int)

const FLOOR_GAP := 46.0
const LANE_GAP := 120.0
const NODE := 40.0

var _nodes: Array[MapNode] = []  # floor * lanes + lane (null where no node)
var _run: DataRun


## Shows the run's map, where the party is and the votes.
func show_run(run: DataRun) -> void:
	_run = run
	var floors: int = Unified.constants.floors
	var lanes: int = Unified.constants.lanes
	custom_minimum_size = Vector2(LANE_GAP * lanes, FLOOR_GAP * floors + 8)
	if _nodes.is_empty():
		for i in floors * lanes:
			var node := MapNode.new()
			node.lane = i % lanes
			node.pressed.connect(func() -> void: voted.emit(node.lane))
			add_child(node)
			_nodes.append(node)
	var next := 0 if run.floor == 255 else run.floor + 1
	for i in _nodes.size():
		@warning_ignore("integer_division")
		var row := i / lanes
		var node := _nodes[i]
		node.kind = run.map_nodes[i]
		node.visible = node.kind != EnumNodeKind.NONE
		node.position = _at(row, node.lane) - Vector2(NODE, NODE) * 0.5
		node.size = Vector2(NODE, NODE)
		node.here = row == run.floor and node.lane == run.lane
		node.passed = row < next and not node.here
		node.disabled = not (row == next and run.can_go[node.lane])
		node.votes = []
		if row == next:
			for hero in 4:
				var hero_row: DataHeroRow = Unified.data.heroes.heroes[hero]
				if hero_row.in_run and hero_row.vote == node.lane + 1:
					node.votes.append(hero)
		node.tooltip_text = EnumNodeKind.name(node.kind).capitalize()
		node.queue_redraw()
	queue_redraw()


## The map's buttons the party may vote for now.
func open_nodes() -> Array[MapNode]:
	var open: Array[MapNode] = []
	for node in _nodes:
		if node.visible and not node.disabled:
			open.append(node)
	return open


## A node's centre: floor 0 at the bottom.
func _at(row: int, lane: int) -> Vector2:
	var floors: int = Unified.constants.floors
	return Vector2(LANE_GAP * (lane + 0.5), FLOOR_GAP * (floors - row - 0.5) + 4)


func _draw() -> void:
	if _run == null:
		return
	var lanes: int = Unified.constants.lanes
	var floors: int = Unified.constants.floors
	for row in floors - 1:
		for lane in lanes:
			if _run.map_nodes[row * lanes + lane] == EnumNodeKind.NONE:
				continue
			for to in range(maxi(lane - 1, 0), mini(lane + 2, lanes)):
				if _run.map_nodes[(row + 1) * lanes + to] == EnumNodeKind.NONE:
					continue
				var walked := row < _run.floor if _run.floor != 255 else false
				var color := Color(UiTheme.LINE, 0.9) if not walked else Color(UiTheme.TEXT_DIM, 0.35)
				_dashes(_at(row, lane), _at(row + 1, to), color)


## A dotted path from `a` to `b`, stopping short of both nodes.
func _dashes(a: Vector2, b: Vector2, color: Color) -> void:
	var along := b - a
	var length := along.length()
	var unit := along / length
	var t := NODE * 0.55
	while t < length - NODE * 0.55:
		draw_line(a + unit * t, a + unit * minf(t + 5.0, length - NODE * 0.55), color, 2.5, true)
		t += 10.0
