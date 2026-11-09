extends Node
## Tiny procedural sound effects, synthesized once at boot (no audio assets): `Sfx.play(&"pop")`.
## A small voice pool on the SFX bus; the same sound is rate-limited so a burst of shots doesn't clip.

const RATE := 22050
const VOICES := 12
const MIN_GAP := {&"fire": 0.05, &"pop": 0.03, &"gem": 0.04, &"hit": 0.05, &"boom": 0.08}

var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _last_played := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_streams[&"click"] = _tone(0.05, 880.0, 660.0, 0.35, 0.0)
	_streams[&"fire"] = _tone(0.05, 1200.0, 500.0, 0.16, 0.15)
	_streams[&"pop"] = _tone(0.09, 420.0, 140.0, 0.45, 0.25)
	_streams[&"hit"] = _tone(0.12, 220.0, 90.0, 0.6, 0.5)
	_streams[&"gem"] = _tone(0.08, 1320.0, 1760.0, 0.25, 0.0)
	_streams[&"boom"] = _tone(0.6, 90.0, 30.0, 0.9, 0.85)
	_streams[&"boost"] = _tone(0.22, 160.0, 520.0, 0.35, 0.7)
	_streams[&"warp"] = _arpeggio([659.25, 987.77, 1318.5], 0.04, 0.25)
	_streams[&"wave"] = _arpeggio([523.25, 659.25, 783.99, 1046.5], 0.07, 0.3)
	_streams[&"start"] = _arpeggio([392.0, 523.25, 659.25], 0.09, 0.3)
	_streams[&"over"] = _arpeggio([523.25, 415.3, 329.63, 261.63], 0.14, 0.3)
	_streams[&"join"] = _arpeggio([329.63, 493.88, 659.25], 0.06, 0.25)
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = &"SFX"
		add_child(p)
		_players.append(p)


## Silences everything for good (`Game.quit_app`). The AudioServer's mix thread frees the stopped playbacks a mix
## or two later; any it still holds when it shuts down are reported as leaked at exit. Returns weak refs to them,
## to wait on.
func shut_down() -> Array[WeakRef]:
	var out: Array[WeakRef] = []
	for p in _players:
		if p.has_stream_playback():
			out.append(weakref(p.get_stream_playback()))
		p.stop()
	return out


func play(sound: StringName, volume_db := 0.0, pitch := 1.0) -> void:
	var stream: AudioStream = _streams.get(sound)
	if stream == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - float(_last_played.get(sound, -1.0)) < float(MIN_GAP.get(sound, 0.0)):
		return
	_last_played[sound] = now
	var p := _players[_next]
	_next = (_next + 1) % VOICES
	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


## A sine sweep from f0 to f1 with an exponential decay, optionally mixed with noise.
func _tone(seconds: float, f0: float, f1: float, gain: float, noise: float) -> AudioStreamWAV:
	var n := int(seconds * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = int(f0 * 1000.0 + f1)
	var lp := 0.0
	for i in n:
		var t := float(i) / n
		var f := lerpf(f0, f1, t)
		phase += TAU * f / RATE
		lp = lerpf(lp, rng.randf_range(-1.0, 1.0), 0.35)
		var env := exp(-t * 5.0) * minf(1.0, i / 60.0)
		var s := (sin(phase) * (1.0 - noise) + lp * noise * 1.6) * env * gain
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav(data)


func _arpeggio(freqs: Array, step: float, gain: float) -> AudioStreamWAV:
	var per := int(step * RATE)
	var tail := int(0.25 * RATE)
	var n := per * freqs.size() + tail
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var s := 0.0
		for k in freqs.size():
			var start := k * per
			if i >= start:
				var t := float(i - start) / RATE
				s += (sin(TAU * freqs[k] * t) + 0.3 * sin(TAU * freqs[k] * 2.0 * t)) * exp(-t * 7.0)
		data.encode_s16(i * 2, int(clampf(s * gain, -1.0, 1.0) * 32767.0))
	return _wav(data)


func _wav(data: PackedByteArray) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w
