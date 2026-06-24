class_name ExampleSchema
extends LadybugSchema

func _init() -> void:
	version = 1
	setup_queries = [
		"CREATE NODE TABLE IF NOT EXISTS Person(name STRING PRIMARY KEY, age INT64)",
		"MERGE (:Person {name: 'Alice'}) ON CREATE SET Person.age = 30",
		"MERGE (:Person {name: 'Bob'}) ON CREATE SET Person.age = 25"
	]
