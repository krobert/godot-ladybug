extends Node
class_name MCPServer

signal connection_changed(active_sessions: int)

const MAX_HEADER_BYTES: int = 32768
const MAX_BODY_BYTES: int = 8 * 1024 * 1024
const REQUEST_TIMEOUT_MSEC: int = 10000

@export var logger: DebugLogger

var _server: TCPServer = TCPServer.new()
var _pending_clients: Array[Dictionary] = []
var _sse_streams: Dictionary = {}
var _glaze: Glaze

var _tools: Dictionary = {}
var _resources: Dictionary = {}
var _active_session_count: int = 0

var port: int

func _ready() -> void:
	_glaze = Glaze.new()

func start(p_port: int = 3000) -> Error:
	if _server.is_listening():
		stop()
	port = p_port
	var err: Error = _server.listen(port)
	if err == OK:
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
				
			var headers_str: String = req_str.substr(0, header_end)
			_parse_headers(conn, headers_str)
			
			if conn["content_length"] > MAX_BODY_BYTES:
				_send_http_response(peer, 413, "Payload Too Large", "text/plain", "")
				_pending_clients.remove_at(i)
				continue

		if conn["headers_parsed"]:
			var expected_total_size: int = conn["buffer"].get_string_from_utf8().find("\r\n\r\n") + 4 + conn["content_length"]
			if conn["buffer"].size() >= expected_total_size:
				var full_req: String = conn["buffer"].get_string_from_utf8()
				var body_start: int = full_req.find("\r\n\r\n") + 4
				var body_text: String = full_req.substr(body_start)
				
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
		
	_update_session_count()

func register_tool(tool_name: String, description: String, schema: Dictionary, callback: Callable) -> void:
	_tools[tool_name] = {"name": tool_name, "description": description, "inputSchema": schema, "callback": callback}

func register_resource(uri: String, resource_name: String, description: String, mime: String, callback: Callable) -> void:
	_resources[uri] = {"uri": uri, "name": resource_name, "description": description, "mimeType": mime, "callback": callback}

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
	logger.d("HTTP Request: ", method, " ", path)
	
	if method == "OPTIONS" and path.begins_with("/mcp"):
		_send_http_response(client, 200, "OK", "", "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n")
		return

	if method == "GET" and path.begins_with("/mcp/sse"):
		var session_id: String = str(Time.get_ticks_usec())
		_sse_streams[session_id] = client
		
		var sse_headers: String = "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n"
		_send_http_response(client, 200, "OK", "text/event-stream", sse_headers, false)
		
		var endpoint_event: String = "event: endpoint\r\ndata: http://127.0.0.1:%d/mcp/message?sessionId=%s\r\n\r\n" % [port, session_id]
		client.put_data(endpoint_event.to_utf8_buffer())
		_update_session_count()
		logger.d("SSE stream opened: ", session_id)
		return

	if method == "POST" and path.begins_with("/mcp/message"):
		var session_id: String = _extract_query_param(path, "sessionId")
		_send_http_response(client, 202, "Accepted", "text/plain", "Access-Control-Allow-Origin: *\r\n", false)
		
		if session_id != "" and _sse_streams.has(session_id):
			_process_mcp_rpc(_sse_streams[session_id], body)
		else:
			logger.d("POST received for unknown SSE session: ", session_id)
		return
		
	_send_http_response(client, 404, "Not Found", "text/plain", "")

func _process_mcp_rpc(sse_client: StreamPeerTCP, json_str: String) -> void:
	logger.d("Incoming RPC: ", json_str)
	var req: Variant = _glaze.from_string(json_str)
	if typeof(req) != TYPE_DICTIONARY or not req.has("method"):
		logger.e("Parse error on incoming RPC")
		_send_error(sse_client, null, -32700, "Parse error")
		return

	var msg_id: Variant = req.get("id", null)
	var params: Dictionary = req.get("params", {})
	
	match req["method"]:
		"initialize":
			_send_response(sse_client, msg_id, {
				"protocolVersion": "2024-11-05",
				"capabilities": {"tools": {}, "resources": {}},
				"serverInfo": {"name": "GodotMCP", "version": "1.0.0"}
			})
		"notifications/initialized":
			pass
		"ping":
			_send_response(sse_client, msg_id, {})
		"tools/list":
			var tool_list: Array = []
			for key: String in _tools:
				var t: Dictionary = _tools[key]
				tool_list.append({"name": t.name, "description": t.description, "inputSchema": t.inputSchema})
			_send_response(sse_client, msg_id, {"tools": tool_list})
		"tools/call":
			var tool_name: String = params.get("name", "")
			if not _tools.has(tool_name):
				logger.e("Tool not found: ", tool_name)
				_send_error(sse_client, msg_id, -32601, "Tool not found")
				return
			
			logger.d("Executing tool: ", tool_name)
			var raw_args: Dictionary = params.get("arguments", {})
			
			var exec_result: Variant = await _tools[tool_name].callback.call(raw_args)
			var text_output: String
			
			if typeof(exec_result) == TYPE_STRING:
				text_output = exec_result
			else:
				text_output = _glaze.to_string(exec_result)
				
			_send_response(sse_client, msg_id, {"content": [{"type": "text", "text": text_output}]})
		_:
			logger.d("Method not found: ", req["method"])
			_send_error(sse_client, msg_id, -32601, "Method not found")
			
func _send_response(client: StreamPeerTCP, id: Variant, result: Dictionary) -> void:
	if id == null: return
	var payload: String = _glaze.to_string({"jsonrpc": "2.0", "id": id, "result": result}).replace("\n", "")
	var sse_event: String = "event: message\r\ndata: %s\r\n\r\n" % payload
	client.put_data(sse_event.to_utf8_buffer())

func _send_error(client: StreamPeerTCP, id: Variant, code: int, message: String) -> void:
	if id == null: return
	var payload: String = _glaze.to_string({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}).replace("\n", "")
	var sse_event: String = "event: message\r\ndata: %s\r\n\r\n" % payload
	client.put_data(sse_event.to_utf8_buffer())

func _send_http_response(client: StreamPeerTCP, code: int, status: String, content_type: String, extra_headers: String, close_conn: bool = true) -> void:
	var response: String = "HTTP/1.1 %d %s\r\n" % [code, status]
	if content_type != "":
		response += "Content-Type: %s\r\n" % content_type
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
		if kv.size() == 2 and kv[0] == param:
			return kv[1]
	return ""

func _update_session_count() -> void:
	var current_count: int = _sse_streams.size()
	if current_count != _active_session_count:
		_active_session_count = current_count
		connection_changed.emit(_active_session_count)
