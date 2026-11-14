extends UnifiedSettings
## drift's settings: the shared ones and the best survival time.


func _game_keys() -> Dictionary:
	return {&"best_time": ["stats", 0.0]}
