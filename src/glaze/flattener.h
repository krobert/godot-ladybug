#ifndef GLAZE_FLATTENER_H
#define GLAZE_FLATTENER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <glaze/glaze.hpp>
#include "glaze.h"

using namespace godot;

class Flattener : public RefCounted {
	GDCLASS(Flattener, RefCounted)

private:
	Glaze* _glaze;

	void smart_merge(glz::generic& target, const glz::generic& source);
	glz::generic expand_dot_notation(const glz::generic& source);
	void flatten_object(const glz::generic& obj, const String& prefix, const String& delimiter, const Array& schema_keys, Dictionary& safe_flattened);

protected:
	static void _bind_methods();

public:
	Flattener();
	~Flattener();

	Dictionary process(const String& id, const String& operation, const String& incoming_delta_str, const String& existing_db_json, const Array& schema_keys, const String& delimiter);
	String format_crdt_delta(const String& delta_string);
};

#endif // GLAZE_FLATTENER_H