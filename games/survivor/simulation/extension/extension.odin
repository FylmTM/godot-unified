// The survivor's GDExtension (game/survivor.gdextension -> .out/bin/libsurvivor.*): the survivor sim run by
// unified:godot_host, plus the game-specific glue: which views exist, how the State maps to them and to the
// HUD, and how InputMap actions become an Input. Built by `uni build survivor`.
package survivor_extension

import "base:runtime"
import "core:fmt"
import "core:math"
import b3 "unified:box3d_port"
import "unified:eos"
import gd "unified:gdext"
import "unified:gdext/gdi"
import gh "unified:godot_host"
import "unified:netcode"
import "unified:physics"
import "unified:sim"
import "unified:view"

import "../survivor"

S :: survivor.State

@(export, link_name = "survivor_init")
survivor_init :: proc "c" (
	gpa: gdi.InterfaceGetProcAddress,
	lib: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	gh.install(&survivor.GAME, GLUE)
	gh.set_transport(&EOS_TRANSPORT)
	return gh.entry(gpa, lib, init)
}

// ---- online play: EOS (lobby codes, P2P with Epic relays), through godot_host's transport interface

// Game + net protocol version: lobby search only finds lobbies of the same bucket, so a build with another
// protocol says "no game with that code" instead of failing to connect.
SURVIVOR_BUCKET :: "survivor/5"
#assert(netcode.PROTOCOL_VERSION == 7, "netcode protocol changed: bump SURVIVOR_BUCKET with it")

@(private)
eos_init :: proc(ev: ^gh.Transport_Events) -> bool {
	if eos.init({product_name = "survivor", product_version = gh.app_version}) do return true
	ev.fail(ev.ctx, eos.status().detail)
	return false
}

EOS_TRANSPORT := gh.Transport {
	name = "EOS",
	open_host = proc(_: rawptr, ev: ^gh.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(ev) do return {}, false
		l, ok := eos.open_host(SURVIVOR_BUCKET)
		if !ok do ev.fail(ev.ctx, eos.status().detail)
		return l, ok
	},
	open_join = proc(_: rawptr, code: string, ev: ^gh.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(ev) do return {}, false
		l, ok := eos.open_join(SURVIVOR_BUCKET, code)
		if !ok do ev.fail(ev.ctx, eos.status().detail)
		return l, ok
	},
	pump = proc(_: rawptr, ev: ^gh.Transport_Events) {
		r := eos.pump()
		if r.code != "" do ev.code(ev.ctx, r.code)
		if r.failed != "" do ev.fail(ev.ctx, r.failed)
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

GLUE := gh.Glue(survivor.State, survivor.Input, survivor.World) {
	scenes = {{"player", Player_View}, {name = "crate"}, {name = "barrel"}},
	scene_dir = "res://game/views",
	bulk_kinds = {"grunt", "runner", "brute", "projectile", "gem"},
	actions = {
		move    = {"move_left", "move_right", "move_forward", "move_back"},
		buttons = {"dash"}, // level-up picks are a command: the HUD sends them (send_command(&"pick", ...))
	},
	extract = extract,
	sample = sample,
	scripted = proc(seed: u64, slot: int, tick: u32, state: ^S) -> survivor.Input {
		return survivor.script(seed, slot, tick, state)
	},
	scripted_commands = survivor.script_commands,
	hud = hud,
	constants = constants,
	event_key = event_key,
	bench = survivor.bench_prepare,
}

// Which scene view an event belongs to: player events (slot set) -> that player's view, barrel explosions
// -> the barrel (entity = item index + 1); enemy and gem events have no scene view (bulk).
event_key :: proc(e: sim.Event) -> view.Key {
	if e.slot != sim.NO_SLOT do return view.Key(PLAYER_KEY + int(e.slot))
	if survivor.Event_Kind(e.kind) == .Barrel_Exploded && e.entity >= 1 do return view.Key(ITEM_KEY + int(e.entity) - 1)
	return 0
}

// ---- input

sample :: proc(a: gh.Actions, slot: int, tick: u32, state: ^S) -> survivor.Input {
	in_: survivor.Input
	in_.move_x = i8(clamp(a.move.x, -1, 1) * 127)
	in_.move_z = i8(clamp(a.move.y, -1, 1) * 127) // Godot's get_vector: +y = move_back = +Z
	if a.held & (1 << BUTTON_DASH) != 0 do in_.buttons |= survivor.BUTTON_DASH
	return in_
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

extract :: proc(cur, prev: ^S, w: ^survivor.World, out: ^gh.Frame) {
	for p in 0 ..< survivor.MAX_PLAYERS {
		pl := &cur.players[p]
		if !pl.active do continue
		it := gh.Scene_Item {
			key  = view.Key(PLAYER_KEY + p),
			kind = SCENE_PLAYER,
			slot = i8(p),
			pos  = pl.pos,
		}
		if prev != nil && prev.players[p].active && prev.players[p].alive == pl.alive {
			it.has_prev = true
			it.prev_pos = prev.players[p].pos
		}
		gh.push_scene(out, it, Player_View{hp = max(pl.hp, 0)})
	}
	for i in 0 ..< survivor.ITEM_COUNT {
		item := &cur.items[i]
		if !item.alive do continue
		id := physics.body_id(w.phys, item.body)
		p := b3.Body_GetPosition(id)
		q := b3.Body_GetRotation(id)
		gh.push_scene(
			out,
			{
				key    = view.Key(ITEM_KEY + i),
				kind   = item.kind == .Barrel ? SCENE_BARREL : SCENE_CRATE,
				slot   = -1,
				entity = u32(i + 1), // barrel_exploded's entity: item index + 1
				pos    = {p.x, p.y, p.z},
				rot    = {q.v.x, q.v.y, q.v.z, q.s},
			},
		)
	}
	// enemies (one bulk kind per Enemy_Kind)
	pv := prev
	en := &cur.enemies
	for idx in 0 ..< en.high_water {
		e := sim.at(en, idx) or_continue
		b := gh.Bulk_Item {
			kind   = u8(e.kind),
			pos    = {e.pos.x, 0, e.pos.y},
			yaw    = enemy_yaw(e.vel),
			custom = {hit_flash(out.tick, e.hit_tick), age_s(out.tick, e.spawn_tick), 0, 0},
		}
		if pe, ok := sim.prev_item(pv != nil ? &pv.enemies : nil, en, idx); ok {
			b.has_prev = true
			b.prev_pos = {pe.pos.x, 0, pe.pos.y}
			b.prev_yaw = enemy_yaw(pe.vel)
		}
		if !gh.push_bulk(out, b) do break
	}
	pr := &cur.projectiles
	for idx in 0 ..< pr.high_water {
		pj := sim.at(pr, idx) or_continue
		b := gh.Bulk_Item {
			kind = BULK_PROJECTILE,
			pos  = {pj.pos.x, 0, pj.pos.z}, // bulk meshes are lifted in the game's shader
			yaw  = math.atan2(pj.vel.x, pj.vel.z),
		}
		if pp, ok := sim.prev_item(pv != nil ? &pv.projectiles : nil, pr, idx); ok {
			b.has_prev = true
			b.prev_pos = {pp.pos.x, 0, pp.pos.z}
			b.prev_yaw = math.atan2(pp.vel.x, pp.vel.z)
		}
		if !gh.push_bulk(out, b) do break
	}
	gm := &cur.gems
	for idx in 0 ..< gm.high_water {
		g := sim.at(gm, idx) or_continue
		gh.push_bulk(
			out,
			{kind = BULK_GEM, pos = {g.pos.x, 0, g.pos.y}, custom = {0, age_s(out.tick, g.spawn_tick), 0, 0}},
		) or_break
	}
	(^Hud)(&out.hud[0])^ = hud_of(cur, out.tick)
}

#assert(size_of(Hud) <= gh.HUD_BYTES)

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

hud :: proc(f: ^gh.Frame, d: ^gd.Dictionary) {
	if f == nil { 	// no session yet: every key, empty
		gd.dict_set(d, "phase", "lobby")
		gd.dict_set(d, "tick", 0)
		gd.dict_set(d, "time_s", 0.0)
		gd.dict_set(d, "wave", 0)
		gd.dict_set(d, "enemies_alive", 0)
		gd.dict_set(d, "circle_radius", 0.0)
		gd.dict_set(d, "matches", 0)
		gd.dict_set(d, "local_slot", -1)
		empty := gd.array_new()
		gd.dict_set_move(d, "players", &empty)
		return
	}
	h := (^Hud)(&f.hud[0])
	gd.dict_set(d, "phase", h.phase_name)
	gd.dict_set(d, "tick", i64(h.tick))
	gd.dict_set(d, "time_s", f64(h.time_s))
	gd.dict_set(d, "wave", i64(h.wave))
	gd.dict_set(d, "enemies_alive", i64(h.enemies_alive))
	gd.dict_set(d, "circle_radius", f64(h.circle_radius))
	gd.dict_set(d, "matches", i64(h.matches))
	gd.dict_set(d, "local_slot", i64(f.local_slot))
	players := gd.array_new()
	for &p in h.players {
		pd := gd.dict_new()
		gd.dict_set(&pd, "slot", i64(p.slot))
		gd.dict_set(&pd, "present", p.present)
		gd.dict_set(&pd, "alive", p.alive)
		gd.dict_set(&pd, "hp", i64(p.hp))
		gd.dict_set(&pd, "hp_max", i64(p.hp_max))
		gd.dict_set(&pd, "xp", i64(p.xp))
		gd.dict_set(&pd, "xp_next", i64(p.xp_next))
		gd.dict_set(&pd, "level", i64(p.level))
		gd.dict_set(&pd, "pending_levelups", i64(p.pending_levelups))
		gd.dict_set(&pd, "respawn_s", f64(p.respawn_s))
		if name := gh.frame_player_name(f, p.slot); name != "" do gd.dict_set(&pd, "name", name)
		gd.array_push_move(&players, &pd)
	}
	gd.dict_set_move(d, "players", &players)
}

// ---- constants for the scripts (UnifiedSession.constants()), from the sim's own definitions

UPGRADE_NAMES := [3]string{"Fire rate", "Damage", "Move speed"}

constants :: proc(d: ^gd.Dictionary) {
	gd.dict_set(d, "over_hold_s", f64(survivor.OVER_HOLD_S))
	gd.dict_set(d, "arena_half", f64(survivor.ARENA_HALF))
	gd.dict_set(d, "start_radius", f64(survivor.START_RADIUS))
	gd.dict_set(d, "dash_cooldown_s", f64(survivor.DASH_COOLDOWN_S))
	gd.dict_set(d, "player_respawn_s", f64(survivor.PLAYER_RESPAWN_S))
	gd.dict_set(d, "max_enemies", i64(survivor.MAX_ENEMIES))
	// level-up options in survivor.Upgrade order: the HUD's card i sends send_command(&"pick", {"upgrade": i})
	ups := gd.array_new()
	details := [3]string {
		"Shoot more often",
		fmt.tprintf("+%d damage per shot", survivor.DAMAGE_LEVELUP),
		fmt.tprintf("+%.1f m/s", survivor.SPEED_LEVELUP),
	}
	for name, i in UPGRADE_NAMES {
		u := gd.dict_new()
		gd.dict_set(&u, "name", name)
		gd.dict_set(&u, "detail", details[i])
		gd.array_push_move(&ups, &u)
	}
	gd.dict_set_move(d, "upgrades", &ups)
	// the item grid as the match starts (crates and barrels; the menu backdrop shows it)
	items := gd.array_new()
	for i in 0 ..< survivor.ITEM_COUNT {
		p := survivor.item_position(i)
		it := gd.dict_new()
		gd.dict_set(&it, "position", gd.Vector3{p.x, p.y, p.z})
		gd.dict_set(&it, "kind", survivor.item_kind(i) == .Barrel ? "barrel" : "crate")
		gd.array_push_move(&items, &it)
	}
	gd.dict_set_move(d, "items", &items)
}
