#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace godot {

class Glaze : public RefCounted {
	GDCLASS(Glaze, RefCounted)

protected:
	static void _bind_methods();

public:
	Glaze();
	~Glaze();

	Variant from_string(const String &json_str);
	String to_string(const Variant &data, bool pretty = false);
	
	Dictionary validate(const String &json_str);
	bool is_valid_json(const String &json_str);
	String minify_json(const String &json_str);
	
	// Extracts a specific value bypassing full Dictionary allocation
	Variant get_at_pointer(const String &json_str, const String &pointer);
};

} // namespace godot