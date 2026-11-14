extends UnifiedSettings
## friendslop's settings: the library's, the 3D resolution, mouse look, and the best run time.


func _game_keys() -> Dictionary:
	return {
		&"render_scale": OPTIONAL[&"render_scale"],
		&"mouse_sensitivity": OPTIONAL[&"mouse_sensitivity"],
		&"invert_y": OPTIONAL[&"invert_y"],
		&"best_time": ["stats", 0.0],
	}
