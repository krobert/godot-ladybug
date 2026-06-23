extends Node

@export var schema: LadybugSchema = ExampleSchema.new()

signal write_finished(err: String)

func _ready() -> void:
	LadybugBridge.logger = Log # in my example global autoloadss
	Mcp.logger = Log
	LadybugBridge.database_ready.connect(_on_db_ready)
	LadybugBridge.init_db([schema], "db/people.lbdb")
	
	_register_tools()

func _on_db_ready() -> void:
	Mcp.start()
	# test db
	var result = LadybugBridge.read_query("MATCH (p:Person) RETURN p.name, p.age")
	for row in result:
		print("Name: ", row["p.name"], " Age: ", row["p.age"])

	LadybugBridge.write_query("CREATE (:Person {name: $n})", {"n": "Charlie"}, func(res, err):
		if err != "":
			print("Write failed: ", err)
		else:
			print("Write succeeded")
	)

func _exit_tree() -> void:
	Mcp.stop()
	LadybugBridge.close_db()

func _register_tools() -> void:
	Mcp.register_tool("list_people", "List all people in DB", {"type": "object"}, _list_people)
	Mcp.register_tool("add_person", 
		"Add a new person", 
		{"type": "object", "properties": {"name": {"type": "string"}, "age": {"type": "integer"}}, "required": ["name", "age"]}, 
		_add_person)
		
	Mcp.register_tool("update_person", "Update person age", 
		{"type": "object", "properties": {"name": {"type": "string"}, "age": {"type": "integer"}}, "required": ["name", "age"]}, 
		_update_person)
		
	Mcp.register_tool("remove_person", "Remove person by name", 
		{"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}, 
		_remove_person)

func _list_people(_args: Dictionary) -> Dictionary:
	return {"data": LadybugBridge.read_query("MATCH (p:Person) RETURN p.name, p.age")}

func _add_person(args: Dictionary) -> Dictionary:
	return await _exec_write("CREATE (:Person {name: $name, age: $age})", args)

func _update_person(args: Dictionary) -> Dictionary:
	return await _exec_write("MATCH (p:Person {name: $name}) SET p.age = $age", args)

func _remove_person(args: Dictionary) -> Dictionary:
	return await _exec_write("MATCH (p:Person {name: $name}) DELETE p", {"name": args.name})

func _exec_write(query: String, params: Dictionary) -> Dictionary:
	LadybugBridge.write_query(query, params, func(_res, err: String):
		write_finished.emit(err)
	)
	var err: String = await write_finished
	return {"status": "ok"} if err.is_empty() else {"error": err}
