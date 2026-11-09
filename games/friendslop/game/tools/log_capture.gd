extends Logger
## Collects engine and script errors in-process (OS.add_logger, Godot 4.5+) so tools can fail on them: Godot's
## exit code stays 0 on script errors.

var errors: Array[Dictionary] = []
var warnings: Array[Dictionary] = []
var _m := Mutex.new()


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtrace: Array[ScriptBacktrace]) -> void:
	var e := {"type": error_type, "msg": rationale if rationale != "" else code, "fn": function, "at": "%s:%d" % [file, line]}
	if not script_backtrace.is_empty() and script_backtrace[0].get_frame_count() > 0:
		e["bt"] = "%s:%d" % [script_backtrace[0].get_frame_file(0), script_backtrace[0].get_frame_line(0)]
	_m.lock()
	if error_type == ERROR_TYPE_WARNING:
		warnings.append(e)
	else:
		errors.append(e)
	_m.unlock()


func _log_message(message: String, error: bool) -> void:
	# GDScript parse errors arrive as plain error messages ("SCRIPT ERROR: Parse Error: ...").
	if error:
		_m.lock()
		errors.append({"type": -1, "msg": message.strip_edges(), "fn": "", "at": ""})
		_m.unlock()


func add(msg: String, at: String) -> void:
	_m.lock()
	errors.append({"type": -2, "msg": msg, "fn": "", "at": at})
	_m.unlock()


func report() -> String:
	var lines := []
	for e in errors:
		lines.append("  ERROR %s  (%s)%s" % [e.msg, e.at, ("  <- " + e.bt) if e.has("bt") else ""])
	for w in warnings:
		lines.append("  warning %s  (%s)" % [w.msg, w.at])
	return "\n".join(lines)
