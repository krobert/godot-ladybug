class_name ExampleSchema
extends LadybugSchema

func _init() -> void:
	version = 1
	setup_queries = [
		"CREATE NODE TABLE Person(name STRING PRIMARY KEY, age INT64)",
		"CREATE (:Person {name: 'Alice', age: 30})",
		"CREATE (:Person {name: 'Bob', age: 25})"
	]
