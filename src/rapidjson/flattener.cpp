#include "flattener.h"
#include <rapidjson/writer.h>
#include <rapidjson/stringbuffer.h>
#include <vector>
#include <string>

void Flattener::_bind_methods() {
    ClassDB::bind_method(D_METHOD("process", "id", "operation", "incoming_delta_string", "existing_db_json", "schema_keys", "delimiter"), &Flattener::process);
    ClassDB::bind_method(D_METHOD("format_crdt_delta", "delta_string"), &Flattener::format_crdt_delta);
}

Flattener::Flattener() {
    _rapidjson = memnew(RapidJSON);
}

Flattener::~Flattener() {
    if (_rapidjson) {
        memdelete(_rapidjson);
    }
}

void Flattener::smart_merge(rapidjson::Value& target, const rapidjson::Value& source, rapidjson::Document::AllocatorType& allocator) {
    if (source.IsNull()) { 
        target.SetNull(); 
        return; 
    }

    if (target.IsArray() && source.IsObject()) {
        for (auto& m : source.GetObject()) {
            std::string s_key(m.name.GetString(), m.name.GetStringLength());
            if (m.value.IsBool() && m.value.GetBool()) {
                bool found = false;
                for (auto& item : target.GetArray()) {
                    if (item.IsString() && std::string(item.GetString(), item.GetStringLength()) == s_key) {
                        found = true; 
                        break; 
                    }
                }
                if (!found) {
                    rapidjson::Value new_item;
                    new_item.SetString(m.name.GetString(), m.name.GetStringLength(), allocator);
                    target.PushBack(new_item, allocator);
                }
            } else if (m.value.IsNull()) {
                for (auto it = target.Begin(); it != target.End();) {
                    if (it->IsString() && std::string(it->GetString(), it->GetStringLength()) == s_key) {
                        it = target.Erase(it);
                    } else {
                        ++it;
                    }
                }
            }
        }
        return;
    }

    if (source.IsArray()) { 
        target.CopyFrom(source, allocator); 
        return; 
    }

    if (target.IsObject() && source.IsObject()) {
        for (auto& m : source.GetObject()) {
            if (m.value.IsNull()) { 
                target.RemoveMember(m.name); 
            } else {
                if (target.HasMember(m.name)) {
                    smart_merge(target[m.name], m.value, allocator);
                } else {
                    rapidjson::Value n;
                    n.SetString(m.name.GetString(), m.name.GetStringLength(), allocator);
                    rapidjson::Value v;
                    v.CopyFrom(m.value, allocator);
                    target.AddMember(n, v, allocator);
                }
            }
        }
        return;
    }
    target.CopyFrom(source, allocator);
}

rapidjson::Value Flattener::expand_dot_notation(const rapidjson::Value& source, rapidjson::Document::AllocatorType& allocator) {
    if (!source.IsObject()) {
        rapidjson::Value ret;
        ret.CopyFrom(source, allocator);
        return ret;
    }
    
    rapidjson::Value out(rapidjson::kObjectType);

    for (auto& m : source.GetObject()) {
        rapidjson::Value expanded_val = expand_dot_notation(m.value, allocator);
        std::string key(m.name.GetString(), m.name.GetStringLength());
        size_t dot_pos = key.find('.');
        
        if (dot_pos != std::string::npos) {
            std::vector<std::string> parts;
            size_t start = 0, end;
            while ((end = key.find('.', start)) != std::string::npos) { 
                parts.push_back(key.substr(start, end - start)); 
                start = end + 1; 
            }
            parts.push_back(key.substr(start));

            rapidjson::Value* current = &out;
            for (size_t i = 0; i < parts.size() - 1; ++i) {
                if (!current->HasMember(parts[i].c_str())) {
                    rapidjson::Value n(parts[i].c_str(), allocator);
                    rapidjson::Value o(rapidjson::kObjectType);
                    current->AddMember(n, o, allocator);
                }
                current = &((*current)[parts[i].c_str()]);
                if (!current->IsObject()) {
                    current->SetObject();
                }
            }
            
            const std::string& last_part = parts.back();
            if (current->HasMember(last_part.c_str()) && (*current)[last_part.c_str()].IsObject() && expanded_val.IsObject()) {
                smart_merge((*current)[last_part.c_str()], expanded_val, allocator);
            } else {
                if (current->HasMember(last_part.c_str())) {
                    current->RemoveMember(last_part.c_str());
                }
                rapidjson::Value n(last_part.c_str(), allocator);
                current->AddMember(n, expanded_val, allocator);
            }
        } else {
            if (out.HasMember(m.name) && out[m.name].IsObject() && expanded_val.IsObject()) {
                smart_merge(out[m.name], expanded_val, allocator);
            } else {
                if (out.HasMember(m.name)) {
                    out.RemoveMember(m.name);
                }
                rapidjson::Value n;
                n.SetString(m.name.GetString(), m.name.GetStringLength(), allocator);
                out.AddMember(n, expanded_val, allocator);
            }
        }
    }
    return out;
}

void Flattener::flatten_object(const rapidjson::Value& obj, const String& prefix, const String& delimiter, const Array& schema_keys, Dictionary& safe_flattened) {
    if (!obj.IsObject()) return;
    
    for (auto& m : obj.GetObject()) {
        std::string key_str(m.name.GetString(), m.name.GetStringLength());
        if (key_str == "_" || key_str == "@type" || key_str == "id") continue;
        
        String g_key = String::utf8(key_str.c_str());
        String safe_key = g_key.replace("/", delimiter);
        String new_key = prefix.is_empty() ? safe_key : prefix + delimiter + safe_key;
        
        if (m.value.IsObject()) {
            if (schema_keys.has(new_key)) {
                rapidjson::StringBuffer sb;
                rapidjson::Writer<rapidjson::StringBuffer> writer(sb);
                m.value.Accept(writer);
                safe_flattened[new_key] = String::utf8(sb.GetString());
            } else {
                flatten_object(m.value, new_key, delimiter, schema_keys, safe_flattened);
            }
        } else if (schema_keys.has(new_key)) {
            if (m.value.IsArray()) {
                rapidjson::StringBuffer sb;
                rapidjson::Writer<rapidjson::StringBuffer> writer(sb);
                m.value.Accept(writer);
                safe_flattened[new_key] = String::utf8(sb.GetString());
            } else if (m.value.IsString()) {
                safe_flattened[new_key] = String::utf8(m.value.GetString(), m.value.GetStringLength());
            } else if (m.value.IsNumber()) {
                if (m.value.IsInt64()) {
                    safe_flattened[new_key] = (int64_t)m.value.GetInt64();
                } else {
                    safe_flattened[new_key] = m.value.GetDouble();
                }
            } else if (m.value.IsBool()) {
                safe_flattened[new_key] = m.value.GetBool();
            } else if (m.value.IsNull()) {
                safe_flattened[new_key] = Variant();
            }
        }
    }
}

Dictionary Flattener::process(const String& id, const String& operation, const String& incoming_delta_str, const String& existing_db_json, const Array& schema_keys, const String& delimiter) {
    Dictionary result;
    rapidjson::Document incoming_doc;
    
    if (incoming_doc.Parse(incoming_delta_str.utf8().get_data()).HasParseError()) {
        UtilityFunctions::push_error("RapidJSON parse error on incoming packet.");
        return result;
    }

    rapidjson::Document::AllocatorType& allocator = incoming_doc.GetAllocator();
    rapidjson::Value expanded_delta = expand_dot_notation(incoming_doc, allocator);
    
    rapidjson::Value final_body;
    rapidjson::Document existing_doc;
    
    if (operation == "UPDATE" && !existing_db_json.is_empty()) {
        if (!existing_doc.Parse(existing_db_json.utf8().get_data()).HasParseError()) {
            smart_merge(existing_doc, expanded_delta, existing_doc.GetAllocator());
            final_body.CopyFrom(existing_doc, allocator);
        } else {
            final_body.CopyFrom(expanded_delta, allocator);
        }
    } else {
        final_body.CopyFrom(expanded_delta, allocator);
    }

    Dictionary flattened;
    flattened["id"] = id;
    flatten_object(final_body, "", delimiter, schema_keys, flattened);
    
    rapidjson::StringBuffer sb;
    rapidjson::Writer<rapidjson::StringBuffer> writer(sb);
    final_body.Accept(writer);
    String final_json_str = String::utf8(sb.GetString());
    flattened["data"] = final_json_str;

    Dictionary gd_final_body;
    Variant p = _rapidjson->from_string(final_json_str);
    if (p.get_type() == Variant::DICTIONARY) {
        gd_final_body = p;
    }

    result["flattened"] = flattened;
    result["expanded_body"] = gd_final_body;
    result["raw_data_string"] = final_json_str;
    
    return result;
}

rapidjson::Value Flattener::format_crdt(const rapidjson::Value& obj, rapidjson::Document::AllocatorType& allocator) {
    if (!obj.IsObject()) {
        if (obj.IsArray()) {
            if (obj.Empty()) {
                rapidjson::Value n;
                n.SetNull();
                return n;
            }
            rapidjson::Value out(rapidjson::kObjectType);
            for (auto& val : obj.GetArray()) {
                if (!val.IsNull() && val.IsString()) {
                    rapidjson::Value n;
                    n.SetString(val.GetString(), val.GetStringLength(), allocator);
                    rapidjson::Value b(true);
                    if (!out.HasMember(n)) {
                        out.AddMember(n, b, allocator);
                    }
                }
            }
            return out;
        }
        rapidjson::Value ret;
        ret.CopyFrom(obj, allocator);
        return ret;
    }
    
    rapidjson::Value out(rapidjson::kObjectType);
    bool has_keys = false;
    
    for (auto& m : obj.GetObject()) {
        rapidjson::Value crdt_val = format_crdt(m.value, allocator);
        if (!crdt_val.IsNull()) {
            rapidjson::Value n;
            n.SetString(m.name.GetString(), m.name.GetStringLength(), allocator);
            out.AddMember(n, crdt_val, allocator);
            has_keys = true;
        }
    }
    
    if (has_keys) {
        return out;
    } else {
        rapidjson::Value n;
        n.SetNull();
        return n;
    }
}

String Flattener::format_crdt_delta(const String& delta_string) {
    rapidjson::Document doc;
    if (doc.Parse(delta_string.utf8().get_data()).HasParseError()) return "";
    
    rapidjson::Document::AllocatorType& allocator = doc.GetAllocator();
    rapidjson::Value expanded = expand_dot_notation(doc, allocator);
    rapidjson::Value formatted = format_crdt(expanded, allocator);
    
    rapidjson::StringBuffer sb;
    rapidjson::Writer<rapidjson::StringBuffer> writer(sb);
    formatted.Accept(writer);
    return String::utf8(sb.GetString());
}