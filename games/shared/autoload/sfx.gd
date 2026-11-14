class_name UnifiedSfx
extends Node
## Procedural sound effects, the base of a game's `Sfx` autoload: synthesized once at boot (no audio assets),
## played with `Sfx.play(&"pop")` from a small voice pool on the SFX bus. A sound with a minimum gap is rate-limited,
## so a burst of the same event doesn't clip. The shared UI plays `click` and `gem`; a game adds its own sounds in
## `_add_sounds()` with `add()`, built with `tone()` and `arpeggio()`.

const RATE := 22050
const VOICES := 12

var _streams: Dictionary[StringName, AudioStream] = {}
var _min_gap: Dictionary[StringName, float] = {}
var _last_played: Dictionary[StringName, float] = {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add(&"click", tone(0.05, 880.0, 660.0, 0.35, 0.0))
	add(&"gem", tone(0.08, 1320.0, 1760.0, 0.25, 0.0), 0.04)
	_add_sounds()
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = &"SFX"
		add_child(p)
		_players.append(p)


## The game's sounds: `add()` each.
func _add_sounds() -> void:
	pass


## Registers a sound; `min_gap` (seconds) rate-limits it.
func add(sound: StringName, stream: AudioStream, min_gap := 0.0) -> void:
	_streams[sound] = stream
	if min_gap > 0.0:
		_min_gap[sound] = min_gap


func play(sound: StringName, volume_db := 0.0, pitch := 1.0) -> void:
	var stream: AudioStream = _streams.get(sound)
	if stream == null:
		push_error("Sfx: no sound %s" % sound)
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_played.get(sound, -1.0) < _min_gap.get(sound, 0.0):
		return
	_last_played[sound] = now
	var p := _players[_next]
	_next = (_next + 1) % VOICES
	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


## A sine sweep from f0 to f1 (Hz) with an exponential decay, mixed with `noise` (0..1) low-passed noise.
static func tone(seconds: float, f0: float, f1: float, gain: float, noise: float) -> AudioStreamWAV:
	var n := int(seconds * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = int(f0 * 1000.0 + f1)
	var lp := 0.0
	for i in n:
		var t := float(i) / n
		phase += TAU * lerpf(f0, f1, t) / RATE
		lp = lerpf(lp, rng.randf_range(-1.0, 1.0), 0.35)
		var env := exp(-t * 5.0) * minf(1.0, i / 60.0)
		var s := (sin(phase) * (1.0 - noise) + lp * noise * 1.6) * env * gain
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav(data)


## Notes (Hz) struck `step` seconds apart, each with its octave, ringing out.
static func arpeggio(freqs: Array[float], step: float, gain: float) -> AudioStreamWAV:
	var per := int(step * RATE)
	var n := per * freqs.size() + int(0.25 * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var s := 0.0
		for k in freqs.size():
			if i >= k * per:
				var t := float(i - k * per) / RATE
				s += (sin(TAU * freqs[k] * t) + 0.3 * sin(TAU * freqs[k] * 2.0 * t)) * exp(-t * 7.0)
		data.encode_s16(i * 2, int(clampf(s * gain, -1.0, 1.0) * 32767.0))
	return _wav(data)


static func _wav(data: PackedByteArray) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = data
	return w
