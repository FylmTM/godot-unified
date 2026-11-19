extends Marker2D
## A ship's spawn spot: one per slot, the slot its `slot` says. Exported by unified's level exporter.

const UNIFIED_KIND := "spawn"

## The player slot whose spawn spot this is (each slot exactly once).
@export var slot := 0
