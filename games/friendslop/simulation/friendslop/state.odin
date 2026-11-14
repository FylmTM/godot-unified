// friendslop (games/friendslop/SPEC.md): constants, input, the pointer-free state block and the events.
package friendslop

import "unified:physics"
import "unified:sim"

TICK_HZ :: 64
DT: f32 : 1.0 / TICK_HZ // exact
PHYSICS_WORKERS :: 1 // Box3D's step threads: any count steps identically, more take CPU from Godot and the netcode
SUBSTEPS :: 4
PLAYERS :: 4
MAX_ITEMS :: 64
MAX_PLATFORMS :: 24
MAX_TRIGGERS :: 16
MAX_PADS :: 16
MAX_BUMPERS :: 8
MAX_CHECKPOINTS :: 16

// Time constants in seconds, converted to whole ticks at compile time.
RESPAWN_S :: 1.5
FINISH_HOLD_S :: 5.0
STUN_S :: 0.75
THROWN_MAX_S :: 1.0
THROWN_MIN_S :: 0.25
THROW_CHARGE_S :: 0.5
THROWN_TAG_S :: 1.0 // a thrown item counts as "thrown by P" this long
THROWER_IGNORE_S :: 0.25 // and can't hit its thrower for this long
PAD_COOLDOWN_S :: 0.25
BREAK_FREE_MIN_S :: 0.5 // a held player can't break free before this
BREAK_FREE_WINDOW_S :: 1.0 // 3 jump presses within this break free
HELD_MAX_S :: 4.0 // then the holder lets go anyway
BELL_COOLDOWN_S :: 1.0

RESPAWN_TICKS :: u16(RESPAWN_S * TICK_HZ)
FINISH_HOLD_TICKS :: u32(FINISH_HOLD_S * TICK_HZ)
STUN_TICKS :: u16(STUN_S * TICK_HZ)
THROWN_MAX_TICKS :: u16(THROWN_MAX_S * TICK_HZ)
THROWN_MIN_TICKS :: u16(THROWN_MIN_S * TICK_HZ)
THROW_CHARGE_TICKS :: u16(THROW_CHARGE_S * TICK_HZ)
THROWN_TAG_TICKS :: u16(THROWN_TAG_S * TICK_HZ)
THROWER_IGNORE_TICKS :: u16(THROWER_IGNORE_S * TICK_HZ)
PAD_COOLDOWN_TICKS :: u16(PAD_COOLDOWN_S * TICK_HZ)
BREAK_FREE_MIN_TICKS :: u16(BREAK_FREE_MIN_S * TICK_HZ)
BREAK_FREE_WINDOW_TICKS :: u16(BREAK_FREE_WINDOW_S * TICK_HZ)
HELD_MAX_TICKS :: u16(HELD_MAX_S * TICK_HZ)
BELL_COOLDOWN_TICKS :: u16(BELL_COOLDOWN_S * TICK_HZ)

// Movement and interaction tuning (metres, seconds).
WALK_SPEED :: 5.5
KILL_Y :: -10.0
GRAB_RANGE :: 1.6 // from the chest, plus the target's radius
GRAB_CONE_COS :: 0.8660254 // 60° cone around the aim (cos 30°)
HOLD_DIST :: 1.1
HOLD_UP :: 0.25 // chest height above the capsule centre
HOLD_PITCH :: 0.8 // how far the aim's pitch raises or lowers the hold point
HOLD_SLOW :: 0.85 // speed while holding (×)
HOLD_SLOW_HEAVY :: 0.6
THROW_SPEED_MIN :: 6.0
THROW_SPEED_ADD :: 10.0 // at full charge
HIT_SPEED :: 6.0 // an item this fast counts as a hit even if nobody threw it
KNOCKBACK :: 7.0 // m/s given to a hit player, along the item's motion, plus a hop
KNOCKBACK_UP :: 3.0
BELL_SPEED :: 4.0
PLAYER_RADIUS :: 0.35
PLAYER_HALF_HEIGHT :: 0.45 // capsule segment half length
POGO_REST :: 0.5 // the pogo holds the capsule's lower sphere centre this high: 1.75 m from feet to head
FEET :: PLAYER_HALF_HEIGHT + POGO_REST // from the capsule centre down to the ground it stands on

BUTTON_JUMP :: u8(1 << 0)
BUTTON_GRAB :: u8(1 << 1) // toggle: press to grab, press again to drop; held, it catches
BUTTON_THROW :: u8(1 << 2) // held charges a throw, released throws

// One player's input for one tick (8 bytes). Directions are world-space: the client rotates the stick
// by its camera and sends the camera's look direction, so the sim needs no trig.
Input :: struct {
	move_x:  i8,
	move_z:  i8,
	aim_x:   i8,
	aim_y:   i8,
	aim_z:   i8,
	buttons: u8,
	_spare:  [2]u8,
}
#assert(size_of(Input) == 8)

Inputs :: sim.Inputs(Input, PLAYERS)
Tick :: sim.Tick(State, Input, World, PLAYERS)

Body_Ref :: physics.Body_Ref

Held_Kind :: enum u8 {
	None,
	Item,
	Player,
}

Player :: struct {
	controller:    physics.Character,
	hold:          physics.Joint_Ref, // the joint to what this player holds
	facing:        [2]f32, // unit (x, z)
	aim:           [3]f32, // unit look direction from the last input
	held_kind:     Held_Kind,
	held_index:    u8, // item index or player
	grab_point:    u8, // which grab point of the held item
	held_by:       u8, // player + 1 of the player holding this one (0: free)
	stun:          u16, // ticks left limp (hit, thrown)
	charge:        u16, // ticks the throw button has been held while holding something
	held_ticks:    u16, // ticks this player has been held
	break_window:  u16, // ticks left to finish a break-free (3 presses)
	respawn:       u16, // ticks until a fallen player respawns (0: not fallen)
	pad_cooldown:  u16,
	thrown:        bool, // stunned by a throw: ends on landing
	active:        bool, // present (joined)
	prev_buttons:  u8,
	break_presses: u8,
}

Item :: struct {
	body:         Body_Ref,
	holders:      [2]u8, // player + 1 holding each grab point (0: free)
	thrown_by:    u8, // player + 1 of the last thrower (while thrown_ticks > 0)
	alive:        bool,
	thrown_ticks: u16,
	pad_cooldown: u16,
}

Platform :: struct {
	body:    Body_Ref,
	phase:   u32, // ticks into the path
	running: bool,
	_pad:    [3]u8,
}

Trigger :: struct {
	active:   bool, // plates: pressed now; bells and switches: fired (latched)
	_pad:     u8,
	cooldown: u16, // bells: no ring again before this runs out
}

Phase :: enum u8 {
	Hub, // free play; walking through the start gate starts a run
	Run, // the route, timed
	Finished, // the trophy is on the pedestal: show the time, then back to the hub
}

State :: struct {
	players:      [PLAYERS]Player,
	items:        [MAX_ITEMS]Item,
	platforms:    [MAX_PLATFORMS]Platform,
	bodies:       [MAX_TRIGGERS]Body_Ref, // bells' and switches' bodies (static, owned by the sim)
	triggers:     [MAX_TRIGGERS]Trigger,
	pad_launches: u32, // counters: tests and the HUD read them
	throws:       u32,
	hits:         u32,
	grabs:        u32,
	run_tick:     u32, // the tick the current run started
	finish_tick:  u32, // the tick the trophy arrived (Finished)
	runs:         u32,
	best_ticks:   u32, // the best run (0: none)
	checkpoint:   i32, // the team's last checkpoint index (-1: the hub)
	phase:        Phase,
	_pad:         [3]u8,
}

// Events (src/sim/SPEC.md "Events"): one plain struct per event, named as GDScript matches them (the type
// name lowercased). `player` is the player the event is about (only events about a player have it;
// sim.NO_PLAYER: none), `entity` the level marker index + 1 of an item, plate, bell, switch or lock (0: none),
// `position` where it happened (metres).

Player_Joined :: struct {
	position: sim.Position, // where the player appears
	player:   u8,
	_pad:     [3]u8,
}

Player_Left :: struct {
	player: u8,
}

Jumped :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

// A jump pad launched a player (entity 0) or an item (player NO_PLAYER).
Launched :: struct {
	entity:   u64,
	position: sim.Position, // the pad's
	player:   u8,
	_pad:     [3]u8,
}

// `player` grabbed an item (entity) or another player (held_player).
Grabbed :: struct {
	entity:      u64, // the item (0: a player)
	position:    sim.Position, // the holder's
	player:      u8, // the holder
	held_kind:   Held_Kind,
	held_player: u8, // the held player (NO_PLAYER: an item)
	_pad:        u8,
}

// `player` let go of what it held (also before a throw).
Dropped :: struct {
	entity:      u64, // the item (0: a player)
	position:    sim.Position, // the holder's
	player:      u8, // the holder
	held_kind:   Held_Kind,
	held_player: u8, // the dropped player (NO_PLAYER: an item)
	_pad:        u8,
}

Thrown :: struct {
	entity:      u64, // the item (0: a player)
	position:    sim.Position, // the thrower's
	speed:       f32, // m/s along the aim
	player:      u8, // the thrower
	held_kind:   Held_Kind,
	held_player: u8, // the thrown player (NO_PLAYER: an item)
	_pad:        [5]u8,
}

// A player was hit by an item or a bumper.
Hit :: struct {
	position: sim.Position,
	speed:    f32, // the knockback's horizontal speed
	player:   u8,
	_pad:     [3]u8,
}

Broke_Free :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

Fell :: struct {
	position: sim.Position, // where it fell below the kill height
	player:   u8,
	_pad:     [3]u8,
}

Respawned :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

// The team reached a checkpoint (the player who reached it).
Checkpoint :: struct {
	position: sim.Position, // the checkpoint's
	index:    i32, // the checkpoint's index (State.checkpoint)
	player:   u8,
	_pad:     [3]u8,
}

// A player walked through the start gate.
Run_Started :: struct {
	position: sim.Position, // the gate's
	player:   u8,
	_pad:     [3]u8,
}

// The trophy (entity) reached the pedestal.
Run_Finished :: struct {
	entity:   u64,
	position: sim.Position, // the finish volume's
	seconds:  f32, // the run's time
}

Plate_On :: struct {
	entity:   u64,
	position: sim.Position,
	mass:     f32, // kg on the plate
}

Plate_Off :: struct {
	entity:   u64,
	position: sim.Position,
	mass:     f32,
}

Bell_Rung :: struct {
	entity:   u64,
	position: sim.Position, // where it was hit
	speed:    f32, // the hit's approach speed
}

// A switch (touched by `player`) or a lock (opened by a key: player NO_PLAYER) fired.
Switch_On :: struct {
	entity:   u64,
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

Event :: union {
	Player_Joined,
	Player_Left,
	Jumped,
	Launched,
	Grabbed,
	Dropped,
	Thrown,
	Hit,
	Broke_Free,
	Fell,
	Respawned,
	Checkpoint,
	Run_Started,
	Run_Finished,
	Plate_On,
	Plate_Off,
	Bell_Rung,
	Switch_On,
}
