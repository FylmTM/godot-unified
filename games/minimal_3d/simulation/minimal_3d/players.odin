package minimal_3d

import "unified:sim"

MOVE_SPEED :: f32(4) // metres per second at full input

on_player_join :: proc(t: ^Tick) {
	for player in t.player_changes.joined {
		slot, _ := sim.player_slot(&t.state.players, player)
		player_data := sim.player_data(&t.state.players, player)
		player_data.position = {f32(slot), 0}
	}
}

move_players :: proc(t: ^Tick) {
	players := sim.iterate_present(&t.state.players)
	for data, player in sim.next(&players) {
		input := sim.input(t, player)

		data.position.x += f32(input.dx) / 127 * MOVE_SPEED * DT
		data.position.y += f32(input.dy) / 127 * MOVE_SPEED * DT
	}
}
