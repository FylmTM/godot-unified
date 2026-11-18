// friendslop (games/friendslop/SPEC.md): constants, input, the pointer-free state block and the events.
package friendslop

import "unified:dmath"
import "unified:physics"
import "unified:sim"

TICK_HZ :: 64
PHYSICS_WORKERS :: 1 // Box3D's step threads: any count steps identically, more take CPU from Godot and the netcode
PLAYERS :: 4
CHARACTERS :: PLAYERS * sim.MEMBERS_PER_SLOT // a character body per member the session remembers (sim.Players)
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

Button :: enum u8 {
	Jump,
	Grab, // toggle: press to grab, press again to drop; held, it catches
	Throw, // held charges a throw, released throws
}

Buttons :: bit_set[Button;u8]

// One player's input for one tick (8 bytes). Directions are world-space: the client rotates the stick
// by its camera and sends the camera's look direction (dmath.Dir3), so the sim needs no trig. Buttons are held:
// presses are the difference from the tick before (sim.input_before).
Input :: struct {
	move_x:  i8,
	move_z:  i8,
	buttons: Buttons,
	_spare:  u8,
	aim:     dmath.Dir3,
}
#assert(size_of(Input) == 8)

Inputs :: sim.Inputs(Game)
Tick :: sim.Tick(Game)

Body_Ref :: physics.Body_Ref

Held_Kind :: enum u8 {
	None,
	Item,
	Player,
}

// A player's data (sim.Players, by member): zeroed when someone new joins; a leave releases and destroys what it
// owns outside the block (the body, the hold) and zeroes it, so a returning player starts fresh too.
Character :: struct {
	controller:    physics.Character,
	hold:          physics.Motor_Joint_Ref, // the joint to what this player holds
	facing:        [2]f32, // unit (x, z)
	aim:           [3]f32, // unit look direction from the last input
	held_player:   sim.Player, // the player this one holds (held_kind .Player)
	held_by:       sim.Player, // the player holding this one ({}: free)
	stun:          u16, // ticks left limp (hit, thrown)
	charge:        u16, // ticks the throw button has been held while holding something
	held_ticks:    u16, // ticks this player has been held
	break_window:  u16, // ticks left to finish a break-free (3 presses)
	respawn:       u16, // ticks until a fallen player respawns (0: not fallen)
	pad_cooldown:  u16,
	held_kind:     Held_Kind,
	held_item:     u8, // the item index (held_kind .Item)
	grab_point:    u8, // which grab point of the held item
	thrown:        bool, // stunned by a throw: ends on landing
	break_presses: u8,
	_pad:          [3]u8,
}

Item :: struct {
	body:         Body_Ref,
	holders:      [2]sim.Player, // the player holding each grab point ({}: free)
	thrown_by:    sim.Player, // the last thrower (while thrown_ticks > 0), whether still here or not
	thrown_ticks: u16,
	pad_cooldown: u16,
	alive:        bool,
	_pad:         [3]u8,
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
	players:      sim.Players(Character, Input, PLAYERS),
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
// name lowercased). `player` is the player the event is about (only events about a player have it; sim.Player{}:
// none), `entity` the level marker index + 1 of an item, plate, bell, switch or lock (0: none), `position` where it
// happened (metres). Joins and leaves are the library's (sim.Event_Player_Joined, sim.Event_Player_Left).

// A player's body appeared (they joined or came back).
Event_Spawned :: struct {
	position: sim.Position, // where the player appears
	player:   sim.Player,
}

Event_Jumped :: struct {
	position: sim.Position,
	player:   sim.Player,
}

// A jump pad launched a player (entity 0) or an item (player {}).
Event_Launched :: struct {
	entity:   u64,
	position: sim.Position, // the pad's
	player:   sim.Player,
}

// `player` grabbed an item (entity) or another player (held_player).
Event_Grabbed :: struct {
	entity:      u64, // the item (0: a player)
	position:    sim.Position, // the holder's
	player:      sim.Player, // the holder
	held_player: sim.Player, // the held player ({}: an item)
	held_kind:   Held_Kind,
	_pad:        [3]u8,
}

// `player` let go of what it held (also before a throw).
Event_Dropped :: struct {
	entity:      u64, // the item (0: a player)
	position:    sim.Position, // the holder's
	player:      sim.Player, // the holder
	held_player: sim.Player, // the dropped player ({}: an item)
	held_kind:   Held_Kind,
	_pad:        [3]u8,
}

Event_Thrown :: struct {
	entity:      u64, // the item (0: a player)
	position:    sim.Position, // the thrower's
	speed:       f32, // m/s along the aim
	player:      sim.Player, // the thrower
	held_player: sim.Player, // the thrown player ({}: an item)
	held_kind:   Held_Kind,
	_pad:        [7]u8,
}

// A player was hit by an item or a bumper.
Event_Hit :: struct {
	position: sim.Position,
	speed:    f32, // the knockback's horizontal speed
	player:   sim.Player,
}

Event_Broke_Free :: struct {
	position: sim.Position,
	player:   sim.Player,
}

Event_Fell :: struct {
	position: sim.Position, // where it fell below the kill height
	player:   sim.Player,
}

Event_Respawned :: struct {
	position: sim.Position,
	player:   sim.Player,
}

// The team reached a checkpoint (the player who reached it).
Event_Checkpoint :: struct {
	position: sim.Position, // the checkpoint's
	index:    i32, // the checkpoint's index (State.checkpoint)
	player:   sim.Player,
}

// A player walked through the start gate.
Event_Run_Started :: struct {
	position: sim.Position, // the gate's
	player:   sim.Player,
}

// The trophy (entity) reached the pedestal.
Event_Run_Finished :: struct {
	entity:   u64,
	position: sim.Position, // the finish volume's
	seconds:  f32, // the run's time
}

Event_Plate_On :: struct {
	entity:   u64,
	position: sim.Position,
	mass:     f32, // kg on the plate
}

Event_Plate_Off :: struct {
	entity:   u64,
	position: sim.Position,
	mass:     f32,
}

Event_Bell_Rung :: struct {
	entity:   u64,
	position: sim.Position, // where it was hit
	speed:    f32, // the hit's approach speed
}

// A switch (touched by `player`) or a lock (opened by a key: player {}) fired.
Event_Switch_On :: struct {
	entity:   u64,
	position: sim.Position,
	player:   sim.Player,
}

// The game has no commands (sim.Game's Cmd).
Cmd :: sim.No_Commands

Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
	Event_Spawned,
	Event_Jumped,
	Event_Launched,
	Event_Grabbed,
	Event_Dropped,
	Event_Thrown,
	Event_Hit,
	Event_Broke_Free,
	Event_Fell,
	Event_Respawned,
	Event_Checkpoint,
	Event_Run_Started,
	Event_Run_Finished,
	Event_Plate_On,
	Event_Plate_Off,
	Event_Bell_Rung,
	Event_Switch_On,
}
