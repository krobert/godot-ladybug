class_name LadybugSchema
extends Resource

@export var version: int = 1
@export_multiline var setup_queries: Array[String] = []

func _init(p_ver: int, p_queries: Array[String]) -> void:
	version = p_ver
	setup_queries = p_queries
