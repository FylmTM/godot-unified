class_name SimEvent
extends RefCounted
## The states a sim event arrives in (`sim_event(event, state, data)` and a view's `_sim_event(event, state, data)`,
## src/godot_host/SPEC.md "Events"): every event is EMITTED once, then once either CONFIRMED (its tick is verified)
## or CANCELLED (a re-simulation no longer produces it). The same values as the native
## `UnifiedSession.EVENT_EMITTED`, `EVENT_CONFIRMED` and `EVENT_CANCELLED` (`Game` checks it), kept here so scripts
## also run on a GDScript stand-in session, without the game library.

const EMITTED := 0
const CONFIRMED := 1
const CANCELLED := 2
