# view

Decided autonomously 2026-11-09, pending developer review.

Host-agnostic view logic between the rollback sim and any renderer (`src/view`, no Godot; tests in `tests/view`).
Render-side code: f32 and transcendentals are fine, nothing feeds back into the sim.

## API

```odin
// sim thread -> render thread
Triple($T)  triple_init / triple_back / triple_publish / triple_front -> (^T, fresh)   // newest wins, no tearing
Queue($T, N)  queue_push (false when full) / queue_pop / queue_len                     // SPSC, N a power of two
alpha(now_us, due_us, tick_us) -> f32        // 0 at tick P's due time, 1 one tick later (clamped)

// per-view pose history
Pose { pos: [3]f32, rot: [4]f32 }            Smoothing { tau_s = 0.1, teleport_dist = 4 }
track_push(^Track, tick, pose, smoothing)    // re-pushing a tick = a rollback correction
track_sample(^Track, tick, alpha, dt_s, smoothing) -> Pose
quat_yaw, yaw_of, nlerp, qmul, lerp3 ...

// views keyed by deterministic spawn keys
View_Set($V)  set_begin / set_see(key) -> (^Entry, spawned) / set_end(now_s, linger_s)
              -> despawned (started lingering) and removed (views to destroy or pool)
Pool($V)      pool_get / pool_put

// predicted events
Event_Tracker($E)  tracker_init(id_of) / tracker_begin_tick / tracker_event / tracker_end_tick / tracker_verified
                   -> out: [](Fire | Cancel | Confirm, E)
Event_Id { tick, kind, entity, extra }
```

## How it works

- **Frames.** The sim thread publishes the newest frame through a triple buffer; the renderer takes the newest
  one and interpolates between ticks P−1 and P with `alpha`. No locks.
- **Tracks.** Each view keeps the poses of its last 4 ticks. Interpolation uses ticks P−1 and P. When a rollback
  re-publishes a tick with a different pose, the difference goes into an error offset and the samples after it
  are dropped. The display is `interpolated pose + error`, and the error decays as `exp(-dt / tau)`. A
  correction or a tick-to-tick move longer than `teleport_dist` snaps instead. Rotations are handled the same way
  with quaternions.
- **Lifetimes.** Views are keyed by the sim's spawn keys, not by slot indices. A key missing from a frame starts
  a linger, which covers an exit animation or a rollback that brings the entity back (it is revived, not
  respawned). A re-used slot gets a new key, so it gets a new view.
- **Events.** The tracker sees every simulated tick: predicted, re-simulated and verified. An event produced
  again by a re-simulation fires only once. One that a re-simulation drops is cancelled. Once its tick is
  verified it is confirmed. Re-simulations of ticks at or below the verified tick are ignored, since they are
  final.

## Open

- Extrapolation past P (alpha > 1) when the sim stalls; today it holds at P.
- Per-kind smoothing settings authored in data.
