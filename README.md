# unified

[![ci](https://github.com/FylmTM/godot-unified/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/FylmTM/godot-unified/actions/workflows/ci.yml)

**Write a co-op game as if it were local multiplayer. Unified makes it online.**

Every player runs the same deterministic simulation, and only input crosses the network. Unified predicts the other
players' input, rolls back when it guessed wrong and runs the ticks again, physics included.

You write the game's rules in [Odin](https://odin-lang.org). [Godot](https://godotengine.org) is the view layer: it
renders the simulation, plays its sound and draws the UI, and never changes the game's state.

> [!NOTE]
> **Pre-1.0.** The API is not stable yet, and breaking changes land without notice.

## Try it

You need git, curl and a C toolchain for Odin's linker: clang on macOS and Linux, Visual Studio Build Tools on
Windows. The first `./uni` downloads the pinned Odin, Godot and Box3D. Nothing else is installed by hand.

```sh
git clone https://github.com/FylmTM/godot-unified
cd godot-unified
./uni init ../mygame     # a new game repo: the template game, with unified as a submodule
cd ../mygame
./uni run                # play it
```

On Windows, run `uni.cmd` instead of `./uni`.

To see co-op on one machine, start an example twice from the unified checkout. Click **Host on the LAN** in one
window and **Join on the LAN** in the other.

```sh
./uni run holdout
```

Before writing gameplay, read [`GUIDE.md`](examples/minimal_3d/GUIDE.md) (every new game gets a copy): the patterns
that survive rollback.

## What you get

- **Rollback netcode, no server to run.** One player hosts. Friends join by LAN address, or online through a lobby
  service: Epic Online Services is built in (lobby codes, peer-to-peer with relay fallback). Late join and rejoin
  work mid-match.
- **Physics inside the rollback.** [Box3D](https://github.com/FylmTM/unified-box3d) bodies, joints, characters and
  ragdolls are saved, restored and re-simulated with the rest of the state.
- **One code path for every mode.** Single player, couch co-op and online run the same simulation.
- **Desyncs caught before players find them.** A sync-test rolls back every tick and compares checksums. Recorded
  sessions replay as regression tests. CI checks that every example computes the same bits on every platform.
- **Your Odin types in GDScript.** Commands, events and view data show up as typed GDScript classes. No codegen step.
- **Levels from Godot scenes.** Build a level in the editor; `uni bake` turns it into sim data, navmesh included.
- **Dev tools in the game.** A dev UI with a state inspector and network conditions. A dev build records every session
  for replay with seek, and F3 saves a bug note a playtester can send you.
- **Headless runs.** Whole sessions, many clients in one process, on a virtual clock behind a simulated network.
- **Agent-ready.** One CLI that documents itself, headless tests, and `uni drive`, which lets a coding agent play the
  running game. A new game repo comes with agent skills.

## How a game looks

A game is a simulation in Odin and a Godot project that shows it. These snippets are from
[`examples/minimal_3d`](examples/minimal_3d/), where players move capsules and throw balls.

**All game state is one block of plain data.** No pointers, so a snapshot is a copy. Input is the controls held this
tick; a one-shot action is a command.

```odin
State :: struct {
	clock:   sim.Clock,
	players: sim.Players(Player_Data, sim.No_Profile, Input, PLAYERS),
	balls:   sim.Table(Ball, MAX_BALLS),
}

Input :: struct { dx, dy: i8 }
Command_Throw_Ball :: struct { speed: u8 }
Event_Ball_Thrown :: struct { player: sim.Player, speed: u8 }
```

**A tick is plain procs over the state.** It runs once on predicted input and again when the real input arrives, so
it reads nothing but the state and the input.

```odin
tick :: proc(t: ^Tick) {
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
```

**Godot sends commands and reacts to events.** `CommandThrowBall` and `EventBallThrown` are the Odin structs above. A
predicted event can be cancelled by a rollback, so an effect plays on `EMITTED` and a score waits for `CONFIRMED`.

```gdscript
func throw_ball() -> void:
	var throw := CommandThrowBall.new()
	throw.speed = 4
	session.send_command(throw)

func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventBallThrown and state == UnifiedSession.EVENT_EMITTED:
		body.scale = Vector3(1.25, 0.8, 1.25)
```

**Views read the state and never write it.** Each frame the game pushes a view per entity. Its struct arrives on the
Godot node as typed `data`.

```odin
View_Player :: struct { color: godot.Color }

fill_frame_players :: proc(f: ^Frame) {
	players := sim.iterate_present(&f.state.players)
	for data, player in sim.next(&players) {
		slot := sim.player_slot(&f.state.players, player)
		godot.push_view(f, player, {pos = sim.position_floor(data.position)}, View_Player{color = PLAYER_COLORS[slot]})
	}
}
```

```gdscript
var data: ViewPlayer  # views/player.gd: data.color paints the capsule
```

## Why it's built this way

- **Floats, not fixed point.** Hardware `+ − × ÷ sqrt` round the same on every CPU, so the sim uses plain `f32`, and a
  lint bans what doesn't (fused multiply-add, libm functions). x64 and ARM64 players play together.
  [`src/dmath`](src/dmath/README.md)
- **State is one block of bytes.** No pointers and no padding: a snapshot is a memcpy, the bytes are the checksum, and
  a late joiner receives the block. [`src/sim`](src/sim/README.md)
- **Input is the only way in.** Godot reads the state and never writes it. Single player is online play with one
  player, so whatever would desync online fails a test offline. [`src/godot`](src/godot/README.md)
- **Nobody sends game state.** Every peer runs the whole sim. The host only orders inputs, and one slow player never
  stalls the rest. [`src/netcode`](src/netcode/README.md)
- **Godot is the host, not a second world.** Rules and physics live in the sim. Rendering, audio, UI and level editing
  live in Godot. There is no second copy of the game to keep in sync. [`src/README.md`](src/README.md)

## Examples

Each one is a Godot project with its Odin code in `simulation/`. Play one with `./uni run <name>` from the unified
checkout.

| Example                              | What it is                             | What it shows                                                   |
| ------------------------------------ | -------------------------------------- | --------------------------------------------------------------- |
| [minimal_3d](examples/minimal_3d/)   | Capsules throwing balls                | The template `uni init` copies: state, commands, events, views  |
| [survivor](examples/survivor/)       | Top-down survival against waves        | A game at scale: big waves, physics props, a lobby              |
| [friendslop](examples/friendslop/)   | Third-person physics sandbox           | Characters, carrying and throwing, a level change mid-session   |
| [drift](examples/drift/)             | Top-down ship arena                    | 2D views over physics locked to a plane, couch co-op            |
| [horde](examples/horde/)             | 2D arena against thousands of enemies  | Crowds as MultiMesh instances, effects as shader ring buffers   |
| [deckbuilder](examples/deckbuilder/) | Co-op card battler                     | A turn-based UI game with no physics, a saved run               |
| [holdout](examples/holdout/)         | First-person shooter defending a core  | Shots land where the shooter saw the target, a 3D navmesh       |
| [playground](examples/playground/)   | Box3D's sample scenes, played together | Every joint type, ragdolls and cars, all under rollback         |

## The `uni` CLI

One command runs everything in a game repo. In the unified checkout, name the game: `./uni run holdout`. The most
useful commands:

```sh
./uni run                                         # play the game in a window
./uni editor                                      # open the game in the Godot editor
./uni test                                        # the sim tests and the determinism lint
./uni headless -- synctest --ticks 600 --window 8 # the sim without Godot, rolled back every tick
./uni coop --lan                                  # a host and a joiner on this machine
./uni bake                                        # turn level scenes into sim data, navmesh included
./uni verify                                      # format check, vet and every test suite
./uni release                                     # a playable build of the game, zipped
./uni doc <package>                               # a package's API, with its doc comments
```

`./uni help` lists every command, and `-h` on one shows its options.

## Where it fits

Built for co-op games of 1–4 players, the range the examples test (the library allows up to 32), on Windows x64,
macOS ARM64 and Linux x64. It does not fit, today:

- **Competitive play or secrets.** Every client holds the whole state, so a modified client sees everything, and the
  host is trusted. A modified guest can't change the outcome: the checksums catch it.
- **Host migration.** The host runs the relay; when the host leaves, the session ends.
- **Web, mobile or consoles.** Desktop only.
- **Gameplay in GDScript.** Rules are Odin: `f32` math, no heap in the state, fixed-capacity tables. GDScript is for
  what the player sees.

## Learn more

- [`GUIDE.md`](examples/minimal_3d/GUIDE.md), copied into every new game: the patterns that survive rollback, and
  the gotchas by symptom.
- [`docs/getting-started.md`](docs/getting-started.md): the toolchain, editor setup, local overrides.
- [`src/README.md`](src/README.md): how the core works inside, with a README per package.
- [`docs/EOS.md`](docs/EOS.md): setting up online play with Epic Online Services.
- [`docs/agent-guide.md`](docs/agent-guide.md): coding agents in a game repo.

## License

Licensed under either of [Apache License 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT), at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as
defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

Third-party code keeps its own license: Box3D and unified-box3d (MIT), Godot (MIT). The EOS SDK is not included.
