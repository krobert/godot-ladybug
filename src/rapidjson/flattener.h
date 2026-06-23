#ifndef JSON_FLATTENER_H
#define JSON_FLATTENER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <rapidjson/document.h>
#include "rapid_json.h"

using namespace godot;

class Flattener : public RefCounted {
    GDCLASS(Flattener, RefCounted)

private:
    RapidJSON* _rapidjson;

    void smart_merge(rapidjson::Value& target, const rapidjson::Value& source, rapidjson::Document::AllocatorType& allocator);
    rapidjson::Value expand_dot_notation(const rapidjson::Value& source, rapidjson::Document::AllocatorType& allocator);
    void flatten_object(const rapidjson::Value& obj, const String& prefix, const String& delimiter, const Array& schema_keys, Dictionary& safe_flattened);
    rapidjson::Value format_crdt(const rapidjson::Value& obj, rapidjson::Document::AllocatorType& allocator);

protected:
    static void _bind_methods();

public:
    Flattener();
    ~Flattener();

    Dictionary process(const String& id, const String& operation, const String& incoming_delta_str, const String& existing_db_json, const Array& schema_keys, const String& delimiter);
    String format_crdt_delta(const String& delta_string);
};

#endif // JSON_FLATTENER_H