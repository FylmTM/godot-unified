extends UnifiedSfx
## friendslop's sounds, besides the library's `click` and `gem`.


func _add_sounds() -> void:
	add(&"pop", tone(0.09, 420.0, 140.0, 0.45, 0.25), 0.03)
	add(&"hit", tone(0.12, 220.0, 90.0, 0.6, 0.5), 0.05)
	add(&"die", tone(0.45, 330.0, 70.0, 0.6, 0.3))
	add(&"start", arpeggio([392.0, 523.25, 659.25], 0.09, 0.3))
	add(&"level", arpeggio([523.25, 659.25, 783.99, 1046.5], 0.07, 0.3))
	add(&"respawn", arpeggio([329.63, 493.88, 659.25], 0.06, 0.25))
