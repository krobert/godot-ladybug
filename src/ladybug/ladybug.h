#ifndef LADYBUG_H
#define LADYBUG_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <unordered_map>
#include <string>

#include "lbug.h"

namespace godot {

class Ladybug : public RefCounted {
    GDCLASS(Ladybug, RefCounted)

    lbug_database _db;
    lbug_connection _conn;
    std::unordered_map<std::string, lbug_prepared_statement> _stmts;

    static void _log_error();

protected:
    static void _bind_methods();

public:
    Ladybug();
    ~Ladybug();

    Error open(const String &path);
    bool is_open() const;
    Array query(const String &cypher);
    Error prepare(const String &name, const String &cypher);
    Array execute_prepared(const String &name, const Dictionary &params);
    String last_error() const;
    void close();

};

}

#endif