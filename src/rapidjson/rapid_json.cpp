#include "rapid_json.h"

#include <rapidjson/document.h>
#include <rapidjson/writer.h>
#include <rapidjson/prettywriter.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/schema.h>
#include <rapidjson/pointer.h>
#include <rapidjson/error/en.h>
#include <rapidjson/reader.h>

using namespace godot;

// --- Internal Conversion Helpers ---

static Variant rapidjson_to_variant(const rapidjson::Value& val) {
	if (val.IsNull()) return Variant();
	if (val.IsBool()) return Variant(val.GetBool());
	if (val.IsInt()) return Variant((int64_t)val.GetInt());
	if (val.IsInt64()) return Variant((int64_t)val.GetInt64());
	if (val.IsUint()) return Variant((int64_t)val.GetUint());
	if (val.IsUint64()) return Variant((int64_t)val.GetUint64());
	if (val.IsDouble()) return Variant(val.GetDouble());
	if (val.IsString()) return Variant(String::utf8(val.GetString(), val.GetStringLength()));
	
	if (val.IsArray()) {
		Array arr;
		for (rapidjson::SizeType i = 0; i < val.Size(); i++) {
			arr.push_back(rapidjson_to_variant(val[i]));
		}
		return arr;
	}
	
	if (val.IsObject()) {
		Dictionary dict;
		for (auto itr = val.MemberBegin(); itr != val.MemberEnd(); ++itr) {
			dict[String::utf8(itr->name.GetString(), itr->name.GetStringLength())] = rapidjson_to_variant(itr->value);
		}
		return dict;
	}
	return Variant();
}

static void variant_to_rapidjson(const Variant& v, rapidjson::Value& out_val, rapidjson::Document::AllocatorType& allocator) {
	switch (v.get_type()) {
		case Variant::NIL: out_val.SetNull(); break;
		case Variant::BOOL: out_val.SetBool((bool)v); break;
		case Variant::INT: out_val.SetInt64((int64_t)v); break;
		case Variant::FLOAT: out_val.SetDouble((double)v); break;
		case Variant::STRING: {
			String s = v;
			CharString utf8 = s.utf8();
			out_val.SetString(utf8.get_data(), utf8.length(), allocator);
			break;
		}
		case Variant::ARRAY: {
			out_val.SetArray();
			Array varr = v;
			for (int i = 0; i < varr.size(); ++i) {
				rapidjson::Value item;
				variant_to_rapidjson(varr[i], item, allocator);
				out_val.PushBack(item, allocator);
			}
			break;
		}
		case Variant::DICTIONARY: {
			out_val.SetObject();
			Dictionary vdict = v;
			Array keys = vdict.keys();
			for (int i = 0; i < keys.size(); ++i) {
				String k = keys[i];
				CharString k_utf8 = k.utf8();
				rapidjson::Value key_str(k_utf8.get_data(), k_utf8.length(), allocator);
				
				rapidjson::Value val;
				variant_to_rapidjson(vdict[k], val, allocator);
				out_val.AddMember(key_str, val, allocator);
			}
			break;
		}
		default: out_val.SetNull(); break;
	}
}

static Variant parse_schema_node(const rapidjson::Value& node) {
	if (!node.IsObject()) return Variant();

	if (node.HasMember("type") && node["type"].IsString()) {
		std::string type_str = node["type"].GetString();
		
		if (type_str == "object") {
			Dictionary dict;
			if (node.HasMember("properties") && node["properties"].IsObject()) {
				const auto& props = node["properties"];
				for (auto itr = props.MemberBegin(); itr != props.MemberEnd(); ++itr) {
					String key = String::utf8(itr->name.GetString(), itr->name.GetStringLength());
					dict[key] = parse_schema_node(itr->value);
				}
			}
			return dict;
		}
		if (type_str == "array") {
			return Array();
		}
		if (type_str == "string") {
			return String("");
		}
		if (type_str == "number" || type_str == "numeric") {
			return 0.0;
		}
		if (type_str == "integer") {
			return (int64_t)0;
		}
		if (type_str == "boolean") {
			return false;
		}
	}
	return Variant();
}

// --- Bindings ---

void RapidJSON::_bind_methods() {
	ClassDB::bind_method(D_METHOD("from_string", "json_str"), &RapidJSON::from_string);
	ClassDB::bind_method(D_METHOD("to_string", "data", "pretty"), &RapidJSON::to_string, DEFVAL(false));
	
	ClassDB::bind_method(D_METHOD("validate", "json_str"), &RapidJSON::validate);
	ClassDB::bind_method(D_METHOD("validate_schema", "json_str", "schema_str"), &RapidJSON::validate_schema);
	ClassDB::bind_method(D_METHOD("is_valid_json", "json_str"), &RapidJSON::is_valid_json);
	ClassDB::bind_method(D_METHOD("minify_json", "json_str"), &RapidJSON::minify_json);
	
	ClassDB::bind_method(D_METHOD("get_at_pointer", "json_str", "pointer"), &RapidJSON::get_at_pointer);
	ClassDB::bind_method(D_METHOD("generate_default_from_schema", "schema_str"), &RapidJSON::generate_default_from_schema);
}

RapidJSON::RapidJSON() {}
RapidJSON::~RapidJSON() {}

Variant RapidJSON::from_string(const String &json_str) {
	rapidjson::Document d;
	if (d.Parse(json_str.utf8().get_data()).HasParseError()) {
		ERR_PRINT(String("Parse error: ") + rapidjson::GetParseError_En(d.GetParseError()));
		return Variant();
	}
	return rapidjson_to_variant(d);
}

String RapidJSON::to_string(const Variant &data, bool pretty) {
	rapidjson::Document d;
	variant_to_rapidjson(data, d, d.GetAllocator());
	
	rapidjson::StringBuffer buffer;
	if (pretty) {
		rapidjson::PrettyWriter<rapidjson::StringBuffer> writer(buffer);
		d.Accept(writer);
	} else {
		rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
		d.Accept(writer);
	}
	return String(buffer.GetString());
}

Dictionary RapidJSON::validate(const String &json_str) {
	Dictionary result;
	rapidjson::Document d;
	rapidjson::ParseResult ok = d.Parse(json_str.utf8().get_data());
	
	if (!ok) {
		result["valid"] = false;
		result["error"] = String(rapidjson::GetParseError_En(ok.Code())) + " (offset " + String::num_int64(ok.Offset()) + ")";
	} else {
		result["valid"] = true;
		result["error"] = "";
	}
	return result;
}

Dictionary RapidJSON::validate_schema(const String &json_str, const String &schema_str) {
	Dictionary result;
	
	rapidjson::Document sd;
	if (sd.Parse(schema_str.utf8().get_data()).HasParseError()) {
		result["valid"] = false;
		result["error"] = "Invalid schema JSON structure.";
		return result;
	}
	
	rapidjson::SchemaDocument schema(sd);
	rapidjson::SchemaValidator validator(schema);
	
	rapidjson::Reader reader;
	rapidjson::StringStream ss(json_str.utf8().get_data());
	
	if (!reader.Parse(ss, validator) && reader.GetParseErrorCode() != rapidjson::kParseErrorTermination) {
		result["valid"] = false;
		result["error"] = String("Invalid input JSON: ") + rapidjson::GetParseError_En(reader.GetParseErrorCode());
		return result;
	}
	
	if (validator.IsValid()) {
		result["valid"] = true;
		result["error"] = "";
	} else {
		rapidjson::StringBuffer sb;
		validator.GetInvalidDocumentPointer().StringifyUriFragment(sb);
		String doc_ptr = sb.GetString();
		
		sb.Clear();
		validator.GetInvalidSchemaPointer().StringifyUriFragment(sb);
		String schema_ptr = sb.GetString();
		
		String keyword = validator.GetInvalidSchemaKeyword();
		
		result["valid"] = false;
		result["error"] = String("Schema violation at '") + doc_ptr + "'. Keyword: '" + keyword + "'. Schema pointer: '" + schema_ptr + "'.";
	}
	
	return result;
}

bool RapidJSON::is_valid_json(const String &json_str) {
	rapidjson::Reader reader;
	rapidjson::StringStream is(json_str.utf8().get_data());
	
	// BaseReaderHandler drops all parsed events, preventing DOM allocation
	rapidjson::BaseReaderHandler<rapidjson::UTF8<>> handler;
	
	return reader.Parse(is, handler);
}

String RapidJSON::minify_json(const String &json_str) {
	rapidjson::Reader reader;
	rapidjson::StringStream is(json_str.utf8().get_data());
	rapidjson::StringBuffer os;
	rapidjson::Writer<rapidjson::StringBuffer> writer(os);
	
	if (!reader.Parse(is, writer)) {
		return "";
	}
	return String(os.GetString());
}

Variant RapidJSON::get_at_pointer(const String &json_str, const String &pointer) {
	rapidjson::Document d;
	if (d.Parse(json_str.utf8().get_data()).HasParseError()) {
		return Variant();
	}
	
	rapidjson::Pointer ptr(pointer.utf8().get_data());
	rapidjson::Value* val = ptr.Get(d);
	
	if (val) {
		return rapidjson_to_variant(*val);
	}
	return Variant();
}

Dictionary RapidJSON::generate_default_from_schema(const String &schema_str) {
	rapidjson::Document d;
	if (d.Parse(schema_str.utf8().get_data()).HasParseError()) {
		ERR_PRINT("Invalid schema JSON format.");
		return Dictionary();
	}
	
	Variant result = parse_schema_node(d);
	if (result.get_type() == Variant::DICTIONARY) {
		return result;
	}
	
	return Dictionary();
}