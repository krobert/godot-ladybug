extends Node
class_name MCPServer

signal connection_changed(active_sessions: int)

const MAX_HEADER_BYTES: int = 32768
const MAX_BODY_BYTES: int = 8 * 1024 * 1024
const REQUEST_TIMEOUT_MSEC: int = 10000

@export var logger: DebugLogger
@export var port: int = 3000

var _server: TCPServer = TCPServer.new()
var _pending_clients: Array[Dictionary] = []
var _sse_streams: Dictionary = {}
var _glaze: Glaze

var _tools: Dictionary = {}
var _resources: Dictionary = {}
var _prompts: Dictionary = {}
var _active_session_count: int = 0
var _last_keepalive_msec: int = 0

func _ready() -> void:
	_glaze = Glaze.new()

func start() -> Error:
	if _server.is_listening():
		stop()
	var err: Error = _server.listen(port)
	if err == OK and logger:
		logger.d("Godot MCP Server running on port ", port, " (HTTP SSE)")
	return err

func stop() -> void:
	if _server.is_listening():
		_server.stop()
		
	for conn: Dictionary in _pending_clients:
		var peer: StreamPeerTCP = conn["peer"]
		peer.disconnect_from_host()
	_pending_clients.clear()
	
	for session_id: String in _sse_streams:
		_sse_streams[session_id].disconnect_from_host()
	_sse_streams.clear()
	
	if _active_session_count != 0:
		_active_session_count = 0
		connection_changed.emit(0)

func _process(_delta: float) -> void:
	if not _server.is_listening(): return
	
	while _server.is_connection_available():
		var peer: StreamPeerTCP = _server.take_connection()
		peer.set_no_delay(true)
		_pending_clients.append({
			"peer": peer,
			"buffer": PackedByteArray(),
			"headers_parsed": false,
			"content_length": 0,
			"method": "",
			"path": "/",
			"started_msec": Time.get_ticks_msec()
		})

	for i: int in range(_pending_clients.size() - 1, -1, -1):
		var conn: Dictionary = _pending_clients[i]
		var peer: StreamPeerTCP = conn["peer"]
		peer.poll()

		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_pending_clients.remove_at(i)
			continue

		if Time.get_ticks_msec() - conn["started_msec"] > REQUEST_TIMEOUT_MSEC:
			_send_http_response(peer, 408, "Request Timeout", "text/plain", "")
			_pending_clients.remove_at(i)
			continue

		var available: int = peer.get_available_bytes()
		if available > 0:
			conn["buffer"].append_array(peer.get_partial_data(available)[1])

		if not conn["headers_parsed"]:
			var req_str: String = conn["buffer"].get_string_from_utf8()
			var header_end: int = req_str.find("\r\n\r\n")
			
			if header_end == -1:
				if conn["buffer"].size() > MAX_HEADER_BYTES:
					_send_http_response(peer, 431, "Headers Too Large", "text/plain", "")
					_pending_clients.remove_at(i)
				continue
				
			_parse_headers(conn, req_str.substr(0, header_end))
			
			if conn["content_length"] > MAX_BODY_BYTES:
				_send_http_response(peer, 413, "Payload Too Large", "text/plain", "")
				_pending_clients.remove_at(i)
				continue

		if conn["headers_parsed"]:
			var expected_total_size: int = conn["buffer"].get_string_from_utf8().find("\r\n\r\n") + 4 + conn["content_length"]
			if conn["buffer"].size() >= expected_total_size:
				var full_req: String = conn["buffer"].get_string_from_utf8()
				var body_text: String = full_req.substr(full_req.find("\r\n\r\n") + 4)
				_route_request(peer, conn["method"], conn["path"], body_text)
				_pending_clients.remove_at(i)

	var dead_sessions: Array[String] = []
	for session_id: String in _sse_streams:
		var stream: StreamPeerTCP = _sse_streams[session_id]
		stream.poll()
		if stream.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			dead_sessions.append(session_id)
			
	for session_id: String in dead_sessions:
		_sse_streams.erase(session_id)
	
	var current_time: int = Time.get_ticks_msec()
	if current_time - _last_keepalive_msec > 15000:
		_last_keepalive_msec = current_time
		var keepalive_bytes: PackedByteArray = ": keepalive\r\n\r\n".to_utf8_buffer()
		for session_id: String in _sse_streams:
			_sse_streams[session_id].put_data(keepalive_bytes)
	_update_session_count()

func register_tool(t_name: String, desc: String, schema: Dictionary, callback: Callable) -> void:
	_tools[t_name] = {"name": t_name, "description": desc, "inputSchema": schema, "callback": callback}

func register_resource(uri: String, r_name: String, desc: String, mime: String, callback: Callable) -> void:
	_resources[uri] = {"uri": uri, "name": r_name, "description": desc, "mimeType": mime, "callback": callback}

func _parse_headers(conn: Dictionary, headers_str: String) -> void:
	var lines: PackedStringArray = headers_str.split("\r\n")
	if lines.is_empty(): return
	
	var req_line: PackedStringArray = lines[0].split(" ")
	if req_line.size() >= 2:
		conn["method"] = req_line[0]
		conn["path"] = req_line[1]

	for i: int in range(1, lines.size()):
		var lower_line: String = lines[i].to_lower()
		if lower_line.begins_with("content-length:"):
			conn["content_length"] = lower_line.split(":")[1].strip_edges().to_int()
			
	conn["headers_parsed"] = true

func _route_request(client: StreamPeerTCP, method: String, path: String, body: String) -> void:
	if logger:
		logger.d("HTTP Request: ", method, " ", path)
		
	if method == "OPTIONS" and path.begins_with("/mcp"):
		_send_http_response(client, 200, "OK", "", "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n")
		return

	if method == "GET" and path.begins_with("/mcp/sse"):
		var session_id: String = str(Time.get_ticks_usec())
		_sse_streams[session_id] = client
		var sse_headers: String = "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n"
		_send_http_response(client, 200, "OK", "text/event-stream", sse_headers, false)
		client.put_data(("event: endpoint\r\ndata: http://127.0.0.1:%d/mcp/message?sessionId=%s\r\n\r\n" % [port, session_id]).to_utf8_buffer())
		_update_session_count()
		
		if logger:
			logger.d("SSE stream opened: ", session_id)
		return

	if method == "POST" and path.begins_with("/mcp/message"):
		var session_id: String = _extract_query_param(path, "sessionId")
		
		if session_id != "" and _sse_streams.has(session_id):
			_process_mcp_rpc(_sse_streams[session_id], body)
		elif logger:
			logger.e("POST received for unknown SSE session: ", session_id)
			
		_send_http_response(client, 202, "Accepted", "text/plain", "Access-Control-Allow-Origin: *\r\n", true)
		return
		
	_send_http_response(client, 404, "Not Found", "text/plain", "")

func _process_mcp_rpc(sse_client: StreamPeerTCP, json_str: String) -> void:
	if logger:
		logger.d("Incoming RPC: ", json_str)
		
	var req: Variant = _glaze.from_string(json_str)
	if typeof(req) != TYPE_DICTIONARY or not req.has("method"):
		if logger:
			logger.e("Parse error on incoming RPC")
		_send_error(sse_client, null, -32700, "Parse error")
		return

	var msg_id: Variant = req.get("id", null)
	var params: Dictionary = req.get("params", {})
	
	match req["method"]:
		"initialize":
			var client_version: String = params.get("protocolVersion", "2024-11-05")
			var negotiated: String = client_version if client_version in ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"] else "2024-11-05"
			_send_response(sse_client, msg_id, {
				"protocolVersion": negotiated,
				"capabilities": {"tools": {}, "resources": {}, "prompts": {}},
				"serverInfo": {"name": "GodotMCP", "version": "1.0.0"}
			})
			
		"notifications/initialized", "notifications/cancelled":
			pass
			
		"ping":
			_send_response(sse_client, msg_id, {})
			
		"tools/list":
			var t_list: Array = []
			for key: String in _tools:
				t_list.append({"name": _tools[key].name, "description": _tools[key].description, "inputSchema": _tools[key].inputSchema})
			_send_response(sse_client, msg_id, {"tools": t_list})
			
		"tools/call":
			var t_name: String = params.get("name", "")
			if not _tools.has(t_name):
				if logger:
					logger.e("Tool not found: ", t_name)
				_send_error(sse_client, msg_id, -32601, "Tool not found: " + t_name)
				return
				
			if logger:
				logger.d("Executing tool: ", t_name)
				
			var exec_result: Variant = await _tools[t_name].callback.call(params.get("arguments", {}))
			var is_err: bool = typeof(exec_result) == TYPE_DICTIONARY and exec_result.has("error")
			
			var response_data: Dictionary = {
				"content": [{"type": "text", "text": exec_result if typeof(exec_result) == TYPE_STRING else _glaze.to_string(exec_result)}],
				"isError": is_err
			}
			
			if not is_err and typeof(exec_result) == TYPE_DICTIONARY:
				response_data["structuredContent"] = exec_result
				
			_send_response(sse_client, msg_id, response_data)
			
		"resources/list":
			var r_list: Array = []
			for key: String in _resources:
				r_list.append({"uri": _resources[key].uri, "name": _resources[key].name, "description": _resources[key].description, "mimeType": _resources[key].mimeType})
			_send_response(sse_client, msg_id, {"resources": r_list})
			
		"resources/read":
			var uri: String = params.get("uri", "")
			if _resources.has(uri):
				var content: Variant = await _resources[uri].callback.call(uri)
				_send_response(sse_client, msg_id, {"contents": [{"uri": uri, "mimeType": _resources[uri].mimeType, "text": content if typeof(content) == TYPE_STRING else _glaze.to_string(content)}]})
			else:
				if logger:
					logger.e("Invalid resource URI: ", uri)
				_send_error(sse_client, msg_id, -32602, "Invalid resource URI")
				
		_:
			if logger:
				logger.d("Method not found: ", req["method"])
			_send_error(sse_client, msg_id, -32601, "Method not found: " + str(req["method"]))
			

func _send_response(client: StreamPeerTCP, id: Variant, result: Dictionary) -> void:
	if id == null: return
	var payload: String = _glaze.to_string({"jsonrpc": "2.0", "id": id, "result": result}).replace("\n", "").replace("\r", "")
	
	if logger:
		logger.d("Sending SSE: ", payload)
		
	client.put_data(("event: message\r\ndata: %s\r\n\r\n" % payload).to_utf8_buffer())

func _send_error(client: StreamPeerTCP, id: Variant, code: int, message: String) -> void:
	if id == null: return
	var payload: String = _glaze.to_string({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}).replace("\n", "").replace("\r", "")
	
	if logger:
		logger.e("Sending Error SSE: ", payload)
		
	client.put_data(("event: message\r\ndata: %s\r\n\r\n" % payload).to_utf8_buffer())

func _send_http_response(client: StreamPeerTCP, code: int, status: String, content_type: String, extra_headers: String, close_conn: bool = true) -> void:
	var response: String = "HTTP/1.1 %d %s\r\n" % [code, status]
	if content_type != "": response += "Content-Type: %s\r\n" % content_type
	response += extra_headers
	
	if close_conn:
		response += "Content-Length: 0\r\nConnection: close\r\n\r\n"
		client.put_data(response.to_utf8_buffer())
		client.disconnect_from_host()
	elif code == 202:
		response += "Content-Length: 0\r\n\r\n"
		client.put_data(response.to_utf8_buffer())
	else:
		response += "\r\n"
		client.put_data(response.to_utf8_buffer())

func _extract_query_param(path: String, param: String) -> String:
	var q_idx: int = path.find("?")
	if q_idx == -1: return ""
	var pairs: PackedStringArray = path.substr(q_idx + 1).split("&")
	for pair: String in pairs:
		var kv: PackedStringArray = pair.split("=")
		if kv.size() == 2 and kv[0] == param: return kv[1]
	return ""

func _update_session_count() -> void:
	var current_count: int = _sse_streams.size()
	if current_count != _active_session_count:
		_active_session_count = current_count
		connection_changed.emit(_active_session_count)
