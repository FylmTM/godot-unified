package friendslop

import "unified:physics"

// Advances each platform along its path (by its mode, and while its trigger is active when it has one) and drives its
// kinematic body to the pose for its phase, a pure function of the platform's state.
move_platforms :: proc(t: ^Tick) {
	for i in 0 ..< t.world.platform_count {
		def := &t.world.platforms[i]
		platform := &t.state.platforms[i]
		total := physics.path_duration_ticks(&def.path, TICK_HZ)
		active := def.trigger < 0 || t.state.triggers[def.trigger].active
		switch def.mode {
		case .Ping_Pong, .Loop:
			if active do platform.running = true
			if platform.running do platform.phase += 1
		case .Once:
			if active do platform.running = true
			if platform.running && platform.phase < total do platform.phase += 1
		case .Follow:
			if active && platform.phase < total do platform.phase += 1
			if !active && platform.phase > 0 do platform.phase -= 1
		}
		target := def.origin + (physics.path_sample(&def.path, platform.phase, TICK_HZ) - def.path.points[0])
		physics.drive_kinematic(t.world.phys, platform.body, target)
	}
}
