package friendslop

// Every rule's number: metres, seconds, kilograms. Times are written in seconds and converted to ticks at compile
// time. The level's own numbers (sizes, launch velocities, platform paths) are its markers' properties.

// ---- sizes

MAX_ITEMS :: 64
MAX_PLATFORMS :: 24
MAX_TRIGGERS :: 16
MAX_PADS :: 16
MAX_BUMPERS :: 8
MAX_CHECKPOINTS :: 16
PHYSICS_WORKERS :: 1 // Box3D's step threads: any count steps identically, more take CPU from Godot and the netcode

// ---- the world

GRAVITY :: 10.0 // Box3D's default, |g|
HIT_EVENT_SPEED :: 2.0 // contacts slower than this report no hit event (m/s)
KILL_Y :: -10.0 // a player or an item below this fell
PLATFORM_FRICTION :: 0.8
PLATE_REACH :: 2.5 // a plate's sensor reaches this far above its top (what stands on it)
PLATE_SINK :: 0.2 // ... and this far below it

// Hub spawns by slot, where the level places none (spawn markers).
@(rodata)
DEFAULT_SPAWNS := [PLAYERS][3]f32{{-2.25, 1.2, 0}, {-0.75, 1.2, 0}, {0.75, 1.2, 0}, {2.25, 1.2, 0}}

// ---- players

WALK_SPEED :: 5.5
PLAYER_RADIUS :: 0.35
PLAYER_HALF_HEIGHT :: 0.45 // capsule segment half length
POGO_REST :: 0.5 // the pogo holds the capsule's lower sphere centre this high: 1.75 m from feet to head
FEET :: PLAYER_HALF_HEIGHT + POGO_REST // from the capsule centre down to the ground it stands on
RESPAWN_S :: 1.5 // a fallen player waits this long
RESPAWN_TICKS :: u16(RESPAWN_S * TICK_HZ)
CHECKPOINT_SPREAD :: 0.9 // players respawn at a checkpoint this far apart along x, by slot
PARK_Y :: -60 // a fallen player's body waits this far down ...
PARK_SPACING :: 4 // ... this far apart along x, by slot
STUN_TICKS :: u16(0.75 * TICK_HZ) // a hit player is limp this long
LANDING_PROBE :: 0.25 // a thrown player has landed when ground is within this below their feet

// ---- hands: grab, hold, throw

GRAB_RANGE :: 1.6 // from the chest, plus the target's radius
GRAB_RAY_RANGE :: GRAB_RANGE + 0.7 // the ray along the aim reaches a little further (it ends at a surface)
GRAB_HEIGHT :: 1.6 // a target more than this above or below the chest is out of reach
GRAB_CONE_COS :: 0.8660254 // 60° cone around the aim (cos 30°)
GRAB_ANYWHERE :: 0.4 // a target this close is in reach in any direction
HOLD_DIST :: 1.1
HOLD_UP :: 0.25 // chest height above the capsule centre
HOLD_UP_PLAYER :: 0.5 // a held friend hangs this much higher
HOLD_PITCH :: 0.8 // how far the aim's pitch raises or lowers the hold point
HOLD_HERTZ :: 5 // the hold's spring, linear and angular
HOLD_DAMPING :: 1
HOLD_TORQUE_PER_KG :: 20 // the angular spring's cap keeping a one-handle item upright (N·m per kg)
HANDLE_OUTSET :: 0.05 // a two-handle item's grab points are this far past its ends
HOLD_SLOW :: 0.85 // speed while holding (×)
HOLD_SLOW_HEAVY :: 0.6
THROW_SPEED_MIN :: 6.0
THROW_SPEED_ADD :: 10.0 // at full charge
THROW_LIFT :: 1.5 // m/s up on top of the aim
THROW_CHARGE_TICKS :: u16(0.5 * TICK_HZ)
THROWN_TAG_TICKS :: u16(1.0 * TICK_HZ) // a thrown item counts as "thrown by P" this long
THROWER_IGNORE_TICKS :: u16(0.25 * TICK_HZ) // and can't hit its thrower for this long
THROWN_MAX_TICKS :: u16(1.0 * TICK_HZ) // a thrown or dropped player is limp until they land, at most this long
THROWN_MIN_TICKS :: u16(0.25 * TICK_HZ) // and at least this long

// Holding a friend: the spring's cap is 2.5× a player's weight (a soft spring needs headroom to accelerate the body,
// not just hold it: 1.4× only drags a friend along the floor).
PLAYER_LIFT :: 2.5

// ---- breaking free

BREAK_FREE_PRESSES :: 3 // jump presses ...
BREAK_FREE_WINDOW_TICKS :: u16(1.0 * TICK_HZ) // ... within this break free
BREAK_FREE_MIN_TICKS :: u16(0.5 * TICK_HZ) // not before this held
BREAK_FREE_HOP :: 4.0 // m/s up on breaking free
HELD_MAX_TICKS :: u16(4.0 * TICK_HZ) // then the holder lets go anyway

// ---- hits, pads, bells

HIT_SPEED :: 6.0 // an item this fast counts as a hit even if nobody threw it
KNOCKBACK :: 7.0 // m/s given to a hit player, along the item's motion, plus a hop
KNOCKBACK_UP :: 3.0
PAD_COOLDOWN_TICKS :: u16(0.25 * TICK_HZ)
PAD_PROBE_UP :: 0.05 // a player is on a pad when the point this far above their feet is inside it
PAD_ITEM_PROBE :: 0.8 // an item is when the point this far down its radius is
BELL_SPEED :: 4.0 // a hit at least this fast rings a bell
BELL_COOLDOWN_TICKS :: u16(1.0 * TICK_HZ)

// ---- the run

FINISH_HOLD_S :: 5.0 // the finish screen, before everyone is back in the hub
FINISH_HOLD_TICKS :: u32(FINISH_HOLD_S * TICK_HZ)

// ---- items

Item_Spec :: struct {
	half:        [3]f32, // box half extents (zero: a sphere)
	radius:      f32, // sphere radius; for boxes, the grab reach bonus
	mass:        f32,
	lift:        f32, // one holder's spring force cap, in multiples of the item's weight
	friction:    f32,
	restitution: f32,
	grab_points: u8, // 1 = the centre, 2 = ±x ends
	throwable:   bool,
}

@(rodata)
ITEM_SPECS := [Item_Kind]Item_Spec {
	.Crate = {
		half        = {0.35, 0.35, 0.35},
		radius      = 0.35,
		mass        = 10,
		lift        = 3,
		friction    = 0.6,
		restitution = 0.1,
		grab_points = 1,
		throwable   = true,
	},
	.Ball = {
		radius      = 0.3,
		mass        = 3,
		lift        = 3,
		friction    = 0.5,
		restitution = 0.6,
		grab_points = 1,
		throwable   = true,
	},
	.Cube = {
		half        = {0.4, 0.4, 0.4},
		radius      = 0.4,
		mass        = 20,
		lift        = 2,
		friction    = 0.7,
		restitution = 0,
		grab_points = 1,
		throwable   = true,
	},
	.Key = {
		half        = {0.15, 0.25, 0.15},
		radius      = 0.25,
		mass        = 3,
		lift        = 3,
		friction    = 0.6,
		restitution = 0.1,
		grab_points = 1,
		throwable   = true,
	},
	.Heavy = {
		half        = {0.7, 0.4, 0.45},
		radius      = 0.7,
		mass        = 50,
		lift        = 0.6,
		friction    = 0.6,
		restitution = 0,
		grab_points = 2,
		throwable   = false,
	},
	.Trophy = {
		half        = {0.25, 0.4, 0.25},
		radius      = 0.4,
		mass        = 5,
		lift        = 3,
		friction    = 0.6,
		restitution = 0.1,
		grab_points = 1,
		throwable   = true,
	},
}
