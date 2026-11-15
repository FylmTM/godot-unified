extends Control
## The toy's HUD view (Hud_Data in ext/ext.odin): data only (a Control root gets no pose). It leaves out
## `pad_check` on purpose: the host reports the missing property as an error the suite expects.

var bumps := 0
var bump_sum := 0
var marks := 0
var mark_at := Vector2.ZERO
var mark_normal := Vector3.ZERO
var mark_weight := 0.0
var mark_count := 0
var mark_shape := &""
var mark_shapes := 0
var mark_loud := false
var x := 0.0
var y := 0.0
var spawned := 0
var tint := Vector4.ZERO
var turn := Quaternion(1, 0, 0, 0)
