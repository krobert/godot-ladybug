#ifndef RAPID_JSON_H
#define RAPID_JSON_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class RapidJSON : public RefCounted {
	GDCLASS(RapidJSON, RefCounted)

protected:
	static void _bind_methods();

public:
	RapidJSON();
	~RapidJSON();

	Variant from_string(const String &json_str);
	String to_string(const Variant &data, bool pretty);
	
	Dictionary validate(const String &json_str);
	Dictionary validate_schema(const String &json_str, const String &schema_str);
	bool is_valid_json(const String &json_str);
	String minify_json(const String &json_str);
	
	Variant get_at_pointer(const String &json_str, const String &pointer);
	Dictionary generate_default_from_schema(const String &schema_str);
};

} // namespace godot

#endif // RAPID_JSON_H