# view

Decided autonomously 2026-11-09, pending developer review.

Host-agnostic view logic between the rollback sim and any renderer (`src/view`, no Godot; tests in `tests/view`).
Render-side code: f32 and transcendentals are fine, nothing feeds back into the sim.

## API

```odin
// sim thread -> render thread
Triple($T)  triple_init / triple_back / triple_publish / triple_front -> (^T, fresh)   // newest wins, no tearing
Queue($T, N)  queue_push (false when full) / queue_peek (nil: empty) / queue_pop / queue_len // SPSC, N a power of two
alpha(now_us, due_us, tick_us) -> f32        // 0 at tick P's due time, 1 one tick later (clamped)

// per-view pose history
Pose { pos: [3]f32, rot: [4]f32 }            Smoothing { tau_s = 0.1, teleport_dist = 4 }
track_push(^Track, tick, pose, smoothing)    // re-pushing a tick = a rollback correction
track_push_prev(^Track, tick, prev, has_prev, smoothing) // tick - 1 before a new tick: corrected, or the last shown
track_sample(^Track, tick, alpha, dt_s, smoothing) -> Pose
quat_yaw, yaw_of, nlerp, qmul, lerp3 ...
quat_angle2d(a) / angle2d_of(q)              // 2D: rotation about +Z (Godot's Node2D.rotation), signed off

// views keyed by deterministic spawn keys (K: a Key, or a wider key: unified:godot uses kind and key)
View_Set($K, $V)  set_begin / set_see(key) -> (^Entry, spawned; set entry.linger_s) / set_end(now_s)
                  -> despawned (started lingering) and removed (views to destroy or pool)
                  set_get(key) / set_remove(key) -> (view, ok)  // removed at once, no linger (a cancelled spawn)
Pool($V)      pool_get / pool_put

// predicted events
Event_Tracker($E)  tracker_init(id_of) / tracker_begin_tick / tracker_event / tracker_end_tick / tracker_verified
                   -> out: []{Emitted | Confirmed | Cancelled, E}
Event_Id { tick, kind, entity, player, nth }  // the subject convention: src/sim/SPEC.md "Events"
```

## How it works

- **Frames.** The sim thread publishes the newest frame through a triple buffer; the renderer takes the newest
  one and interpolates between ticks P−1 and P with `alpha`. No locks.
- **Tracks.** Each view keeps the poses of its last 4 ticks. Interpolation uses ticks P−1 and P. When a rollback
  re-publishes a tick with a different pose, the difference goes into an error offset and the samples after it
  are dropped. The display is `interpolated pose + error`, and the error decays as `exp(-dt / tau)`. A
  correction or a tick-to-tick move longer than `teleport_dist` snaps instead. Rotations are handled the same way
  with quaternions. Before a new tick, `track_push_prev` records tick − 1: a corrected pose (after a rollback)
  becomes a correction; when the history lacks tick − 1 (the renderer skipped frames, or the sim several ticks),
  the last shown pose starts it, so the display glides instead of jumping (#284, measured under lag).
- **Lifetimes.** Views are keyed by the sim's spawn keys, not by slot indices. A key missing from a frame starts
  a linger (its entry's `linger_s`), which covers an exit animation or a rollback that brings the entity back (it is
  revived, not respawned). A re-used slot gets a new key, so it gets a new view.
- **Events** (D6, the #6 sitting; its states renamed in #168's review). The tracker sees every simulated tick:
  predicted, re-simulated and verified. Every event is **Emitted** exactly once, the first time any simulation of
  its tick produces it (a re-simulation that produces it again emits nothing new), then exactly once either
  **Confirmed** (its tick is verified) or **Cancelled** (a re-simulation drops it). An event first produced when its
  tick is verified is Emitted, then Confirmed, in the same output. Cancels and confirmations come out in tick order
  and, within a tick, in emission order (#152). Re-simulations of ticks at or below the verified tick are
  ignored, since they are final.

## Open

- Extrapolation past P (alpha > 1) when the sim stalls; today it holds at P.
- Per-kind smoothing settings authored in data.
