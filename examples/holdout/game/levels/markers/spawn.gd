extends Marker3D
## A player's start spot: one per slot, the slot its `slot` says. Exported by unified's level exporter.

const UNIFIED_KIND := "spawn"

## The player slot whose start spot this is (each slot exactly once).
@export var slot := 0
