class_name UnifiedCrowdClip
extends Resource
## One clip a crowd plays (UnifiedCrowdRecipe.clips): which animation, the rate it is baked at, and whether it loops.

## Whether a clip loops: as its Animation says (its loop_mode), or said here, which the bake holds to the Animation's.
enum Loop { FROM_ANIMATION, LOOPS, HOLDS }

## The frames a second a clip is baked at unless it says otherwise: a model's usual key rate.
const DEFAULT_RATE := 30.0

## The animation, as the character's AnimationPlayer names it (`Library/Clip`).
@export var animation: StringName = &""
## The frames a second it is baked at. Its length must be a whole number of its frames. The shader blends two frames'
## matrices linearly where the scene turns each bone along an arc, so a clip whose bones turn fast between keys is baked
## at a multiple of its keys' rate (UnifiedCrowdCheck's parity measures the cut).
@export var rate := DEFAULT_RATE
## Whether it loops: FROM_ANIMATION reads the Animation's loop_mode (a loop wraps, and its last frame must be its first
## pose again; a one-shot holds its first frame before its start and its last past its end). LOOPS or HOLDS says so
## here, and the bake refuses a clip whose Animation says otherwise.
@export var loop := Loop.FROM_ANIMATION


func _init(clip_animation := &"", clip_rate := DEFAULT_RATE, clip_loop := Loop.FROM_ANIMATION) -> void:
	animation = clip_animation
	rate = clip_rate
	loop = clip_loop


## Whether it loops, given its Animation (null: as said here, a one-shot unless LOOPS).
func loops(clip: Animation) -> bool:
	match loop:
		Loop.LOOPS:
			return true
		Loop.HOLDS:
			return false
	return clip != null and clip.loop_mode != Animation.LOOP_NONE
