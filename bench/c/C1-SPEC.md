# Task C1: grab and throw

You're adding a gameplay feature to an existing deterministic simulation (a headless benchmark of a co-op game). The
codebase in your directory implements `bench/a/SPEC.md`: Box3D physics, 4 players, 300 props, 1000 swarm agents, a
pointer-free state block, and a per-tick XXH3 hash. Read that spec and the code first. Work like a developer on a real
team: idiomatic code in this language, following the codebase's existing structure.

## The feature

Players can grab a nearby prop, carry it above their head, and throw it. Swarm agents flee from carried props.

1. **Input.** Each player's input gets a `grab` button (held state, not a pulse) and a **facing** direction: the last
   non-zero `(dx, dz)` move direction, normalized (initially `(1, 0)`). Both are part of the hashed state.
   - In the default random-input mode, sample grab with the other inputs every 30 ticks:
     `grab = ((r >> 12) & 3) == 0`, using the same `r` already drawn for that player.
2. **Grab.** On the tick a player's grab goes from up to down, that player picks the nearest prop whose centre is
   within **3.0 m** (3D distance from the player's body position), unless another player already holds it.
   - If several players start grabbing in the same tick, process players in index order (lower index first).
   - The held prop becomes **kinematic** while held. Each tick it's moved to the **hold point**: player position +
     `(0, 1.6, 0)`. A small lag of up to 2 ticks is fine.
   - A player holds at most one prop. Nothing happens if no free prop is in range.
3. **Throw.** On the tick grab goes from down to up while holding, the prop becomes **dynamic** again with linear
   velocity `facing * 10.0 + (0, 3.0, 0)` (m/s, ignoring the player's own velocity). The player holds nothing
   afterwards.
4. **Flee.** In the swarm's velocity step, if any held prop is within **6.0 m** (horizontal distance) of an agent,
   that agent's desired velocity is `normalize(agent − prop) * 4.0` (horizontal, away from the nearest held prop)
   instead of seeking its target player. Separation, blending, clamping and ray blocking stay as they are.
5. **Determinism.** Everything stays deterministic: f32 only, no transcendentals, no state outside the block except
   physics handles, the same output for the same inputs. All new state goes in the hashed state block (extend the
   canonical hash: per player `grab` u8, `held` i16 (−1 = none), `facing` 2×f32, after the existing input fields).
   Physics changes are covered by the existing body hash.

## Scenarios (new CLI flags, for the acceptance checker)

`--scenario NAME --dump PATH` replaces the random inputs with a script and writes one JSON line per tick (after the
tick) to PATH:

`{"t":<tick after increment>,"pp":[[x,y,z]×4],"held":[i,i,i,i],"prop0":[x,y,z,vx,vy,vz],"near":[[px,pz,vx,vz],...]}`

where `pp` are player body positions, `held` the held prop index per player (−1 = none), and `prop0` prop 0's
position and linear velocity. `near` lists every agent within 6.0 m (horizontal) of prop 0's position, **but only
while prop 0 is held** (otherwise it's an empty list).

Scenario setup happens after world creation and before tick 0. A teleport means `b3Body_SetTransform` to the given
position with identity rotation, and zero velocity. Unmentioned players get no input (dx = dz = 0, grab up). The ticks
`t` below are tick indices at the *start* of the tick (0-based).

- `grab1`: teleport player 0 to `(-12.75, 2, -11.25)`. Grab down for `t` in 10..69, up from 70. Move `dx = +1` for
  `t` in 15..69, otherwise 0. Run 200 ticks.
- `grab2`: teleport player 0 to `(-12.75, 2, -11.25)` and player 1 to `(-9.75, 2, -11.25)`. Both hold grab for `t`
  in 10..39. Run 60 ticks.
- `grab3`: teleport player 0 to `(30, 2, 30)`. Grab down for `t` in 10..40. Run 60 ticks.

Default mode (no `--scenario`) keeps working with `--ticks N --trace PATH` and the JSON line, now including grab.

## Done means

- `python3 ../../../harness/check_c1.py .` passes. It builds release, runs the three scenarios, and runs the default
  mode twice for 3600 ticks plus once for 20000 ticks.
- The code is idiomatic, the bindings are extended properly for any new Box3D calls, and pointer-freedom checks still
  cover the new state.
- **Use only `./build.sh dev|release` to build.** It logs each build, and that log is part of the measurement.
- Write `NOTES.md` (≤ 30 lines) on what you changed and what was hard.
