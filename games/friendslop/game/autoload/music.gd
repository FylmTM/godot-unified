extends AudioStreamPlayer
## A quiet generative pad on the Music bus, synthesized live into an AudioStreamGenerator: four slow chords, a
## soft bass that pulses only during a match. Per-frame cost in `cost_us`. Child of the Sfx autoload.

const RATE := 11025.0  # a soft pad needs no highs; halves the synthesis cost
## Seconds synthesized ahead: frame stalls up to this long (scene loads) play on without a dropout. An intensity
## change reaches the ear this much later, so the fade itself is quick (FADE_S) to keep the total under 2 s.
## Godot rounds the buffer up to a power of two frames: 0.7 s -> 8192 frames = 0.74 s (0.75 s would give 1.49 s).
const BUFFER_S := 0.7
const FADE_S := 1.0
const BAR := 4.0  # seconds per chord
## A minor-ish loop (Am - F - C - G), root frequencies of each chord voice.
const CHORDS := [
	[220.0, 261.63, 329.63],
	[174.61, 220.0, 261.63],
	[196.0, 261.63, 329.63],
	[196.0, 246.94, 293.66],
]

## 0 = calm (menu, lobby), 1 = match: fades the bass pulse in.
var intensity := 0.0
var _target := 0.0
var _t := 0.0
var _phases := PackedFloat64Array([0, 0, 0, 0, 0, 0])
var _playback: AudioStreamGeneratorPlayback
## Microseconds the last _process spent synthesizing (for the dev overlay / measurements).
var cost_us := 0


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = BUFFER_S
	stream = gen
	bus = &"Music"
	volume_db = -10.0
	play()
	_playback = get_stream_playback()


## Stops for good (quitting): the AudioServer frees the playback a few mixes later.
func shut_down() -> void:
	stop()
	_playback = null


func set_intensity(v: float) -> void:
	_target = clampf(v, 0.0, 1.0)


func _process(delta: float) -> void:
	intensity = move_toward(intensity, _target, delta / FADE_S)
	if _playback == null:
		return
	var t0 := Time.get_ticks_usec()
	var n := _playback.get_frames_available()
	var chord_i := int(_t / BAR) % CHORDS.size()
	var chord: Array = CHORDS[chord_i]
	var next: Array = CHORDS[(chord_i + 1) % CHORDS.size()]
	for i in n:
		var in_bar := fmod(_t, BAR) / BAR
		var xfade := smoothstep(0.85, 1.0, in_bar)
		var s := 0.0
		for v in 3:
			var f: float = lerpf(chord[v], next[v], xfade)
			_phases[v] = fmod(_phases[v] + TAU * f * 0.5 / RATE, TAU)
			_phases[v + 3] = fmod(_phases[v + 3] + TAU * f * 0.5 * 1.003 / RATE, TAU)  # detuned twin
			s += (sin(_phases[v]) + sin(_phases[v + 3])) * 0.06
		# Bass: the chord root an octave down, pulsing in eighths while a match runs.
		var beat := fmod(_t * 4.0, 1.0)
		var bass := sin(_t * TAU * float(chord[0]) * 0.25) * exp(-beat * 6.0) * 0.18 * intensity
		var swell := 0.75 + 0.25 * sin(_t * TAU / (BAR * 2.0))
		var sample := (s * swell + bass)
		_playback.push_frame(Vector2(sample, sample))
		_t += 1.0 / RATE
	cost_us = Time.get_ticks_usec() - t0
