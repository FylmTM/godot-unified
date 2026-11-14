extends UnifiedSettings
## survivor's settings: the library's, the 3D resolution, and the best survival time.


func _game_keys() -> Dictionary:
	return {
		&"render_scale": OPTIONAL[&"render_scale"],
		&"best_time": ["stats", 0.0],
	}
