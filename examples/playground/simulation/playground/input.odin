package playground

import "unified:dmath"
import "unified:sim"

Button :: enum u8 {
	Grab, // held: the body under the aim follows the camera; released: it goes with its velocity
	Closer, // held while grabbing: the grab point comes toward the camera
	Farther, // held while grabbing: it goes away
}

Buttons :: bit_set[Button;u8]

// One player's input for one tick (8 bytes): the camera's stick (right, up and forward along the look, each -127..127:
// dmath.axis_i8), the held buttons and the look (dmath.Aim: no angles cross the wire as floats, the sim needs no
// trig). In a car the stick steers (`right`) and throttles (`forward`).
Input :: struct {
	right:   i8,
	up:      i8,
	forward: i8,
	buttons: Buttons,
	aim:     dmath.Aim,
}
#assert(size_of(Input) == 8)

// The shapes the spawn tool makes (and the scenes use).
Shape :: enum u8 {
	Box,
	Sphere,
	Capsule,
	Cylinder,
}

// `scene`: everyone goes to `scene` (picking the current one resets it).
Cmd_Scene :: struct {
	scene: Scene,
}

// `shoot`: a bullet from the sender's camera along their aim.
Cmd_Shoot :: struct {}

// `spawn`: a body of `shape` in front of the sender's camera.
Cmd_Spawn :: struct {
	shape: Shape,
}

// `explode`: an explosion where the sender's aim meets something (or at GRAB_RANGE).
Cmd_Explode :: struct {}

// `drive`: in the Driving scene, the sender takes the nearest free car, or leaves the one they drive.
Cmd_Drive :: struct {}

// Every command a player can send: the tools' one-shot actions and the scene picker.
Cmd :: union {
	Cmd_Scene,
	Cmd_Shoot,
	Cmd_Spawn,
	Cmd_Explode,
	Cmd_Drive,
}

// A tick's inputs and commands, by slot.
Inputs :: sim.Inputs(Game)
