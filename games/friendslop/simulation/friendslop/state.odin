// friendslop (games/friendslop/SPEC.md): constants, input, and the pointer-free state block.
package friendslop

import "unified:physics"
import "unified:sim"

TICK_HZ :: 64
DT: f32 : 1.0 / TICK_HZ // exact
SUBSTEPS :: 4
MAX_PLAYERS :: 4
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

Inputs :: sim.Inputs(Input, MAX_PLAYERS)

Body_Ref :: physics.Body_Ref

Held_Kind :: enum u8 {
	None,
	Item,
	Player,
}

Player :: struct {
	mover:         physics.Mover,
	hold:          physics.Joint_Ref, // the joint to what this player holds
	facing:        [2]f32, // unit (x, z)
	aim:           [3]f32, // unit look direction from the last input
	held_kind:     Held_Kind,
	held_index:    u8, // item index or player slot
	handle:        u8, // which grab point of the held item
	held_by:       u8, // slot + 1 of the player holding this one (0: free)
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
	holders:      [2]u8, // slot + 1 holding each grab point (0: free)
	thrown_by:    u8, // slot + 1 of the last thrower (while thrown_ticks > 0)
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
	players:      [MAX_PLAYERS]Player,
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

Event_Kind :: enum u16 {
	Player_Joined,
	Player_Left,
	Jumped,
	Launched, // a jump pad (players and items)
	Grabbed,
	Dropped,
	Thrown,
	Hit, // a player was hit by an item or a bumper (value: speed)
	Broke_Free,
	Fell,
	Respawned,
	Checkpoint, // value: index
	Run_Started,
	Run_Finished, // value: seconds
	Plate_On,
	Plate_Off,
	Bell_Rung,
	Switch_On,
}

EVENT_NAMES := []string {
	"player_joined",
	"player_left",
	"jumped",
	"launched",
	"grabbed",
	"dropped",
	"thrown",
	"hit",
	"broke_free",
	"fell",
	"respawned",
	"checkpoint",
	"run_started",
	"run_finished",
	"plate_on",
	"plate_off",
	"bell_rung",
	"switch_on",
}
#assert(len(Event_Kind) == 18)
