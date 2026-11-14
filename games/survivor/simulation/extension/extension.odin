// The survivor's GDExtension (game/survivor.gdextension -> .out/bin/libsurvivor.*): the survivor sim run by
// unified:godot_host, plus the game-specific glue: which views exist, how the State maps to them and to the
// HUD, and how InputMap actions become an Input. Built by `uni build survivor`.
package survivor_extension

import "base:runtime"
import "core:fmt"
import "core:math"
import "unified:b3"
import "unified:eos"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:godot"
import "unified:netcode"
import "unified:physics"
import "unified:sim"
import "unified:view"

import "../survivor"


@(export, link_name = "survivor_init")
survivor_init :: proc "c" (
	gpa: gdi.InterfaceGetProcAddress,
	lib: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	godot.install(&survivor.GAME, GLUE)
	godot.set_transport(&EOS_TRANSPORT)
	return godot.entry(gpa, lib, init)
}

// ---- online play: EOS (lobby codes, P2P with Epic relays), through godot_host's transport interface

// Game + net protocol version: lobby search only finds lobbies of the same bucket, so a build with another
// protocol says "no game with that code" instead of failing to connect.
SURVIVOR_BUCKET :: "survivor/7"
#assert(netcode.PROTOCOL_VERSION == 9, "netcode protocol changed: bump SURVIVOR_BUCKET with it")

@(private)
eos_init :: proc(events: ^godot.Transport_Events) -> bool {
	if eos.init({product_name = "survivor", product_version = godot.app_version}) do return true
	events.fail(events.ctx, eos.status().detail)
	return false
}

EOS_TRANSPORT := godot.Transport {
	name = "EOS",
	open_host = proc(_: rawptr, events: ^godot.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(events) do return {}, false
		link, ok := eos.open_host(SURVIVOR_BUCKET)
		if !ok do events.fail(events.ctx, eos.status().detail)
		return link, ok
	},
	open_join = proc(_: rawptr, code: string, events: ^godot.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(events) do return {}, false
		link, ok := eos.open_join(SURVIVOR_BUCKET, code)
		if !ok do events.fail(events.ctx, eos.status().detail)
		return link, ok
	},
	pump = proc(_: rawptr, events: ^godot.Transport_Events) {
		result := eos.pump()
		if result.code != "" do events.code(events.ctx, result.code)
		if result.failed != "" do events.fail(events.ctx, result.failed)
	},
	close = proc(_: rawptr) {eos.close()},
	// EOS's HTTP completes through the macOS main run loop, which headless Godot doesn't pump.
	main_frame = proc(_: rawptr) {eos.pump_main_run_loop()},
	// EOS left initialized at exit crashed in its own threads during process teardown (macOS, ~1 in 2 exits).
	shutdown = proc(_: rawptr) {eos.shutdown()},
}

// View kinds: <scene_dir>/<kind>.tscn for scene views, `kind` of the bulk views (group sim_bulk).
SCENE_PLAYER :: 0
SCENE_CRATE :: 1
SCENE_BARREL :: 2
BULK_PROJECTILE :: 3 // after the three enemy kinds (Enemy_Kind order)
BULK_GEM :: 4

BUTTON_DASH :: 0

// Events reach views by the host's default routing: a player's events (`player`) its player view, a barrel's
// explosion (`entity` = item index + 1) the barrel's view (Scene_Item.entity); enemies and gems are bulk, so
// their events (by handle) reach no view.
GLUE := godot.Glue(survivor.State, survivor.Input, survivor.World) {
	scenes = {{"player", Player_View}, {name = "crate"}, {name = "barrel"}},
	scene_dir = "res://game/views",
	bulk_kinds = {"grunt", "runner", "brute", "projectile", "gem"},
	actions = {
		move    = {"move_left", "move_right", "move_forward", "move_back"},
		buttons = {"dash"}, // level-up picks are a command: the HUD sends them (send_command(&"pick", ...))
	},
	extract = extract,
	poll_input = poll_input,
	scripted_input = survivor.scripted_input,
	scripted_commands = survivor.scripted_commands,
	hud = hud,
	constants = constants,
	bench = survivor.bench_prepare,
}

// ---- input

poll_input :: proc(actions: godot.Actions, player: int, tick: u32, state: ^survivor.State) -> (input: survivor.Input) {
	input.move_x = i8(clamp(actions.move.x, -1, 1) * 127)
	input.move_z = i8(clamp(actions.move.y, -1, 1) * 127) // Godot's get_vector: +y = move_back = +Z
	if actions.held & (1 << BUTTON_DASH) != 0 do input.buttons |= survivor.BUTTON_DASH
	return
}

// ---- frame extraction (session thread)

// Spawn keys: players 1..4 (a player's view lives for the whole session), items 0x100 + index (a destroyed
// barrel's view goes; the respawned one is a new view).
PLAYER_KEY :: 1
ITEM_KEY :: 0x100

// The player view's data (Scene_Kind.data): set as its properties when it changes.
Player_View :: struct {
	hp: i32,
}

extract :: proc(current, previous: ^survivor.State, world: ^survivor.World, out: ^godot.Frame) {
	for player in 0 ..< survivor.PLAYERS {
		character := &current.players[player]
		if !character.active do continue
		item := godot.Scene_Item {
			key    = view.Key(PLAYER_KEY + player),
			kind   = SCENE_PLAYER,
			player = i8(player),
			pos    = character.pos,
		}
		if previous != nil && previous.players[player].active && previous.players[player].alive == character.alive {
			item.has_prev = true
			item.prev_pos = previous.players[player].pos
		}
		godot.push_scene(out, item, Player_View{hp = max(character.hp, 0)})
	}
	for i in 0 ..< survivor.ITEM_COUNT {
		item := &current.items[i]
		if !item.alive do continue
		body := physics.body_id(world.phys, item.body)
		body_pos := b3.body_get_position(body)
		godot.push_scene(
			out,
			{
				key    = view.Key(ITEM_KEY + i),
				kind   = item.kind == .Barrel ? SCENE_BARREL : SCENE_CRATE,
				player = -1,
				entity = u64(i + 1), // barrel_exploded's entity: item index + 1
				pos    = {body_pos.x, body_pos.y, body_pos.z},
				rot    = b3.body_get_rotation(body),
			},
		)
	}
	// enemies (one bulk kind per Enemy_Kind)
	enemies := sim.iterate(&current.enemies)
	for enemy, handle in sim.next(&enemies) {
		bulk := godot.Bulk_Item {
			kind   = u8(enemy.kind),
			pos    = {enemy.pos.x, 0, enemy.pos.y},
			yaw    = enemy_yaw(enemy.vel),
			custom = {hit_flash(out.tick, enemy.hit_tick), age_s(out.tick, enemy.spawn_tick), 0, 0},
		}
		previous_table := previous != nil ? &previous.enemies : nil
		if before, ok := sim.prev_item(previous_table, &current.enemies, int(handle.index)); ok {
			bulk.has_prev = true
			bulk.prev_pos = {before.pos.x, 0, before.pos.y}
			bulk.prev_yaw = enemy_yaw(before.vel)
		}
		if !godot.push_bulk(out, bulk) do break
	}
	projectiles := sim.iterate(&current.projectiles)
	for projectile, handle in sim.next(&projectiles) {
		bulk := godot.Bulk_Item {
			kind = BULK_PROJECTILE,
			pos  = {projectile.pos.x, 0, projectile.pos.z}, // bulk meshes are lifted in the game's shader
			yaw  = math.atan2(projectile.vel.x, projectile.vel.z),
		}
		previous_table := previous != nil ? &previous.projectiles : nil
		if before, ok := sim.prev_item(previous_table, &current.projectiles, int(handle.index)); ok {
			bulk.has_prev = true
			bulk.prev_pos = {before.pos.x, 0, before.pos.z}
			bulk.prev_yaw = math.atan2(before.vel.x, before.vel.z)
		}
		if !godot.push_bulk(out, bulk) do break
	}
	gems := sim.iterate(&current.gems)
	for gem in sim.next(&gems) {
		godot.push_bulk(
			out,
			{kind = BULK_GEM, pos = {gem.pos.x, 0, gem.pos.y}, custom = {0, age_s(out.tick, gem.spawn_tick), 0, 0}},
		) or_break
	}
	(^Hud)(&out.hud[0])^ = hud_of(current, out.tick)
}

#assert(size_of(Hud) <= godot.HUD_BYTES)

HIT_FLASH_S :: 0.15

enemy_yaw :: proc(vel: [2]f32) -> f32 {
	return (vel.x != 0 || vel.y != 0) ? math.atan2(vel.x, vel.y) : 0
}

// Bulk custom data (the game's shaders): r = hit flash 1 -> 0 over HIT_FLASH_S, g = age in seconds.
hit_flash :: proc(tick, hit_tick: u32) -> f32 {
	if hit_tick == 0 || tick < hit_tick do return 0
	return max(0, 1 - f32(tick - hit_tick) * survivor.DT / HIT_FLASH_S)
}

age_s :: proc(tick, spawn_tick: u32) -> f32 {
	return tick > spawn_tick ? f32(tick - spawn_tick) * survivor.DT : 0
}

// ---- HUD (contract v0): hud_of (hud.odin) on the session thread, a Dictionary on the main thread

hud :: proc(frame: ^godot.Frame, dict: ^gd.Dictionary) {
	if frame == nil { 	// no session yet: every key, empty
		gd.dict_set(dict, "phase", "lobby")
		gd.dict_set(dict, "tick", 0)
		gd.dict_set(dict, "time_s", 0.0)
		gd.dict_set(dict, "wave", 0)
		gd.dict_set(dict, "enemies_alive", 0)
		gd.dict_set(dict, "circle_radius", 0.0)
		gd.dict_set(dict, "matches", 0)
		gd.dict_set(dict, "local_player", -1)
		empty := gd.array_new()
		gd.dict_set_move(dict, "players", &empty)
		return
	}
	data := (^Hud)(&frame.hud[0])
	gd.dict_set(dict, "phase", data.phase_name)
	gd.dict_set(dict, "tick", i64(data.tick))
	gd.dict_set(dict, "time_s", f64(data.time_s))
	gd.dict_set(dict, "wave", i64(data.wave))
	gd.dict_set(dict, "enemies_alive", i64(data.enemies_alive))
	gd.dict_set(dict, "circle_radius", f64(data.circle_radius))
	gd.dict_set(dict, "matches", i64(data.matches))
	gd.dict_set(dict, "local_player", i64(frame.local_player))
	players := gd.array_new()
	for &player in data.players {
		info := gd.dict_new()
		gd.dict_set(&info, "player", i64(player.player))
		gd.dict_set(&info, "present", player.present)
		gd.dict_set(&info, "alive", player.alive)
		gd.dict_set(&info, "hp", i64(player.hp))
		gd.dict_set(&info, "hp_max", i64(player.hp_max))
		gd.dict_set(&info, "xp", i64(player.xp))
		gd.dict_set(&info, "xp_next", i64(player.xp_next))
		gd.dict_set(&info, "level", i64(player.level))
		gd.dict_set(&info, "pending_levelups", i64(player.pending_levelups))
		gd.dict_set(&info, "respawn_s", f64(player.respawn_s))
		if name := godot.frame_player_name(frame, player.player); name != "" do gd.dict_set(&info, "name", name)
		gd.array_push_move(&players, &info)
	}
	gd.dict_set_move(dict, "players", &players)
}

// ---- constants for the scripts (UnifiedSession.constants()), from the sim's own definitions

UPGRADE_NAMES := [3]string{"Fire rate", "Damage", "Move speed"}

constants :: proc(dict: ^gd.Dictionary) {
	gd.dict_set(dict, "over_hold_s", f64(survivor.OVER_HOLD_S))
	gd.dict_set(dict, "arena_half", f64(survivor.ARENA_HALF))
	gd.dict_set(dict, "start_radius", f64(survivor.START_RADIUS))
	gd.dict_set(dict, "dash_cooldown_s", f64(survivor.DASH_COOLDOWN_S))
	gd.dict_set(dict, "player_respawn_s", f64(survivor.PLAYER_RESPAWN_S))
	gd.dict_set(dict, "max_enemies", i64(survivor.MAX_ENEMIES))
	// level-up options in survivor.Upgrade order: the HUD's card i sends send_command(&"pick", {"upgrade": i})
	upgrades := gd.array_new()
	details := [3]string {
		"Shoot more often",
		fmt.tprintf("+%d damage per shot", survivor.DAMAGE_LEVELUP),
		fmt.tprintf("+%.1f m/s", survivor.SPEED_LEVELUP),
	}
	for name, i in UPGRADE_NAMES {
		upgrade := gd.dict_new()
		gd.dict_set(&upgrade, "name", name)
		gd.dict_set(&upgrade, "detail", details[i])
		gd.array_push_move(&upgrades, &upgrade)
	}
	gd.dict_set_move(dict, "upgrades", &upgrades)
	// the item grid as the match starts (crates and barrels; the menu backdrop shows it)
	items := gd.array_new()
	for i in 0 ..< survivor.ITEM_COUNT {
		spot := survivor.item_position(i)
		item := gd.dict_new()
		gd.dict_set(&item, "position", gd.Vector3{spot.x, spot.y, spot.z})
		gd.dict_set(&item, "kind", survivor.item_kind(i) == .Barrel ? "barrel" : "crate")
		gd.array_push_move(&items, &item)
	}
	gd.dict_set_move(dict, "items", &items)
}
