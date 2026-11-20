# unified

[![ci](https://github.com/FylmTM/godot-unified/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/FylmTM/godot-unified/actions/workflows/ci.yml)

**A deterministic core for co-op games with rollback netcode, written in Odin, with Godot as the host.**

A game's simulation is a fixed-tick, bit-for-bit deterministic function of player input, with rigid-body physics
([Box3D](https://github.com/erincatto/box3d)) inside the rollback. [Godot](https://godotengine.org) renders it, plays
its audio and draws its UI through GDExtension. Built for 2–4 player co-op across Windows x64, macOS ARM64 and Linux.

> [!NOTE]
> **Status: pre-1.0.** The API is not stable yet, and breaking changes land without notice.

## Features

- **Input-relay netcode:** prediction, rollback, late join and rejoin, no backend. Transports: in-process loopback,
  UDP / LAN, Epic Online Services (lobbies by code, P2P with relay fallback).
- **Physics inside rollback:** Box3D through [unified-box3d](https://github.com/FylmTM/unified-box3d), an Odin port
  that saves, restores and hashes the world.
- **Proven offline:** a sync-test rolls back and re-simulates every tick and compares checksums; recorded sessions
  replay as regression tests; every CI platform reproduces each game's reference run bit for bit.
- **Headless everything:** whole sessions, many clients per process, on a virtual clock with a network simulator.
  `uni drive` lets an agent play a running game.

## The model

A game is a sim package (its state, input and tick) and a Godot project. From
[`examples/minimal_3d`](examples/minimal_3d/), trimmed:

```odin
// The whole simulation state: one pointer-free block.
State :: struct {
	clock:   sim.Clock,
	players: sim.Players(Player_Data, sim.No_Profile, Input, PLAYERS),
	balls:   sim.Table(Ball, MAX_BALLS),
}

Input :: struct { dx, dy: i8 } // the controls' state for one tick, quantized: an Input holds no floats
Command :: union { Command_Throw_Ball, Command_Set_Paused } // one-shot actions a player sends
Event :: union { sim.Event_Player_Joined, sim.Event_Player_Left, Event_Ball_Thrown, Event_Paused } // for the view

Game :: sim.Game(State, Input, sim.No_World, Event, Command, sim.No_Setup, sim.No_Profile, PLAYERS)
Tick :: sim.Tick(Game)

// One tick: plain procs over the state, in order. A physics game also calls physics.step(t.world.phys).
tick :: proc(t: ^Tick) {
	place_new_players(t)
	apply_pause(t)
	if t.paused do return
	move_players(t)
	throw_balls(t)
	move_balls(t)
}

move_players :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		input := sim.input(t, player)
		data.position += dmath.stick(input.dx, input.dy) * (MOVE_SPEED * t.dt)
	}
}

throw_balls :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for _, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			throw := sent.(Command_Throw_Ball) or_continue
			throw_ball(t, player, throw.speed) // spawns a Ball, sim.emit(t, Event_Ball_Thrown{...})
		}
	}
}

// The game's GDExtension: a frame of views, read from the state (never written).
fill_frame_balls :: proc(f: ^Frame) {
	balls := sim.iterate(&f.state.balls)
	for ball, handle in sim.next(&balls) {
		godot.push_multi_view(f, {
			key  = sim.handle_key(handle),
			kind = .Ball,
			pos  = sim.position_floor(ball.pos, ball.height),
		})
	}
}
```

```gdscript
# main.gd: a one-shot action is a command, sent to the sim.
var throw := CommandThrowBall.new()
throw.speed = 4
session.send_command(throw)

# views/player.gd: an effect plays on EMITTED (predicted, undone on CANCELLED); what must happen once waits for
# CONFIRMED, or a rollback can fire it twice.
func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventBallThrown and state == UnifiedSession.EVENT_EMITTED:
		body.scale = Vector3(1.25, 0.8, 1.25)
```

The netcode runs `tick` ahead on predicted input, rolls back when the official inputs differ and runs it again; the
view shows the newest prediction. [`GUIDE.md`](examples/minimal_3d/GUIDE.md) builds this game step by step.

## Design

- **Determinism is a discipline, not a number format.** f32, not fixed point: IEEE 754 rounds hardware
  `+ − × ÷ sqrt` the same on every CPU, and Box3D and Godot speak floats. What differs between CPUs is banned and
  linted: fused multiply-add (rounds once instead of twice), libm transcendentals (ours are fixed polynomials),
  builtin float `min`/`max`, NaN in the state, wall-clock time, unordered iteration. So x64 and ARM64 players play
  together.
- **One pointer-free, padding-free state block.** A snapshot is a memcpy, the bytes are the checksum, and a late
  joiner receives the block. References are handles.
- **Input is the only way into the sim.** The view reads frames and events and never writes, so single player is
  online play with one player, and what would diverge online fails a test offline.
- **Input relay, not lockstep.** Nobody sends game state: every peer runs the whole sim. The host's relay finalizes
  each tick once every input is in or a short tolerance has passed, a missing input repeating that player's last,
  so one slow player never stalls the others.
- **Physics in the rollback.** Box3D's world is saved, restored and hashed with the block: no second physics world
  to reconcile. Game rules run on one thread; any physics worker count steps to the same bits.
- **Godot is a host, not a second world.** The sim is the game; Godot renders, plays audio, draws UI and authors
  levels. No bridge between an engine's scene and a separate sim, no schema codegen, no mirrored physics.
- **Odin, code-first, one CLI.** A plain-data systems language with fast builds. Content comes from code and baked
  scenes, dev tools live in the game, and everything runs through `uni`, whose commands describe themselves.
- **Minimal dependencies.** Ideally zero; each needs a reason and its own tests, so an upgrade is safe because the
  tests say so.
- **Built for agents.** Deterministic headless tests, one CLI, `uni drive` and parallel worktrees let AI agents do
  most of the work safely.

## Examples

Example co-op games, each a Godot project with its Odin sim in `simulation/`; a real game lives in its own repo.

- [`examples/minimal_3d/`](examples/minimal_3d/): the smallest 3D game (capsules throw balls), what `uni init` copies.
- [`examples/survivor/`](examples/survivor/): top-down survivor, waves of enemies and physics props (3D).
- [`examples/friendslop/`](examples/friendslop/): third-person physics sandbox: carry, stack, throw (3D).
- [`examples/drift/`](examples/drift/): ship arena defending a station (2D views, physics locked to a plane).
- [`examples/deckbuilder/`](examples/deckbuilder/): co-op card battler, a run up one act (turns, no physics, a UI of
  Controls, a saved run to continue).
- [`examples/holdout/`](examples/holdout/): first-person co-op shooter defending a core, enemies on a 3D navmesh.
- [`examples/playground/`](examples/playground/): co-op physics playground of Box3D's sample scenes: flying cameras with
  tools, ragdolls, cars, every joint, a benchmark row per scene (3D).

## Documentation

- [`docs/getting-started.md`](docs/getting-started.md): the toolchain, the first commands, a new game.
- [`src/README.md`](src/README.md): how the core works inside; each package's `README.md` and `./uni doc <pkg>`.
- [`AGENTS.md`](AGENTS.md): the rules and workflow, for people and agents. [`docs/EOS.md`](docs/EOS.md): online
  setup. [Issues](https://github.com/FylmTM/godot-unified/issues): current and upcoming work.

## License

Licensed under either of [Apache License 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT), at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as
defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

Third-party code keeps its own license: Box3D and unified-box3d (MIT), Godot (MIT). The EOS SDK is not included.
