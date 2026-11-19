class_name Banner
extends Label
## A big centred message that pops in, holds and fades out; a new one replaces it.

var _tween: Tween


## Shows `message` in `color` for `seconds`, then fades it out.
func show_message(message: String, color := UiTheme.TEXT, seconds := 1.5) -> void:
	text = message
	add_theme_color_override(&"font_color", color)
	pivot_offset = size / 2.0
	if _tween != null:
		_tween.kill()
	modulate.a = 0.0
	scale = Vector2(1.4, 1.4)
	_tween = create_tween()
	_tween.set_parallel()
	_tween.tween_property(self, "modulate:a", 1.0, 0.15)
	_tween.tween_property(self, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.chain().tween_interval(seconds)
	_tween.chain().tween_property(self, "modulate:a", 0.0, 0.4)
