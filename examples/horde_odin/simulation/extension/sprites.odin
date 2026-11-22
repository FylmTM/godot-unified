// The enemies as animated sprites (`-- --sprites`): game/art/enemies.png, a row per kind, each enemy's clip chosen
// from the State (spawning, hurt, walking or idle) and its frame from a clock in the State (the tick it spawned), so a
// rollback replays the same frame. One sprite batch draws them all.
package horde_odin_extension

import "unified:godot"
import "unified:sim"

import g "../../../horde/simulation/horde"

SHEET_PATH :: "res://game/art/enemies.png"
SHEET_COLUMNS :: 8 // frames per kind: walk 0-3, idle 4-5, hurt 6, spawn 7
SPAWN_S :: f32(0.2) // the spawn frame shows this long
WALK_SPEED :: f32(0.2) // slower than this (units per second), an enemy idles

// What an enemy is doing, as its sprite shows it.
Pose :: enum u8 {
	Walk,
	Idle,
	Hurt,
	Spawn,
}

// Each pose's clip in a kind's row (the first frame is the row's own).
@(rodata)
POSE_CLIPS := [Pose]godot.Clip {
	.Walk = {first = 0, count = 4, fps = 8, loop = true},
	.Idle = {first = 4, count = 2, fps = 2, loop = true},
	.Hurt = {first = 6, count = 1, fps = 1},
	.Spawn = {first = 7, count = 1, fps = 1},
}

// Loads the sheet and makes its batch in `layer` (false: no sheet, and the shapes stay).
sprites_make :: proc(layer: godot.Layer) -> bool {
	texture, ok := godot.texture_load(SHEET_PATH, pixel_art = true)
	if !ok do return false
	canvas.sheet = godot.sprite_batch_create(
		layer,
		{texture = texture, columns = SHEET_COLUMNS, rows = len(g.Enemy_Kind)},
	)
	return true
}

// One enemy's sprite: its pose from the State, its frame from the clock since it spawned (each enemy a little out
// of step with the others), mirrored when it walks left.
draw_enemy_sprite :: proc(d: ^Draw, enemy: ^g.Enemy, index: u32, pos: [2]f32, flash: f32) {
	time := sim.game_time(d.state, d.tick)
	age_s := (f32(time - enemy.spawn_tick) + d.alpha) / f32(g.TICK_HZ)
	speed_sq := enemy.vel.x * enemy.vel.x + enemy.vel.y * enemy.vel.y
	pose: Pose = .Idle
	switch {
	case age_s < SPAWN_S:
		pose = .Spawn
	case flash > 0:
		pose = .Hurt
	case speed_sq > WALK_SPEED * WALK_SPEED:
		pose = .Walk
	}
	clip := POSE_CLIPS[pose]
	clip.first += i32(enemy.kind) * SHEET_COLUMNS
	phase := f32(index % 7) * 0.13
	facing: f32 = enemy.vel.x < 0 ? -1 : 1
	godot.sprite(canvas.sheet, pos, godot.clip_frame(clip, age_s + phase), {facing, 1}, flash = flash * 0.8)
}
