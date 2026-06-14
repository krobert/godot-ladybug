extends Node

signal database_ready
signal database_error(message: String)

enum LogLevel {
	NONE   = 0,
	ERROR  = 1,
	WARN   = 2,
	INFO   = 4,
	ALL    = 7   # ERROR | WARN | INFO
}

var _db: Ladybug
var _schema: LadybugSchema

var _write_queue: Array = []      # {cypher, params, callback: Callable}
var _is_ready: bool = false
var _initializing: bool = false
var _is_writing: bool = false
var _prepared_read: Dictionary = {}  # name -> cypher

var _log_level: int = LogLevel.ERROR | LogLevel.WARN

func _ready():
	_db = Ladybug.new()

func init_db(schema: LadybugSchema, user_path: String) -> void:
	_schema = schema
	if _is_ready:
		_log(LogLevel.WARN, "Database already initialised")
		return
	
	_initializing = true
	
	var err = open_db(user_path)
	if err != OK:
		_log(LogLevel.ERROR, "DEBUG: Database failed to open...")
		return
	_log(LogLevel.INFO, "DEBUG: Database opened, checking version...")

	# Read current schema version from a Meta node table
	var current_version: int = _get_stored_version()
	_log(LogLevel.INFO, "Stored schema version: %d, resource version: %d" % [current_version, schema.version])

	if current_version < schema.version:
		_log(LogLevel.INFO, "Running %d setup queries..." % schema.setup_queries.size())
		# Enqueue all setup queries as writes
		for query in schema.setup_queries:
			var trimmed = query.strip_edges()
			if trimmed.is_empty():
				continue
			write_query(trimmed, {})   # no callback needed

		# Wait until the write queue is completely drained
		await _wait_for_queue_empty()

		# Store the new version
		_set_stored_version(schema.version)
	else:
		_log(LogLevel.INFO, "Schema up to date, no migration needed")

	_log(LogLevel.INFO, "Database ready for queries")
	_is_ready = true
	database_ready.emit()

func is_ready() -> bool:
	return _is_ready

# ------------------------------------------------------------------
#  Open / Close
# ------------------------------------------------------------------
func open_db(user_path: String) -> Error:
	#var real_path = OS.get_executable_path().get_base_dir().path_join(user_path)
	var absolute_path = ProjectSettings.globalize_path("res://db/" + user_path)
	var dir = absolute_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err = DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			_log(LogLevel.ERROR, "Failed to create database directory: " + dir)
			return FAILED

	var err = _db.open(absolute_path)
	if err != OK:
		_log(LogLevel.ERROR, "Failed to open database: " + absolute_path)
	else:
		_log(LogLevel.INFO, "Database opened: " + absolute_path)
	return err

func close_db():
	_is_ready = false
	_db.close()
	_log(LogLevel.INFO, "Database closed")

# ------------------------------------------------------------------
#  Read-only query (no write keywords allowed)
# ------------------------------------------------------------------
func read_query(cypher: String, params: Dictionary = {}) -> Array:
	if not _is_ready:
		_log(LogLevel.ERROR, "read_query called before database is ready")
		return []
	
	# Block write keywords
	var upper = cypher.to_upper()
	for keyword in ["CREATE ", "DELETE ", "SET ", "MERGE ", "DROP ", "COPY ", "ALTER "]:
		if keyword in upper:
			_log(LogLevel.ERROR, "read_query used for a write operation. Use write_query.")
			return []

	if params.is_empty():
		return _db.query(cypher)

	# Cache prepared statement by cypher hash
	var key = "read_" + cypher.md5_text()
	if not key in _prepared_read:
		var err = _db.prepare(key, cypher)
		if err != OK:
			_log(LogLevel.ERROR, "Failed to prepare read: " + cypher)
			return []
		_prepared_read[key] = cypher
	return _db.execute_prepared(key, params)

# ------------------------------------------------------------------
#  Write queue (safe sequential writes)
# ------------------------------------------------------------------
func write_query(cypher: String, params: Dictionary = {}, callback: Callable = Callable()) -> void:
	if not _is_ready and not _initializing:
		_log(LogLevel.ERROR, "write_query called before database is ready")
		return

	# ensure it contains a write keyword (soft guard)
	var upper = cypher.to_upper()
	var is_write = false
	for keyword in ["CREATE", "DELETE", "SET", "MERGE", "DROP", "COPY", "ALTER"]:
		if keyword in upper:
			is_write = true
			break
	if not is_write:
		_log(LogLevel.WARN, "write_query used with no write keyword: " + cypher)

	_write_queue.append({"cypher": cypher, "params": params, "callback": callback})
	_process_queue()

# Logs
func set_log_level(level: int) -> void:
	_log_level = level

# Helpers for version storage
func _get_stored_version() -> int:
	# Ensure the Meta table exists (idempotent)
	_db.query("CREATE NODE TABLE IF NOT EXISTS Meta(key STRING PRIMARY KEY, value INT64)");
	var rows = _db.query("MATCH (m:Meta {key: 'schema_version'}) RETURN m.value")
	if rows.is_empty():
		return 0
	return int(rows[0]["m.value"])

func _set_stored_version(version: int) -> void:
	_db.query("MERGE (m:Meta {key: 'schema_version'}) SET m.value = %d" % version)

# Async helper: resolves when queue is empty
func _wait_for_queue_empty() -> void:
	while _write_queue.size() > 0 or _is_writing:
		await get_tree().process_frame
		
func _process_queue() -> void:
	if _is_writing:
		return
	_is_writing = true

	while _write_queue.size() > 0:
		var entry = _write_queue.pop_front()
		var cypher: String = entry.cypher
		var params: Dictionary = entry.params
		var cb: Callable = entry.callback

		var result: Variant = null
		var error_msg: String = ""

		if not _db.is_open():
			error_msg = "Database not open during write"
			_log(LogLevel.ERROR, error_msg)
		else:
			if params.is_empty():
				result = _db.query(cypher)
			else:
				var stmt_name = "write_" + cypher.md5_text()
				if _db.prepare(stmt_name, cypher) != OK:
					error_msg = "Failed to prepare write: " + cypher
					_log(LogLevel.ERROR, error_msg)
				else:
					result = _db.execute_prepared(stmt_name, params)
			
			# Check if result is an error (Ladybug may return empty array on failure + we already logged internal)
			# If we detected an "already exists" kind of error, downgrade to WARN
			# (The C++ layer already printed the error; we just avoid double‑screaming here)
			if typeof(result) == TYPE_ARRAY and result.is_empty():
				# Could be a successful non‑returning query (e.g., CREATE). That's fine.
				pass
				
		if _write_queue.size() > 0:
			await get_tree().process_frame
			
		if cb.is_valid():
			cb.call(result, error_msg)

		# Yield to prevent frame lockup
		if _write_queue.size() > 0:
			await get_tree().process_frame

	_is_writing = false

# ------------------------------------------------------------------
#  Error logging (copypaste ready)
# ------------------------------------------------------------------

func _log(level: LogLevel, msg: String) -> void:
	if not _should_log(level):
		return
	var prefix = "[LadybugBridge]"
	match level:
		LogLevel.ERROR:
			printerr(prefix, " ERROR: ", msg)
			database_error.emit(msg)
		LogLevel.WARN:
			push_warning(prefix, " WARN: ", msg)
		LogLevel.INFO:
			print(prefix, " INFO: ", msg)
			
func _should_log(level: LogLevel) -> bool:
	return (_log_level & level) != 0
