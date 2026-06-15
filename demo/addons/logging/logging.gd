extends Node
class_name DebugLogger

@export var is_enabled: bool = OS.is_debug_build()

class Session:
	var interval_ms: int
	var last_log_ms: int = 0
	var last_p_frame: int = -1
	var last_ph_frame: int = -1
	var _should_log_session: bool = false
	
	func _init(p_enable: bool = false, interval: int = 30) -> void:
		interval_ms = interval
		_should_log_session = p_enable

	func d(...args) -> void:
		if Log.is_enabled and should_log():
			Log._log_with_color("yellow", args)

	func e(...args) -> void:
		if Log.is_enabled and should_log():
			Log._log_with_color("red", args)
		
	func should_log() -> bool:
		if not _should_log_session: return false
		var curr_p := Engine.get_process_frames()
		var curr_ph := Engine.get_physics_frames()
		
		# Keeps all logs in the same frame together
		if curr_p == last_p_frame and curr_ph == last_ph_frame:
			return true
			
		var now := Time.get_ticks_msec()
		if now - last_log_ms < interval_ms:
			return false
			
		last_log_ms = now
		last_p_frame = curr_p
		last_ph_frame = curr_ph
		return true

func d(...args) -> void:
	_log_with_color("yellow", args)

func e(...args) -> void:
	_log_with_color("red", args)
	
func _log_with_color(color: String, args: Array) -> void:
	if not is_enabled:
		return

	var stack := get_stack()
	var tag := "GLOBAL"
	
	# Detects the calling file
	if stack.size() > 2:
		var full_path: String = stack[2].source
		tag = full_path.get_file().get_basename().to_upper()

	var message := " ".join(args.map(func(v): return str(v)))
	print_rich("[b][color=%s][%s][/color][/b] %s" % [color, tag, message])
