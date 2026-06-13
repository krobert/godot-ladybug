extends Node

@export var schema: LadybugSchema = ExampleSchema.new()

func _ready():
	LadybugBridge.set_log_level(LadybugBridge.LogLevel.ALL)
	LadybugBridge.database_ready.connect(_on_db_ready)
	await LadybugBridge.init_db(schema, "people.lbdb")
	
func _on_db_ready():
	print("db_ready")
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
	LadybugBridge.close_db()
