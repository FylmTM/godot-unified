class_name UnifiedLogCapture
extends Logger
## Collects engine and script errors in-process (`OS.add_logger`) so tool scripts can fail on them: Godot's exit
## code stays 0 on script errors. Each entry is {type, msg, fn, at} (plus `bt`, the script frame, when known).

## Types beside Logger's ErrorType: a plain error message (GDScript parse errors arrive so), a tool's own finding.
const MESSAGE := -1
const FINDING := -2

var errors: Array[Dictionary] = []
var warnings: Array[Dictionary] = []
var _m := Mutex.new()


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, script_backtrace: Array[ScriptBacktrace]) -> void:
	var e := {"type": error_type, "msg": rationale if rationale != "" else code, "fn": function,
		"at": "%s:%d" % [file, line]}
	if not script_backtrace.is_empty() and script_backtrace[0].get_frame_count() > 0:
		e["bt"] = "%s:%d" % [script_backtrace[0].get_frame_file(0), script_backtrace[0].get_frame_line(0)]
	_m.lock()
	if error_type == ERROR_TYPE_WARNING:
		warnings.append(e)
	else:
		errors.append(e)
	_m.unlock()


func _log_message(message: String, error: bool) -> void:
	if error:
		_append({"type": MESSAGE, "msg": message.strip_edges(), "fn": "", "at": ""})


## A tool's own finding, counted as an error.
func add(msg: String, at: String) -> void:
	_append({"type": FINDING, "msg": msg, "fn": "", "at": at})


func report() -> String:
	var lines: Array[String] = []
	for e in errors:
		lines.append("  ERROR %s  (%s)%s" % [e.msg, e.at, ("  <- " + e.bt) if e.has("bt") else ""])
	for w in warnings:
		lines.append("  warning %s  (%s)" % [w.msg, w.at])
	return "\n".join(lines)


func _append(e: Dictionary) -> void:
	_m.lock()
	errors.append(e)
	_m.unlock()
