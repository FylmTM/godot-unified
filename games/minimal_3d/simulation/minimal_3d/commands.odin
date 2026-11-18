package minimal_3d

import "unified:sim"

Cmd :: union {
	Cmd_Ball_Drop,
}

Cmd_Ball_Drop :: struct {
	speed: u8,
}

apply_commands :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for _, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			switch command in sent {
			case Cmd_Ball_Drop:
				throw_ball(t, player, command.speed)
			}
		}
	}
}
