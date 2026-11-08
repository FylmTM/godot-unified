// Host-agnostic view logic between a rollback sim and a renderer (no Godot here; tested in tests/view):
//
//   sync.odin    Triple (sim thread -> render thread, newest frame wins), Queue (SPSC events), alpha
//   track.odin   per-view pose history: interpolation between the last two ticks, rollback corrections
//                smoothed by an exponentially decaying error offset, teleports snap
//   set.odin     views keyed by deterministic spawn keys: spawn, despawn with linger, revive, remove; Pool
//   events.odin  predicted events: fire once, cancel when a re-simulation drops them, confirm when verified
//
// The render side may use f32 and transcendentals freely: nothing here feeds back into the sim.
package view
