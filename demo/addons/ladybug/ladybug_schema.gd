class_name LadybugSchema
extends Resource

@export var version: int = 1
@export_multiline var setup_queries: Array[String] = []
@export var edge_rules: Dictionary = {}

func _init(p_ver: int = 1, p_queries: Array[String] = [], p_edge_rules: Dictionary = {}) -> void:
	version = p_ver
	setup_queries = p_queries
	edge_rules = p_edge_rules

## Generic flat-dict to Graph Cypher compiler
func build_queries(node_label: String, flat_dict: Dictionary, raw_data: String) -> Array:
	var queries: Array = []
	var node_id = flat_dict["id"]
	var p_label = node_label.capitalize()
	
	# 1. Base Node Update (SET clauses)
	var set_clauses: PackedStringArray = PackedStringArray()
	var params: Dictionary = {"id": node_id, "data": raw_data}
	
	for key in flat_dict:
		if key == "id": 
			continue
		set_clauses.append("n.%s = $%s" % [key, key])
		params[key] = flat_dict[key]
		
	var cypher = "MERGE (n:%s {id: $id})" % p_label
	if set_clauses.size() > 0:
		cypher += " SET " + ", ".join(set_clauses)
	cypher += " SET n.data = $data"
	queries.append({"cypher": cypher, "params": params})
	
	# 2. Configured Edge Updates
	for key in flat_dict:
		var target_val = flat_dict[key]
		if target_val == null:
			continue
			
		if edge_rules.has(key):
			var rule = edge_rules[key]
			
			# Wipe existing edges for this relation
			queries.append({
				"cypher": "MATCH (n:%s {id: $id})-[r:%s]->() DELETE r" % [p_label, rule.rel],
				"params": {"id": node_id}
			})
			
			var is_array = rule.get("is_array", false)
			var targets = _parse_array(target_val) if is_array else [target_val]
			
			for t_val in targets:
				queries.append({
					"cypher": "MERGE (t:%s {id: $target}) WITH t MATCH (n:%s {id: $id}) MERGE (n)-[:%s]->(t)" % [rule.label, p_label, rule.rel],
					"params": {"id": node_id, "target": str(t_val).strip_edges()}
				})
				
	return queries

func _parse_array(val: Variant) -> Array:
	if typeof(val) == TYPE_ARRAY:
		return val
	if typeof(val) == TYPE_STRING:
		var parsed = JSON.parse_string(val)
		if typeof(parsed) == TYPE_ARRAY:
			return parsed
	return []