#include "flattener.h"
#include <vector>
#include <algorithm>

void Flattener::_bind_methods() {
	ClassDB::bind_method(D_METHOD("process", "id", "operation", "incoming_delta_string", "existing_db_json", "schema_keys", "delimiter"), &Flattener::process);
	ClassDB::bind_method(D_METHOD("format_crdt_delta", "delta_string"), &Flattener::format_crdt_delta);
}

Flattener::Flattener() {
	_glaze = memnew(Glaze);
}

Flattener::~Flattener() {
	if (_glaze) {
		memdelete(_glaze);
	}
}

void Flattener::smart_merge(glz::generic& target, const glz::generic& source) {
	if (source.is_null()) { target = source; return; }

	if (target.is_array() && source.is_object()) {
		auto& arr = target.get_array();
		for (auto& [s_key, s_val] : source.get_object()) {
			if (s_val.is_boolean() && s_val.get_boolean()) {
				bool found = false;
				for (auto& item : arr) { if (item.is_string() && item.get_string() == s_key) { found = true; break; } }
				if (!found) arr.push_back(s_key);
			} else if (s_val.is_null()) {
				arr.erase(std::remove_if(arr.begin(), arr.end(), [&](const glz::generic& item) { return item.is_string() && item.get_string() == s_key; }), arr.end());
			}
		}
		return;
	}

	if (source.is_array()) { target = source; return; }

	if (target.is_object() && source.is_object()) {
		auto& t_obj = target.get_object();
		for (auto& [s_key, s_val] : source.get_object()) {
			if (s_val.is_null()) { t_obj.erase(s_key); }
			else {
				if (t_obj.contains(s_key)) smart_merge(t_obj[s_key], s_val);
				else t_obj[s_key] = s_val;
			}
		}
		return;
	}
	target = source;
}

glz::generic Flattener::expand_dot_notation(const glz::generic& source) {
	if (!source.is_object()) return source;
	glz::generic out = glz::generic::object_t{};

	for (auto& [key, val] : source.get_object()) {
		glz::generic expanded_val = expand_dot_notation(val);
		size_t dot_pos = key.find('.');
		
		if (dot_pos != std::string::npos) {
			std::vector<std::string> parts;
			size_t start = 0, end;
			while ((end = key.find('.', start)) != std::string::npos) { parts.push_back(key.substr(start, end - start)); start = end + 1; }
			parts.push_back(key.substr(start));

			glz::generic* current = &out;
			for (size_t i = 0; i < parts.size() - 1; ++i) {
				auto& obj = current->get_object();
				if (!obj.contains(parts[i]) || !obj[parts[i]].is_object()) obj[parts[i]] = glz::generic::object_t{};
				current = &obj[parts[i]];
			}
			auto& current_obj = current->get_object();
			if (current_obj.contains(parts.back()) && current_obj[parts.back()].is_object() && expanded_val.is_object()) smart_merge(current_obj[parts.back()], expanded_val);
			else current_obj[parts.back()] = expanded_val;
		} else {
			auto& out_obj = out.get_object();
			if (out_obj.contains(key) && out_obj[key].is_object() && expanded_val.is_object()) smart_merge(out_obj[key], expanded_val);
			else out_obj[key] = expanded_val;
		}
	}
	return out;
}

void Flattener::flatten_object(const glz::generic& obj, const String& prefix, const String& delimiter, const Array& schema_keys, Dictionary& safe_flattened) {
	if (!obj.is_object()) return;
	
	for (auto& [key, val] : obj.get_object()) {
		if (key == "_" || key == "@type" || key == "id") continue;
		
		String g_key(key.c_str());
		String safe_key = g_key.replace("/", delimiter);
		String new_key = prefix.is_empty() ? safe_key : prefix + delimiter + safe_key;
		
		if (val.is_object()) {
			if (schema_keys.has(new_key)) {
				std::string str_val;
				(void)glz::write_json(val, str_val);
				safe_flattened[new_key] = String(str_val.c_str());
			} else {
				flatten_object(val, new_key, delimiter, schema_keys, safe_flattened);
			}
		} else if (schema_keys.has(new_key)) {
			if (val.is_array()) {
				std::string str_val;
				(void)glz::write_json(val, str_val);
				safe_flattened[new_key] = String(str_val.c_str());
			} else if (val.is_string()) {
				safe_flattened[new_key] = String(val.get_string().c_str());
			} else if (val.is_number()) {
				safe_flattened[new_key] = val.get_number();
			} else if (val.is_boolean()) {
				safe_flattened[new_key] = val.get_boolean();
			} else if (val.is_null()) {
				safe_flattened[new_key] = Variant();
			}
		}
	}
}

Dictionary Flattener::process(const String& id, const String& operation, const String& incoming_delta_str, const String& existing_db_json, const Array& schema_keys, const String& delimiter) {
	Dictionary result;
	glz::generic incoming_doc;
	glz::generic existing_doc = glz::generic::object_t{};
	
	if (glz::read_json(incoming_doc, incoming_delta_str.utf8().get_data())) {
		UtilityFunctions::push_error("Glaze parse error on incoming packet.");
		return result;
	}

	glz::generic expanded_delta = expand_dot_notation(incoming_doc);
	glz::generic final_body = expanded_delta;

	if (operation == "UPDATE" && !existing_db_json.is_empty()) {
		if (!glz::read_json(existing_doc, existing_db_json.utf8().get_data())) {
			smart_merge(existing_doc, expanded_delta);
			final_body = existing_doc;
		}
	}

	Dictionary flattened;
	flattened["id"] = id;
	flatten_object(final_body, "", delimiter, schema_keys, flattened);
	
	std::string final_json_str;
	(void)glz::write_json(final_body, final_json_str);
	flattened["data"] = String(final_json_str.c_str());

	// Utilize your existing Glaze wrapper class to handle the memory-efficient Variant extraction
	Dictionary gd_final_body;
	Variant p = _glaze->from_string(String(final_json_str.c_str()));
	if (p.get_type() == Variant::DICTIONARY) {
		gd_final_body = p;
	}

	result["flattened"] = flattened;
	result["expanded_body"] = gd_final_body;
	result["raw_data_string"] = String(final_json_str.c_str());
	
	return result;
}

glz::generic format_crdt(const glz::generic& obj) {
	if (!obj.is_object()) {
		if (obj.is_array()) {
			auto& arr = obj.get_array();
			if (arr.empty()) return glz::generic(glz::generic::null_t{});
			glz::generic out = glz::generic::object_t{};
			auto& out_obj = out.get_object();
			for (auto& val : arr) {
				if (!val.is_null() && val.is_string()) out_obj[val.get_string()] = true;
			}
			return out;
		}
		return obj;
	}
	
	glz::generic out = glz::generic::object_t{};
	auto& out_obj = out.get_object();
	bool has_keys = false;
	
	for (auto& [k, v] : obj.get_object()) {
		glz::generic crdt_val = format_crdt(v);
		if (!crdt_val.is_null()) {
			out_obj[k] = crdt_val;
			has_keys = true;
		}
	}
	return has_keys ? out : glz::generic(glz::generic::null_t{});
}

String Flattener::format_crdt_delta(const String& delta_string) {
	glz::generic doc;
	if (glz::read_json(doc, delta_string.utf8().get_data())) return "";
	glz::generic expanded = expand_dot_notation(doc);
	glz::generic formatted = format_crdt(expanded);
	std::string out;
	(void)glz::write_json(formatted, out);
	return String(out.c_str());
}