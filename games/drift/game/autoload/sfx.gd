extends UnifiedSfx
## drift's sounds, besides the library's `click` and `gem`.


func _add_sounds() -> void:
	add(&"fire", tone(0.05, 1200.0, 500.0, 0.16, 0.15), 0.05)
	add(&"pop", tone(0.09, 420.0, 140.0, 0.45, 0.25), 0.03)
	add(&"hit", tone(0.12, 220.0, 90.0, 0.6, 0.5), 0.05)
	add(&"boom", tone(0.6, 90.0, 30.0, 0.9, 0.85), 0.08)
	add(&"boost", tone(0.22, 160.0, 520.0, 0.35, 0.7))
	add(&"warp", arpeggio([659.25, 987.77, 1318.5], 0.04, 0.25))
	add(&"wave", arpeggio([523.25, 659.25, 783.99, 1046.5], 0.07, 0.3))
	add(&"start", arpeggio([392.0, 523.25, 659.25], 0.09, 0.3))
	add(&"over", arpeggio([523.25, 415.3, 329.63, 261.63], 0.14, 0.3))
	add(&"join", arpeggio([329.63, 493.88, 659.25], 0.06, 0.25))
