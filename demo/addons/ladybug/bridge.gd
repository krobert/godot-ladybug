extends Node

signal database_ready

@export var logger: DebugLogger

var _db: Ladybug
var _schema: LadybugSchema

var _write_queue: Array = []      # {cypher, params, callback: Callable}
var _is_ready: bool = false
var _initializing: bool = false
var _is_writing: bool = false
var _prepared_read: Dictionary = {}  # name -> cypher


func _ready():
	_db = Ladybug.new()

func init_db(schema: LadybugSchema, user_path: String) -> void:
	_schema = schema
	if _is_ready:
		logger.d("Database already initialised")
		return
	
	_initializing = true
	
	var err = open_db(user_path)
	if err != OK:
		logger.e("Database failed to open...")
		return
	logger.d("Database opened, checking version...")

	# Read current schema version from a Meta node table
	var current_version: int = _get_stored_version()
	logger.d("Stored schema version: %d, resource version: %d" % [current_version, schema.version])

	if current_version < schema.version:
		logger.d("Running %d setup queries..." % schema.setup_queries.size())
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
		logger.d( "Schema up to date, no migration needed")

	logger.d("Database ready for queries")
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
			logger.e("Failed to create database directory: " + dir)
			return FAILED

	var err = _db.open(absolute_path)
	if err != OK:
		logger.e("Failed to open database: " + absolute_path)
	else:
		logger.d("Database opened: " + absolute_path)
	return err

func close_db():
	_is_ready = false
	_db.close()
	logger.d( "Database closed")

# ------------------------------------------------------------------
#  Read-only query (no write keywords allowed)
# ------------------------------------------------------------------
func read_query(cypher: String, params: Dictionary = {}) -> Array:
	if not _is_ready:
		logger.e("read_query called before database is ready")
		return []
	
	# Block write keywords
	var upper = cypher.to_upper()
	for keyword in ["CREATE ", "DELETE ", "SET ", "MERGE ", "DROP ", "COPY ", "ALTER "]:
		if keyword in upper:
			logger.e("read_query used for a write operation. Use write_query.")
			return []

	if params.is_empty():
		return _db.query(cypher)

	# Cache prepared statement by cypher hash
	var key = "read_" + cypher.md5_text()
	if not key in _prepared_read:
		var err = _db.prepare(key, cypher)
		if err != OK:
			logger.e("Failed to prepare read: " + cypher)
			return []
		_prepared_read[key] = cypher
	return _db.execute_prepared(key, params)

# ------------------------------------------------------------------
#  Write queue (safe sequential writes)
# ------------------------------------------------------------------
func write_query(cypher: String, params: Dictionary = {}, callback: Callable = Callable()) -> void:
	if not _is_ready and not _initializing:
		logger.e("write_query called before database is ready")
		return

	# ensure it contains a write keyword (soft guard)
	var upper = cypher.to_upper()
	var is_write = false
	for keyword in ["CREATE", "DELETE", "SET", "MERGE", "DROP", "COPY", "ALTER"]:
		if keyword in upper:
			is_write = true
			break
	if not is_write:
		logger.d("write_query used with no write keyword: " + cypher)

	_write_queue.append({"cypher": cypher, "params": params, "callback": callback})
	_process_queue()

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
			logger.e(error_msg)
		else:
			if params.is_empty():
				result = _db.query(cypher)
			else:
				var stmt_name = "write_" + cypher.md5_text()
				if _db.prepare(stmt_name, cypher) != OK:
					error_msg = "Failed to prepare write: " + cypher
					logger.e(error_msg)
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
