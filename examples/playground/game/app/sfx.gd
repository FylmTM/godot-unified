extends Node
## playground's sound effects (the `Sfx` autoload): synthesized once at boot (no audio assets), played with
## `Sfx.play(&"pop")` from a small voice pool on the SFX bus. A sound with a minimum gap is rate-limited, so a burst
## of the same event doesn't clip. The menus play `click` and `gem`; the game's own sounds are in `_add_sounds()`,
## built with `tone()` and `arpeggio()`.

const RATE := 22050
const VOICES := 12

var _streams: Dictionary[StringName, AudioStream] = {}
var _min_gap: Dictionary[StringName, float] = {}
var _last_played: Dictionary[StringName, float] = {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _closed := false
## Per voice: the token of the sound it plays (play's result, for stop).
var _tokens: PackedInt64Array = []
var _serial := 0


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
	_tokens.resize(VOICES)


func _add_sounds() -> void:
	add(&"shoot", tone(0.08, 900.0, 240.0, 0.4, 0.35), 0.03)
	add(&"boom", tone(0.6, 90.0, 30.0, 0.9, 0.85), 0.05)
	add(&"pop", tone(0.09, 420.0, 140.0, 0.45, 0.25), 0.03)
	add(&"grab", tone(0.07, 330.0, 520.0, 0.35, 0.0), 0.03)
	add(&"release", tone(0.08, 520.0, 260.0, 0.3, 0.1), 0.03)
	add(&"crack", tone(0.1, 180.0, 60.0, 0.5, 0.7), 0.06)
	add(&"blip", tone(0.05, 1100.0, 1300.0, 0.15, 0.0), 0.1)
	add(&"scene", arpeggio([392.0, 523.25, 659.25], 0.07, 0.3))


## Registers a sound; `min_gap` (seconds) rate-limits it.
func add(sound: StringName, stream: AudioStream, min_gap := 0.0) -> void:
	_streams[sound] = stream
	if min_gap > 0.0:
		_min_gap[sound] = min_gap


## Plays a sound on the next voice; nothing once the app is quitting (`close`). Returns a token for `stop` (0:
## nothing played).
func play(sound: StringName, volume_db := 0.0, pitch := 1.0) -> int:
	if _closed:
		return 0
	var stream: AudioStream = _streams.get(sound)
	if stream == null:
		push_error("Sfx: no sound %s" % sound)
		return 0
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_played.get(sound, -1.0) < _min_gap.get(sound, 0.0):
		return 0
	_last_played[sound] = now
	var p := _players[_next]
	_serial += 1
	_tokens[_next] = _serial
	_next = (_next + 1) % VOICES
	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()
	return _serial


## Stops the sound `token` started (play's result), if its voice still plays it: e.g. a mispredicted shot's, when
## its event is cancelled.
func stop(token: int) -> void:
	var voice := _tokens.find(token) if token != 0 else -1
	if voice >= 0:
		_players[voice].stop()
		_tokens[voice] = 0


## The app is quitting (Game.quit_app, which then stops the voices and waits for their playbacks): later plays
## are ignored. Events keep arriving until the quit (the frame it happens in too), and a playback started then would
## still be held at exit (a leak).
func close() -> void:
	_closed = true


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
