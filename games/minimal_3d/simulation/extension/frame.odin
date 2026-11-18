package extension

import "unified:godot"
import "unified:sim"

import g "../minimal_3d"

Frame :: godot.Frame(g.Game, View, MultiView)

View :: enum u8 {
	Player,
}

MultiView :: enum u8 {
	Ball,
}

PLAYER_COLORS := [g.PLAYERS]godot.Color {
	{1, 0.4, 0.4, 1},
	{0.7, 1, 0.4, 1},
	{0.4, 1, 1, 1},
	{0.7, 0.4, 1, 1},
}

GONE_COLOR :: godot.Color{0.5, 0.5, 0.5, 1}

Player_View_Data :: struct {
	color: godot.Color,
}

Data :: union {
	Data_Hud,
}

Data_Hud :: struct {
	players: u32,
	balls:   u32,
	color:   godot.Color,
}

fill_frame :: proc(f: ^Frame) {
	fill_frame_players(f)
	fill_frame_balls(f)
	fill_frame_hud(f)
}

fill_frame_players :: proc(f: ^Frame) {
	players := sim.iterate_present(&f.state.players)
	for data, player in sim.next(&players) {
		slot := sim.player_slot(&f.state.players, player)
		godot.push_view(f, player, {
			kind = .Player,
			pos  = {data.position.x, 0, data.position.y},
		}, Player_View_Data{color = PLAYER_COLORS[slot]})
	}
}

fill_frame_balls :: proc(f: ^Frame) {
	balls := sim.iterate(&f.state.balls)
	for ball, handle in sim.next(&balls) {
		godot.push_multi_view(f, {
			key   = sim.handle_key(handle),
			kind  = .Ball,
			pos   = {ball.pos.x, ball.height, ball.pos.y},
			color = player_color(f, ball.thrower),
		})
	}
}

fill_frame_hud :: proc(f: ^Frame) {
	godot.push_data(f, Data_Hud {
		players = u32(sim.present_count(&f.state.players)),
		balls   = u32(f.state.balls.count),
		color   = player_color(f, f.local_player),
	})
}

player_color :: proc(f: ^Frame, player: sim.Player) -> godot.Color {
	slot, present := sim.player_slot(&f.state.players, player)
	return PLAYER_COLORS[slot] if present else GONE_COLOR
}
