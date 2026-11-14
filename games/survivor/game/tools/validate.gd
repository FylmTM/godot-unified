extends UnifiedValidate
## survivor's project check (the library's, UnifiedValidate) and its contract: with the game library loaded, the
## mock session reports what the native one does (every constants() key, and hud() before any session), so the
## mock's copy of the sim's numbers can't drift.

const MOCK := "res://game/session/mock_session.gd"


func _check_contract() -> String:
	if game.is_mock:
		return "skipped (mock session)"
	var mock: Node = (load(MOCK) as GDScript).new()
	_compare("constants()", mock.constants(), game.session.constants())
	_compare("hud() before a session", mock.hud(), game.session.hud())
	mock.free()
	return "ok"


func _compare(what: String, mock: Dictionary, native: Dictionary) -> void:
	for key: String in native:
		if not mock.has(key):
			log_capture.add("mock %s lacks key %s" % [what, key], MOCK)
		elif var_to_str(mock[key]) != var_to_str(native[key]):
			log_capture.add("mock %s[%s] differs from the native session: %s vs %s" % [what, key, short(mock[key]),
				short(native[key])], MOCK)
	for key: String in mock:
		if not native.has(key):
			log_capture.add("mock %s has key %s the native session lacks" % [what, key], MOCK)
