// The survivor's GDExtension (game/survivor.gdextension -> .uni/bin/libsurvivor.*): the survivor sim run by
// unified:godot_host, plus the game-specific glue: which views exist, how the State maps to them and to the
// HUD, and how InputMap actions become an Input. Built by `python tools/dev.py game build survivor`.
package survivor_extension

import "base:runtime"
import "core:math"
import b3 "unified:box3d"
import gd "unified:gdext"
import "unified:gdext/gdi"
import gh "unified:godot_host"
import "unified:physics"
import "unified:view"

import "../survivor"

S :: survivor.State

@(export, link_name = "survivor_init")
survivor_init :: proc "c" (gpa: gdi.InterfaceGetProcAddress, lib: gdi.ClassLibraryPtr, init: ^gdi.Initialization) -> gdi.Bool {
	context = runtime.default_context()
	gh.install(&survivor.GAME, GLUE)
	return gh.entry(gpa, lib, init)
}

// View kinds: res://game/views/<kind>.tscn for scene views, `kind` of the bulk views (group sim_bulk).
SCENE_PLAYER :: 0
SCENE_CRATE :: 1
SCENE_BARREL :: 2
BULK_PROJECTILE :: 3 // after the three enemy kinds (Enemy_Kind order)
BULK_GEM :: 4

BUTTON_DASH :: 0
BUTTON_LEVELUP_1 :: 1

GLUE := gh.Glue(survivor.State, survivor.Input, survivor.World) {
	scene_kinds = {"player", "crate", "barrel"},
	bulk_kinds = {"grunt", "runner", "brute", "projectile", "gem"},
	actions = {
		move = {"move_left", "move_right", "move_forward", "move_back"},
		buttons = {"dash", "levelup_1", "levelup_2", "levelup_3"},
	},
	extract = extract,
	sample = sample,
	scripted = proc(seed: u64, slot: int, tick: u32, state: ^S) -> survivor.Input {
		return survivor.script(seed, slot, tick, state)
	},
	hud = hud,
}

// ---- input

sample :: proc(a: gh.Actions, slot: int, tick: u32, state: ^S) -> survivor.Input {
	in_: survivor.Input
	in_.move_x = i8(clamp(a.move.x, -1, 1) * 127)
	in_.move_z = i8(clamp(a.move.y, -1, 1) * 127) // Godot's get_vector: +y = move_back = +Z
	if a.held & (1 << BUTTON_DASH) != 0 do in_.buttons |= survivor.BUTTON_DASH
	for k in 0 ..< 3 {
		if a.pressed & (1 << u32(BUTTON_LEVELUP_1 + k)) != 0 {
			in_.choice = u8(k + 1)
			break
		}
	}
	return in_
}

// ---- frame extraction (session thread)

// Spawn keys: players 1..4 (a player's view lives for the whole session), items 0x100 + index (a destroyed
// barrel's view goes; the respawned one is a new view).
PLAYER_KEY :: 1
ITEM_KEY :: 0x100

extract :: proc(cur, prev: ^S, w: ^survivor.World, out: ^gh.Frame) {
	for p in 0 ..< survivor.MAX_PLAYERS {
		pl := &cur.players[p]
		if !pl.active || out.n_scene >= gh.MAX_SCENE_ITEMS do continue
		it := &out.scene[out.n_scene]
		out.n_scene += 1
		it^ = {
			key  = view.Key(PLAYER_KEY + p),
			kind = SCENE_PLAYER,
			slot = i8(p),
			pos  = pl.pos,
		}
		if prev != nil && prev.players[p].active && prev.players[p].alive == pl.alive {
			it.has_prev = true
			it.prev_pos = prev.players[p].pos
		}
	}
	for i in 0 ..< survivor.ITEM_COUNT {
		item := &cur.items[i]
		if !item.alive || out.n_scene >= gh.MAX_SCENE_ITEMS do continue
		it := &out.scene[out.n_scene]
		out.n_scene += 1
		id := physics.body_id(w.phys, item.body)
		p := b3.Body_GetPosition(id)
		q := b3.Body_GetRotation(id)
		it^ = {
			key    = view.Key(ITEM_KEY + i),
			kind   = item.kind == .Barrel ? SCENE_BARREL : SCENE_CRATE,
			slot   = -1,
			entity = u32(i),
			pos    = {p.x, p.y, p.z},
			rot    = {q.v.x, q.v.y, q.v.z, q.s},
		}
	}
	// enemies (one bulk kind per Enemy_Kind)
	en := &cur.enemies
	for idx in 0 ..< int(en.high_water) {
		if !en.slots[idx].alive || out.n_bulk >= gh.MAX_BULK_ITEMS do continue
		e := &en.items[idx]
		b := &out.bulk[out.n_bulk]
		out.n_bulk += 1
		b^ = {
			kind = u8(e.kind),
			pos  = {e.pos.x, 0, e.pos.y},
			yaw  = (e.vel.x != 0 || e.vel.y != 0) ? math.atan2(e.vel.x, e.vel.y) : 0,
		}
		if prev != nil {
			ps := &prev.enemies.slots[idx]
			if ps.alive && ps.generation == en.slots[idx].generation {
				pe := &prev.enemies.items[idx]
				b.has_prev = true
				b.prev_pos = {pe.pos.x, 0, pe.pos.y}
			}
		}
	}
	pr := &cur.projectiles
	for idx in 0 ..< int(pr.high_water) {
		if !pr.slots[idx].alive || out.n_bulk >= gh.MAX_BULK_ITEMS do continue
		pj := &pr.items[idx]
		b := &out.bulk[out.n_bulk]
		out.n_bulk += 1
		b^ = {
			kind = BULK_PROJECTILE,
			pos  = pj.pos,
			yaw  = math.atan2(pj.vel.x, pj.vel.z),
		}
		if prev != nil {
			ps := &prev.projectiles.slots[idx]
			if ps.alive && ps.generation == pr.slots[idx].generation {
				b.has_prev = true
				b.prev_pos = prev.projectiles.items[idx].pos
			}
		}
	}
	gm := &cur.gems
	for idx in 0 ..< int(gm.high_water) {
		if !gm.slots[idx].alive || out.n_bulk >= gh.MAX_BULK_ITEMS do continue
		g := &gm.items[idx]
		b := &out.bulk[out.n_bulk]
		out.n_bulk += 1
		b^ = {
			kind = BULK_GEM,
			pos  = {g.pos.x, 0, g.pos.y},
		}
	}
	extract_hud(cur, (^Hud)(&out.hud[0]))
}

// ---- HUD (contract v0): extracted on the session thread, turned into a Dictionary on the main thread

Hud_Player :: struct {
	present, alive:   bool,
	hp, hp_max:       i32,
	xp, xp_next:      i32,
	level, pending:   i32,
	respawn_s:        f32,
}

Hud :: struct {
	tick:          u32,
	wave:          i32,
	enemies_alive: i32,
	circle_radius: f32,
	phase:         u8, // 0 lobby, 1 match, 2 over
	players:       [survivor.MAX_PLAYERS]Hud_Player,
}

#assert(size_of(Hud) <= gh.HUD_BYTES)

PHASE_NAMES := [3]string{"lobby", "match", "over"}

extract_hud :: proc(s: ^S, h: ^Hud) {
	h^ = {}
	h.enemies_alive = s.enemies.count
	h.phase = 1 // the sim has no match phases yet: always "match"
	for p in 0 ..< survivor.MAX_PLAYERS {
		pl := &s.players[p]
		h.players[p] = {
			present   = pl.active,
			alive     = pl.alive,
			hp        = pl.hp,
			hp_max    = survivor.PLAYER_HP,
			xp        = pl.xp,
			xp_next   = 10 + pl.level * 5,
			level     = pl.level,
			pending   = pl.pending_levelups,
			respawn_s = pl.alive ? 0 : f32(pl.respawn) / survivor.TICK_HZ,
		}
	}
}

hud :: proc(f: ^gh.Frame, names: []string, d: ^gd.Dictionary) {
	h := (^Hud)(&f.hud[0])
	gd.dict_set(d, "phase", PHASE_NAMES[min(int(h.phase), 2)])
	gd.dict_set(d, "tick", i64(f.tick))
	gd.dict_set(d, "time_s", f64(f.tick) / f64(survivor.TICK_HZ))
	gd.dict_set(d, "wave", i64(h.wave))
	gd.dict_set(d, "enemies_alive", i64(h.enemies_alive))
	gd.dict_set(d, "circle_radius", f64(h.circle_radius))
	gd.dict_set(d, "local_slot", i64(f.local_slot))
	players := gd.array_new()
	for &p, i in h.players {
		pd := gd.dict_new()
		gd.dict_set(&pd, "slot", i64(i))
		gd.dict_set(&pd, "present", p.present)
		gd.dict_set(&pd, "alive", p.alive)
		gd.dict_set(&pd, "hp", i64(p.hp))
		gd.dict_set(&pd, "hp_max", i64(p.hp_max))
		gd.dict_set(&pd, "xp", i64(p.xp))
		gd.dict_set(&pd, "xp_next", i64(p.xp_next))
		gd.dict_set(&pd, "level", i64(p.level))
		gd.dict_set(&pd, "pending_levelups", i64(p.pending))
		gd.dict_set(&pd, "respawn_s", f64(p.respawn_s))
		if i == int(f.local_slot) && len(names) > 0 do gd.dict_set(&pd, "name", names[0])
		gd.array_push_move(&players, &pd)
	}
	gd.dict_set_move(d, "players", &players)
}

