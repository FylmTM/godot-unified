package minimal_3d

import "unified:sim"

MAX_BALLS :: 64
GRAVITY :: f32(9.8) // metres per second squared, down
HAND_HEIGHT :: f32(1.8) // where a ball leaves the player, metres above the ground
BALL_RADIUS :: f32(0.2) // metres: a ball is gone when its centre is this low

// Each present player's `Cmd_Throw_Ball` throws a ball.
throw_balls :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for _, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			switch command in sent {
			case Cmd_Throw_Ball:
				throw_ball(t, player, command.speed)
			}
		}
	}
}

// A ball from `player`'s position, owned by them. With MAX_BALLS in the air it is lost, and no event says so.
throw_ball :: proc(t: ^Tick, player: sim.Player, speed: u8) {
	ball, _, ok := sim.spawn(&t.state.balls)
	if !ok do return
	capped := speed if speed <= THROW_SPEED_MAX else THROW_SPEED_MAX
	ball^ = {
		pos            = sim.player_data(t, player).position,
		height         = HAND_HEIGHT,
		vertical_speed = f32(capped),
		thrower        = player,
	}
	sim.emit(t, Event_Ball_Thrown{player = player, speed = capped})
}

move_balls :: proc(t: ^Tick) {
	balls := sim.iterate(&t.state.balls)
	for ball, handle in sim.next(&balls) {
		ball.vertical_speed -= GRAVITY * t.dt
		ball.height += ball.vertical_speed * t.dt
		if ball.height <= BALL_RADIUS do sim.despawn(&t.state.balls, handle)
	}
}
