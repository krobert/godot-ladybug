#include "glaze.h"
#include <glaze/glaze.hpp>
#include <sstream>

using namespace godot;

// --- Internal Conversion Helpers ---

static Variant glaze_to_variant(const glz::generic& val) {
	if (val.is_null()) return Variant();
	if (val.is_boolean()) return Variant(val.get_boolean());
	if (val.is_number()) return Variant(val.get_number());
	if (val.is_string()) return Variant(String(val.get_string().c_str()));
	
	if (val.is_array()) {
		Array arr;
		for (const auto& item : val.get_array()) {
			arr.push_back(glaze_to_variant(item));
		}
		return arr;
	}
	
	if (val.is_object()) {
		Dictionary dict;
		for (const auto& [k, v] : val.get_object()) {
			dict[String(k.c_str())] = glaze_to_variant(v);
		}
		return dict;
	}
	return Variant();
}

static glz::generic variant_to_glaze(const Variant& v) {
	switch (v.get_type()) {
		case Variant::NIL: return glz::generic();
		case Variant::BOOL: return glz::generic((bool)v);
		case Variant::INT: return glz::generic((double)(int64_t)v);
		case Variant::FLOAT: return glz::generic((double)v);
		case Variant::STRING: return glz::generic(((String)v).utf8().get_data());
		
		case Variant::ARRAY: {
			glz::generic::array_t arr;
			Array varr = v;
			for (int i = 0; i < varr.size(); ++i) {
				arr.push_back(variant_to_glaze(varr[i]));
			}
			return glz::generic(arr);
		}
		
		case Variant::DICTIONARY: {
			glz::generic::object_t obj;
			Dictionary vdict = v;
			Array keys = vdict.keys();
			for (int i = 0; i < keys.size(); ++i) {
				String k = keys[i];
				obj[k.utf8().get_data()] = variant_to_glaze(vdict[k]);
			}
			return glz::generic(obj);
		}
		
		default: return glz::generic();
	}
}

// --- Bindings ---

void Glaze::_bind_methods() {
	ClassDB::bind_method(D_METHOD("from_string", "json_str"), &Glaze::from_string);
	ClassDB::bind_method(D_METHOD("to_string", "data", "pretty"), &Glaze::to_string, DEFVAL(false));
	
	ClassDB::bind_method(D_METHOD("validate", "json_str"), &Glaze::validate);
	ClassDB::bind_method(D_METHOD("is_valid_json", "json_str"), &Glaze::is_valid_json);
	ClassDB::bind_method(D_METHOD("minify_json", "json_str"), &Glaze::minify_json);
	
	ClassDB::bind_method(D_METHOD("get_at_pointer", "json_str", "pointer"), &Glaze::get_at_pointer);
}

Glaze::Glaze() {}
Glaze::~Glaze() {}

Variant Glaze::from_string(const String &json_str) {
	glz::generic root;
	CharString utf8 = json_str.utf8();
	auto ec = glz::read_json(root, utf8.get_data());
	
	if (ec) {
		ERR_PRINT(String("Glaze parse error: ") + glz::format_error(ec, utf8.get_data()).c_str());
		return Variant();
	}
	return glaze_to_variant(root);
}

String Glaze::to_string(const Variant &data, bool pretty) {
	glz::generic root = variant_to_glaze(data);
	std::string out;
	
	if (pretty) {
		(void)glz::write<glz::opts{.prettify = true}>(root, out);
	} else {
		(void)glz::write_json(root, out);
	}
	
	return String(out.c_str());
}

Dictionary Glaze::validate(const String &json_str) {
	Dictionary result;
	glz::generic root;
	CharString utf8 = json_str.utf8();
	
	auto ec = glz::read_json(root, utf8.get_data());
	if (ec) {
		result["valid"] = false;
		result["error"] = String(glz::format_error(ec, utf8.get_data()).c_str());
	} else {
		result["valid"] = true;
		result["error"] = "";
	}
	return result;
}

bool Glaze::is_valid_json(const String &json_str) {
	CharString utf8 = json_str.utf8();
	return !glz::validate_json(utf8.get_data());
}

String Glaze::minify_json(const String &json_str) {
	CharString utf8 = json_str.utf8();
	std::string in_str = utf8.get_data();
	std::string minified;
	
	glz::minify_json(in_str, minified);
	
	return String(minified.c_str());
}

Variant Glaze::get_at_pointer(const String &json_str, const String &pointer) {
	glz::generic root;
	CharString utf8 = json_str.utf8();
	
	auto ec = glz::read_json(root, utf8.get_data());
	if (ec) return Variant();

	CharString ptr_utf8 = pointer.utf8();
	std::string ptr_str = ptr_utf8.get_data();
	
	// Basic JSON pointer traversal (e.g., "/payload/users/0/name")
	glz::generic* current = &root;
	std::stringstream ss(ptr_str);
	std::string token;
	
	while (std::getline(ss, token, '/')) {
		if (token.empty()) continue; // Skip leading slash
		
		if (current->is_object()) {
			auto& obj = current->get_object();
			if (obj.find(token) != obj.end()) {
				current = &obj[token];
			} else {
				return Variant();
			}
		} else if (current->is_array()) {
			int index = std::stoi(token);
			auto& arr = current->get_array();
			if (index >= 0 && index < arr.size()) {
				current = &arr[index];
			} else {
				return Variant();
			}
		} else {
			return Variant();
		}
	}

	return glaze_to_variant(*current);
}