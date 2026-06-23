extends Node

signal database_ready

@export var logger: DebugLogger

# DB Core
var _db: Ladybug
var _schema: LadybugSchema
var _write_queue: Array = []
var _is_ready: bool = false
var _initializing: bool = false
var _is_writing: bool = false
var _prepared_read: Dictionary = {}

# Sync Bridge
var _flattener: Flattener
var _delimiter: String = "_"

func _ready() -> void:
	_db = Ladybug.new()
	if ClassDB.class_exists("GlazeFlattener"):
		_flattener = Flattener.new()
	else:
		if logger: logger.e("GlazeFlattener GDExtension not found.")

# ------------------------------------------------------------------
#  Database Init & Queue Management
# ------------------------------------------------------------------
func init_db(schemas: Array[LadybugSchema], user_path: String) -> void:
	if _is_ready:
		if logger: logger.d("Database already initialised")
		return
	
	_initializing = true
	var err = open_db(user_path)
	if err != OK:
		if logger: logger.e("Database failed to open...")
		return
		
	_init_meta_table()

	for schema in schemas:
		var schema_key: String = schema.resource_name 
		var current_version: int = _get_stored_version(schema_key)
		
		if current_version < schema.version:
			if logger: logger.d("Migrating '%s' to version %d" % [schema_key, schema.version])
			for query in schema.setup_queries:
				var trimmed = query.strip_edges()
				if not trimmed.is_empty():
					_db.query(trimmed) # Direct execution: No async await, zero queue GC overhead
			
			_set_stored_version(schema_key, schema.version)

	_is_ready = true
	_initializing = false
	if logger: logger.d("Database ready")
	database_ready.emit()
	

func is_ready() -> bool:
	return _is_ready

func open_db(user_path: String) -> Error:
	var absolute_path = ProjectSettings.globalize_path("res://" + user_path)
	var dir = absolute_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err = DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			if logger: logger.e("Failed to create database directory: " + dir)
			return FAILED

	var err = _db.open(absolute_path)
	if err != OK:
		if logger: logger.e("Failed to open database: " + absolute_path)
	else:
		if logger: logger.d("Database opened: " + absolute_path)
	return err

func close_db() -> void:
	_is_ready = false
	_db.close()
	if logger: logger.d("Database closed")

func read_query(cypher: String, params: Dictionary = {}) -> Array:
	if not _is_ready:
		if logger: logger.e("read_query called before database is ready")
		return []
	
	var upper = cypher.to_upper()
	for keyword in ["CREATE ", "DELETE ", "SET ", "MERGE ", "DROP ", "COPY ", "ALTER "]:
		if keyword in upper:
			if logger: logger.e("read_query used for a write operation. Use write_query.")
			return []

	if params.is_empty():
		return _db.query(cypher)

	var key = "read_" + cypher.md5_text()
	if not key in _prepared_read:
		var err = _db.prepare(key, cypher)
		if err != OK:
			if logger: logger.e("Failed to prepare read: " + cypher)
			return []
		_prepared_read[key] = cypher
	return _db.execute_prepared(key, params)

func write_query(cypher: String, params: Dictionary = {}, callback: Callable = Callable()) -> void:
	if not _is_ready and not _initializing:
		if logger: logger.e("write_query called before database is ready")
		return

	var upper = cypher.to_upper()
	var is_write = false
	for keyword in ["CREATE", "DELETE", "SET", "MERGE", "DROP", "COPY", "ALTER"]:
		if keyword in upper:
			is_write = true
			break
	if not is_write:
		if logger: logger.d("write_query used with no write keyword: " + cypher)

	_write_queue.append({"cypher": cypher, "params": params, "callback": callback})
	_process_queue()

func _init_meta_table() -> void:
	_db.query("CREATE NODE TABLE IF NOT EXISTS Meta(key STRING PRIMARY KEY, value INT64)")

func _get_stored_version(schema_key: String) -> int:
	var rows = _db.query("MATCH (m:Meta {key: '%s'}) RETURN m.value" % schema_key)
	if rows.is_empty():
		return 0
	return int(rows[0]["m.value"])

func _set_stored_version(schema_key: String, version: int) -> void:
	_db.query("MERGE (m:Meta {key: '%s'}) SET m.value = %d" % [schema_key, version])

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
			if logger: logger.e(error_msg)
		else:
			if params.is_empty():
				result = _db.query(cypher)
			else:
				var stmt_name = "write_" + cypher.md5_text()
				if _db.prepare(stmt_name, cypher) != OK:
					error_msg = "Failed to prepare write: " + cypher
					if logger: logger.e(error_msg)
				else:
					result = _db.execute_prepared(stmt_name, params)
			
			if typeof(result) == TYPE_ARRAY and result.is_empty():
				pass
				
		if _write_queue.size() > 0:
			await get_tree().process_frame
			
		if cb.is_valid():
			cb.call(result, error_msg)

		if _write_queue.size() > 0:
			await get_tree().process_frame

	_is_writing = false

# ------------------------------------------------------------------
#  Glaze Flattening Hooks
# ------------------------------------------------------------------

func configure(delimiter: String) -> void:
	_delimiter = delimiter

func process_and_flatten(node_label: String, id: String, operation: String, incoming_delta_str: String, schema_keys: Array) -> Dictionary:
	if not _flattener or not _is_ready: 
		return {}

	var existing_data: String = ""
	if operation == "UPDATE":
		var fetch_cypher = "MATCH (n:%s {id: $id}) RETURN n.data LIMIT 1" % node_label.capitalize()
		var rows = read_query(fetch_cypher, {"id": id})
		if not rows.is_empty() and rows[0].has("n.data"):
			var raw_variant = rows[0]["n.data"]
			if typeof(raw_variant) == TYPE_STRING:
				existing_data = raw_variant

	return _flattener.process(id, operation, incoming_delta_str, existing_data, schema_keys, _delimiter)

func format_crdt_delta(incoming_delta_str: String) -> String:
	if not _flattener: return ""
	return _flattener.format_crdt_delta(incoming_delta_str)
