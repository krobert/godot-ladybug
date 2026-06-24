class_name LbBridge
extends Node

# ------------------------------------------------------------------
# Signals
# ------------------------------------------------------------------
signal database_ready

# ------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------
const WRITE_KEYWORDS: Array[String] = ["CREATE ", "DELETE ", "SET ", "MERGE ", "DROP ", "COPY ", "ALTER "]

# ------------------------------------------------------------------
# Private Variables
# ------------------------------------------------------------------
var _db: Ladybug
var _write_queue: Array[Dictionary] = []
var _prepared_stmts: Dictionary = {}
var _delimiter: String = "_"
var _is_ready: bool = false
var _initializing: bool = false
var _is_writing: bool = false

# ------------------------------------------------------------------
# Built-in Virtual Methods
# ------------------------------------------------------------------
func _ready() -> void:
	_db = Ladybug.new()

# ------------------------------------------------------------------
# Public Methods (Database Lifecycle)
# ------------------------------------------------------------------
func init_db(schemas: Array[LadybugSchema], user_path: String) -> void:
	if _is_ready:
		push_warning("Database already initialised")
		return
	
	_initializing = true
	if open_db(user_path) != OK:
		push_error("Database failed to open...")
		_initializing = false
		return
		
	var setup_res := _db.query("CREATE NODE TABLE IF NOT EXISTS Meta(key STRING PRIMARY KEY, value INT64)")
	if setup_res["status"] != OK:
		push_error("Failed to init meta table: ", setup_res["error"])
		_initializing = false
		return

	for schema in schemas:
		var schema_key: String = schema.resource_name
		var current_version := _get_stored_version(schema_key)
		
		if current_version < schema.version:
			print("Migrating '", schema_key, "' to version ", schema.version)
			for query in schema.setup_queries:
				var trimmed := query.strip_edges()
				if not trimmed.is_empty():
					_db.query(trimmed)
			_set_stored_version(schema_key, schema.version)

	_is_ready = true
	_initializing = false
	print("Database ready")
	database_ready.emit()

func is_ready() -> bool:
	return _is_ready

func open_db(user_path: String) -> Error:
	var absolute_path := ProjectSettings.globalize_path(user_path)
	var dir := absolute_path.get_base_dir()
	
	if not DirAccess.dir_exists_absolute(dir):
		if DirAccess.make_dir_recursive_absolute(dir) != OK:
			push_error("Failed to create database directory: ", dir)
			return FAILED

	var err := _db.open(absolute_path)
	if err != OK:
		push_error("Failed to open database: ", absolute_path)
	else:
		print("Database opened: ", absolute_path)
		
	return err

func close_db() -> void:
	_is_ready = false
	_db.close()
	print("Database closed")

func last_error() -> String:
	return _db.last_error()

# ------------------------------------------------------------------
# Public Methods (Queries)
# ------------------------------------------------------------------
func read_query(cypher: String, params: Dictionary = {}) -> Array:
	if not _is_ready:
		push_error("read_query called before database is ready")
		return []
	
	var upper := cypher.to_upper()
	for keyword in WRITE_KEYWORDS:
		if keyword in upper:
			push_error("read_query used for a write operation. Use write_query.")
			return []

	var res := _execute_query(cypher, params, "read_")
	if res["status"] == OK:
		return res["data"]
		
	push_error("Read query failed: ", res["error"])
	return []

func write_query(cypher: String, params: Dictionary = {}, callback: Callable = Callable()) -> void:
	if not _is_ready and not _initializing:
		push_error("write_query called before database is ready")
		return

	_write_queue.append({"cypher": cypher, "params": params, "callback": callback})
	_process_queue()

# ------------------------------------------------------------------
# Public Methods (Glaze Hooks)
# ------------------------------------------------------------------
func configure(delimiter: String) -> void:
	_delimiter = delimiter

func process_and_flatten(node_label: String, id: String, operation: String, incoming_delta_str: String, schema_keys: Array) -> Dictionary:
	if not _is_ready: 
		return {}

	var existing_data: String = ""
	if operation == "UPDATE":
		var fetch_cypher := "MATCH (n:%s {id: $id}) RETURN n.data LIMIT 1" % node_label.capitalize()
		var rows := read_query(fetch_cypher, {"id": id})
		if not rows.is_empty() and rows[0].has("n.data"):
			var raw_variant: Variant = rows[0]["n.data"]
			if typeof(raw_variant) == TYPE_STRING:
				existing_data = raw_variant

	var flattener := Flattener.new()
	return flattener.process(id, operation, incoming_delta_str, existing_data, schema_keys, _delimiter)

func format_crdt_delta(incoming_delta_str: String) -> String:
	var flattener := Flattener.new()
	return flattener.format_crdt_delta(incoming_delta_str)

# ------------------------------------------------------------------
# Private Methods
# ------------------------------------------------------------------
func _execute_query(cypher: String, params: Dictionary, prefix: String) -> Dictionary:
	if not _db.is_open():
		return {"status": FAILED, "error": "Database not open", "data": []}
		
	var result: Dictionary
	
	if params.is_empty():
		result = _db.query(cypher)
	else:
		var key := prefix + cypher.md5_text()
		if not key in _prepared_stmts:
			var prep := _db.prepare(key, cypher)
			if prep == OK:
				_prepared_stmts[key] = true
			else:
				var err_msg := "Failed to prepare statement: %s => cypher: %s" % [error_string(prep), cypher]
				push_error(err_msg)
				result = {"status": FAILED, "error": err_msg, "data": []}
				
		if key in _prepared_stmts:
			result = _db.execute_prepared(key, params)
			
	return result

func _get_stored_version(schema_key: String) -> int:
	var q_res := _db.query("MATCH (m:Meta {key: '%s'}) RETURN m.value" % schema_key)
	if q_res["status"] == OK and not q_res["data"].is_empty():
		return int(q_res["data"][0]["m.value"])
	return 0

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
		var entry: Dictionary = _write_queue.pop_front()
		var cypher: String = entry.cypher
		var params: Dictionary = entry.params
		var cb: Callable = entry.callback

		var res := _execute_query(cypher, params, "write_")
		
		if res["status"] != OK:
			push_error("Write query failed: ", res["error"])

		# Yielding here allows the main thread to process frames 
		# so the game doesn't freeze during heavy bulk writes.
		if _write_queue.size() > 0:
			await get_tree().process_frame
			
		if cb.is_valid():
			cb.call(res["status"], res["data"], res["error"])

	_is_writing = false
