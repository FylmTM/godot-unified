package playground

// Every rule number of the playground (examples/playground/README.md names them). Metres, seconds, kilograms, Y up.

// ---- the flying cameras

FLY_SPEED :: f32(8) // metres per second at full stick
FLY_BOUND :: f32(60) // a camera stays within this of the scene's origin, horizontally
FLY_FLOOR :: f32(0.3) // and above this height
FLY_CEILING :: f32(40)

// ---- tools

GRAB_RANGE :: f32(40) // the aim ray's length for grabbing and exploding
GRAB_DIST_MIN :: f32(1.5) // a held body's grab point is this far in front of the camera, at least
GRAB_HERTZ :: f32(5) // the grab's spring (the motor joint's linear stiffness)
GRAB_DAMPING :: f32(0.7)
GRAB_FORCE_SCALE :: f32(40) // the grab pulls with at most this many times the body's weight
GRAB_TORQUE :: f32(5) // and damps its spin with up to this much torque per kilogram (N·m/kg)

SHOT_SPEED :: f32(60) // a bullet's launch speed along the aim
SHOT_RADIUS :: f32(0.12)
SHOT_DENSITY :: f32(4000)
SHOT_TICKS :: 192 // a bullet lives this long
SHOT_COOLDOWN_TICKS :: 8 // between one player's shots

SPAWN_DIST :: f32(4) // a spawned body appears this far along the aim
SPAWN_COOLDOWN_TICKS :: 10
SPAWN_HALF :: f32(0.4) // its size: a box's half extent, a sphere's radius, ...

EXPLODE_RADIUS :: f32(2.5)
EXPLODE_FALLOFF :: f32(3)
EXPLODE_IMPULSE :: f32(600) // N·s per square metre of a facing shape
EXPLODE_COOLDOWN_TICKS :: 32

DRIVE_RANGE :: f32(8) // a camera takes a car whose chassis is this close

// ---- the world

KILL_Y :: f32(-20) // a body below this is gone
DENSITY :: f32(100) // the default density of the scenes' bodies (kg/m³)

// ---- the cars (the Box3D sample's)

CAR_SPIN_SPEED :: f32(30) // rad/s of the rear wheels at full throttle
CAR_SPIN_TORQUE :: f32(600) // the sample's 5 N·m drives a car of a hundredth of the mass
CAR_STEER :: f32(0.6) // rad at full stick (about 35°)
CAR_STEER_LIMIT :: f32(0.785) // rad (45°)
CAR_STEER_TORQUE :: f32(1000)
CAR_SUSPENSION_HERTZ :: f32(4)
CAR_SUSPENSION_DAMPING :: f32(0.7)
CAR_SUSPENSION_TRAVEL :: f32(0.2)
CAR_UPRIGHT_HERTZ :: f32(0.5) // the parallel joint that keeps a car upright

// ---- scene rules

RAIN_EVERY_TICKS :: 6 // Rain: a body falls in every this many ticks
RAIN_CAP :: 120 // and the oldest goes once this many are down
TURRET_EVERY_TICKS :: 48 // Bullets: the turret fires this often
WIND_SPEED :: f32(12) // Wind: the air's speed (m/s)
WIND_DRAG :: f32(1)
WIND_LIFT :: f32(0.5)
WIND_TURN_TICKS :: 512 // the wind's direction turns once around in this many ticks
CONVEYOR_EVERY_TICKS :: 40 // Conveyor: a crate drops onto the first belt this often
CONVEYOR_CAP :: 40
BREAK_FORCE :: f32(2500) // Breakable: a joint breaks past this force (N)
BREAK_TORQUE :: f32(1500) // or this torque (N·m)
FLASH_TICKS :: 12 // Sensors: a hit body flashes this long
HIT_SPEED :: f32(2) // contacts faster than this make hit events
