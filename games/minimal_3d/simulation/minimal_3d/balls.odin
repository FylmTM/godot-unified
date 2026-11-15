package minimal_3d

import "unified:sim"

MAX_BALLS :: 64
GRAVITY :: f32(9.8) // metres per second squared, down
HAND_HEIGHT :: f32(1.8) // where a ball leaves the player, metres above the ground
BALL_RADIUS :: f32(0.2) // metres: a ball is gone when its centre is this low

throw_ball :: proc(t: ^Tick, player: sim.Player, speed: u8) {
	ball, _, ok := sim.spawn(&t.state.balls)
	if !ok do return
	ball^ = {
		pos            = sim.player_data(&t.state.players, player).position,
		height         = HAND_HEIGHT,
		vertical_speed = f32(speed),
		thrower        = player,
	}
	sim.emit(t, Event_Ball_Dropped{player = player, speed = speed})
}

move_balls :: proc(t: ^Tick) {
	balls := sim.iterate(&t.state.balls)
	for ball, handle in sim.next(&balls) {
		ball.vertical_speed -= GRAVITY * DT
		ball.height += ball.vertical_speed * DT
		if ball.height <= BALL_RADIUS do sim.despawn(&t.state.balls, handle)
	}
}
