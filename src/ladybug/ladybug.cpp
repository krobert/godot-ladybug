#include "ladybug.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cstring>
#include <vector>

namespace godot {

void Ladybug::_bind_methods() {
    ClassDB::bind_method(D_METHOD("open", "path"), &Ladybug::open);
    ClassDB::bind_method(D_METHOD("is_open"), &Ladybug::is_open);
    ClassDB::bind_method(D_METHOD("query", "cypher"), &Ladybug::query);
    ClassDB::bind_method(D_METHOD("prepare", "name", "cypher"), &Ladybug::prepare);
    ClassDB::bind_method(D_METHOD("execute_prepared", "name", "params"), &Ladybug::execute_prepared);
    ClassDB::bind_method(D_METHOD("close"), &Ladybug::close);
}

Ladybug::Ladybug() {
    _db = {};
    _conn = {};
}

Ladybug::~Ladybug() {
    close();
}

void Ladybug::_log_error() {
    char* err = lbug_get_last_error();
    if (err) {
        UtilityFunctions::printerr("Ladybug error: ", err);
        lbug_destroy_string(err);
    }
}

Error Ladybug::open(const String &path) {
    close();
    lbug_system_config config = lbug_default_system_config();
    std::string p = path.utf8().get_data();

    if (lbug_database_init(p.c_str(), config, &_db) != LbugSuccess) {
        _log_error();
        _db = {};
        return FAILED;
    }

    if (lbug_connection_init(&_db, &_conn) != LbugSuccess) {
        _log_error();
        lbug_database_destroy(&_db);
        _db = {};
        return FAILED;
    }
    return OK;
}

bool Ladybug::is_open() const {
    return _db._database != nullptr && _conn._connection != nullptr;
}

// ---------- value conversion helpers ----------
static Variant value_to_variant(lbug_value* val) {
    if (lbug_value_is_null(val)) return Variant();
    lbug_logical_type type;
    lbug_value_get_data_type(val, &type);
    lbug_data_type_id id = lbug_data_type_get_id(&type);
    lbug_data_type_destroy(&type);

    switch (id) {
        case LBUG_BOOL: { bool b; lbug_value_get_bool(val, &b); return b; }
        case LBUG_INT64: { int64_t i; lbug_value_get_int64(val, &i); return i; }
        case LBUG_INT32: { int32_t i; lbug_value_get_int32(val, &i); return i; }
        case LBUG_DOUBLE: { double d; lbug_value_get_double(val, &d); return d; }
        case LBUG_STRING: {
            char* s = nullptr;
            lbug_value_get_string(val, &s);
            String ret;
            if (s) {
                ret = String::utf8(s);
                if (ret.is_empty() && s[0] != '\0') {
                    ret = String(s); 
                }
                lbug_destroy_string(s);
            }
            return ret;
        }
        case LBUG_NODE: {
            Dictionary dict;
            uint64_t prop_count = 0;
            if (lbug_node_val_get_property_size(val, &prop_count) == LbugSuccess) {
                for (uint64_t i = 0; i < prop_count; i++) {
                    char* prop_name = nullptr;
                    if (lbug_node_val_get_property_name_at(val, i, &prop_name) == LbugSuccess) {
                        lbug_value prop_val;
                        if (lbug_node_val_get_property_value_at(val, i, &prop_val) == LbugSuccess) {
                            // Recursively parse the property (handles nested lists/strings correctly)
                            dict[String::utf8(prop_name)] = value_to_variant(&prop_val);
                            lbug_value_destroy(&prop_val);
                        }
                        lbug_destroy_string(prop_name);
                    }
                }
            }
            return dict;
        }
        case LBUG_REL: {
            Dictionary dict;
            uint64_t prop_count = 0;
            if (lbug_rel_val_get_property_size(val, &prop_count) == LbugSuccess) {
                for (uint64_t i = 0; i < prop_count; i++) {
                    char* prop_name = nullptr;
                    if (lbug_rel_val_get_property_name_at(val, i, &prop_name) == LbugSuccess) {
                        lbug_value prop_val;
                        if (lbug_rel_val_get_property_value_at(val, i, &prop_val) == LbugSuccess) {
                            dict[String::utf8(prop_name)] = value_to_variant(&prop_val);
                            lbug_value_destroy(&prop_val);
                        }
                        lbug_destroy_string(prop_name);
                    }
                }
            }
            return dict;
        }
        case LBUG_LIST:
        case LBUG_ARRAY: {
            Array arr;
            uint64_t size = 0;
            if (lbug_value_get_list_size(val, &size) == LbugSuccess) {
                for (uint64_t i = 0; i < size; i++) {
                    lbug_value elem_val;
                    if (lbug_value_get_list_element(val, i, &elem_val) == LbugSuccess) {
                        // Recursively parse the element
                        arr.append(value_to_variant(&elem_val));
                        lbug_value_destroy(&elem_val);
                    }
                }
            }
            return arr;
        }
        default: {
            char* s = lbug_value_to_string(val);
            String ret;
            if (s) {
                ret = String::utf8(s);
                if (ret.is_empty() && s[0] != '\0') {
                    ret = String(s);
                }
                lbug_destroy_string(s);
            }
            return ret;
        }
    }
}

// ---------- query ----------
Array Ladybug::query(const String &cypher) {
    Array out;
    ERR_FAIL_COND_V(!is_open(), out);

    lbug_query_result qr;
    if (lbug_connection_query(&_conn, cypher.utf8().get_data(), &qr) != LbugSuccess) {
        _log_error();
        return out;
    }

    if (!lbug_query_result_is_success(&qr)) {
        char* msg = lbug_query_result_get_error_message(&qr);
        if (msg) {
            UtilityFunctions::printerr("Query error: ", msg);
            lbug_destroy_string(msg);
        } else {
            _log_error();
        }
        lbug_query_result_destroy(&qr);
        return out;
    }

    uint64_t num_cols = lbug_query_result_get_num_columns(&qr);
    std::vector<String> col_names;
    for (uint64_t i = 0; i < num_cols; i++) {
        char* name = nullptr;
        lbug_query_result_get_column_name(&qr, i, &name);
        col_names.push_back(String::utf8(name));
        lbug_destroy_string(name);
    }

    while (lbug_query_result_has_next(&qr)) {
        lbug_flat_tuple row;
        if (lbug_query_result_get_next(&qr, &row) != LbugSuccess) continue;
        Dictionary dict;
        for (uint64_t i = 0; i < num_cols; i++) {
            lbug_value val;
            if (lbug_flat_tuple_get_value(&row, i, &val) == LbugSuccess) {
                dict[col_names[i]] = value_to_variant(&val);
                lbug_value_destroy(&val);
            }
        }
        out.append(dict);
    }
    lbug_query_result_destroy(&qr);
    return out;
}

// ---------- prepared statements ----------
static lbug_state bind_param(lbug_prepared_statement* stmt, const char* name, const Variant& value) {
    switch (value.get_type()) {
        case Variant::NIL: return LbugSuccess;
        case Variant::BOOL: return lbug_prepared_statement_bind_bool(stmt, name, static_cast<bool>(value));
        case Variant::INT:  return lbug_prepared_statement_bind_int64(stmt, name, static_cast<int64_t>(int(value)));
        case Variant::FLOAT: return lbug_prepared_statement_bind_double(stmt, name, static_cast<double>(value));
        case Variant::STRING: {
            std::string s = String(value).utf8().get_data();
            return lbug_prepared_statement_bind_string(stmt, name, s.c_str());
        }
        default: {
            std::string s = String(value).utf8().get_data();
            return lbug_prepared_statement_bind_string(stmt, name, s.c_str());
        }
    }
}

Error Ladybug::prepare(const String &name, const String &cypher) {
    ERR_FAIL_COND_V(!is_open(), FAILED);
    lbug_prepared_statement stmt;
    if (lbug_connection_prepare(&_conn, cypher.utf8().get_data(), &stmt) != LbugSuccess) {
        _log_error();
        return FAILED;
    }
    if (!lbug_prepared_statement_is_success(&stmt)) {
        char* msg = lbug_prepared_statement_get_error_message(&stmt);
        if (msg) {
            UtilityFunctions::printerr("Prepare error: ", msg);
            lbug_destroy_string(msg);
        } else {
            _log_error();
        }
        lbug_prepared_statement_destroy(&stmt);
        return FAILED;
    }
    std::string key = name.utf8().get_data();
    // if a statement with this name already exists, destroy it
    if (_stmts.find(key) != _stmts.end()) {
        lbug_prepared_statement_destroy(&_stmts[key]);
    }
    _stmts[key] = stmt;
    return OK;
}

Array Ladybug::execute_prepared(const String &name, const Dictionary &params) {
    Array out;
    std::string key = name.utf8().get_data();
    auto it = _stmts.find(key);
    ERR_FAIL_COND_V(it == _stmts.end(), out);
    lbug_prepared_statement* stmt = &it->second;

    // Bind parameters
    Array keys = params.keys();
    for (int i = 0; i < keys.size(); i++) {
        String k = keys[i];
        std::string pname = k.utf8().get_data();
        if (bind_param(stmt, pname.c_str(), params[k]) != LbugSuccess) {
            UtilityFunctions::printerr("Failed to bind parameter: ", k);
            return out;
        }
    }

    lbug_query_result qr;
    if (lbug_connection_execute(&_conn, stmt, &qr) != LbugSuccess) {
        _log_error();
        return out;
    }

    if (!lbug_query_result_is_success(&qr)) {
        char* msg = lbug_query_result_get_error_message(&qr);
        if (msg) {
            UtilityFunctions::printerr("Execute error: ", msg);
            lbug_destroy_string(msg);
        } else {
            _log_error();
        }
        lbug_query_result_destroy(&qr);
        return out;
    }

    uint64_t num_cols = lbug_query_result_get_num_columns(&qr);
    std::vector<String> col_names;
    for (uint64_t i = 0; i < num_cols; i++) {
        char* name = nullptr;
        lbug_query_result_get_column_name(&qr, i, &name);
        col_names.push_back(name);
        lbug_destroy_string(name);
    }

    while (lbug_query_result_has_next(&qr)) {
        lbug_flat_tuple row;
        if (lbug_query_result_get_next(&qr, &row) != LbugSuccess) continue;
        Dictionary dict;
        for (uint64_t i = 0; i < num_cols; i++) {
            lbug_value val;
            if (lbug_flat_tuple_get_value(&row, i, &val) == LbugSuccess) {
                dict[col_names[i]] = value_to_variant(&val);
                lbug_value_destroy(&val);
            }
        }
        out.append(dict);
    }
    lbug_query_result_destroy(&qr);
    return out;
}

void Ladybug::close() {
    if (_conn._connection != nullptr) {
        lbug_connection_destroy(&_conn);
        _conn = {};
    }
    if (_db._database != nullptr) {
        lbug_database_destroy(&_db);
        _db = {};
    }
    for (auto& pair : _stmts) {
        lbug_prepared_statement_destroy(&pair.second);
    }
    _stmts.clear();
}

} // namespace godot