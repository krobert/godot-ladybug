extends Node
class_name MCPServer

var _server: TCPServer = TCPServer.new()
var _pending_http_clients: Dictionary = {} # StreamPeerTCP -> PackedByteArray (Buffer)
var _sse_streams: Dictionary = {} # sessionId (String) -> StreamPeerTCP
var _glaze: Glaze

var _tools: Dictionary = {}
var _resources: Dictionary = {}

func _ready() -> void:
	_glaze = Glaze.new()
	var err: int = _server.listen(3000)
	if err == OK:
		print("Godot MCP Server running on port 3000 (HTTP SSE)")

func _process(_delta: float) -> void:
	# 1. Accept new incoming HTTP connections
	if _server.is_connection_available():
		var new_client: StreamPeerTCP = _server.take_connection()
		_pending_http_clients[new_client] = PackedByteArray()

	# 2. Process incoming HTTP requests (Handshakes or POSTs)
	var dead_clients: Array[StreamPeerTCP] = []
	for client: StreamPeerTCP in _pending_http_clients:
		client.poll()
		
		var status: int = client.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			dead_clients.append(client)
			continue
			
		var bytes: int = client.get_available_bytes()
		if bytes > 0:
			var chunk: PackedByteArray = client.get_partial_data(bytes)[1]
			_pending_http_clients[client].append_array(chunk)
			
			if _is_http_request_complete(_pending_http_clients[client]):
				var req_str: String = _pending_http_clients[client].get_string_from_utf8()
				_handle_http_request(client, req_str)
				dead_clients.append(client)

	for c: StreamPeerTCP in dead_clients:
		_pending_http_clients.erase(c)

	# 3. Cleanup dead SSE streams
	var dead_sessions: Array[String] = []
	for session_id in _sse_streams:
		var stream: StreamPeerTCP = _sse_streams[session_id]
		stream.poll()
		if stream.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			dead_sessions.append(session_id)
			
	for session_id in dead_sessions:
		_sse_streams.erase(session_id)

func register_tool(tool_name: String, description: String, schema: Dictionary, callback: Callable) -> void:
	_tools[tool_name] = {"name": tool_name, "description": description, "inputSchema": schema, "callback": callback}

func register_resource(uri: String, resource_name: String, description: String, mime: String, callback: Callable) -> void:
	_resources[uri] = {"uri": uri, "name": resource_name, "description": description, "mimeType": mime, "callback": callback}

func _is_http_request_complete(buffer: PackedByteArray) -> bool:
	var req_str: String = buffer.get_string_from_utf8()
	var header_end: int = req_str.find("\r\n\r\n")
	
	if header_end == -1:
		return false # Headers not fully received yet
		
	var headers: String = req_str.substr(0, header_end)
	var content_length: int = 0
	
	# Extract Content-Length if it exists
	var lines: PackedStringArray = headers.split("\r\n")
	for line in lines:
		var lower_line: String = line.to_lower()
		if lower_line.begins_with("content-length:"):
			content_length = lower_line.split(":")[1].strip_edges().to_int()
			break
			
	var expected_total_size: int = header_end + 4 + content_length
	return buffer.size() >= expected_total_size

func _handle_http_request(client: StreamPeerTCP, req_str: String) -> void:
	var header_end: int = req_str.find("\r\n\r\n")
	if header_end == -1: return
	
	var headers_str: String = req_str.substr(0, header_end)
	var lines: PackedStringArray = headers_str.split("\r\n")
	if lines.is_empty(): return
	
	var req_line: PackedStringArray = lines[0].split(" ")
	if req_line.size() < 2: return
	
	var method: String = req_line[0]
	var path: String = req_line[1]
	
	if method == "OPTIONS" and path.begins_with("/api/mcp"):
		_send_http_response(client, 200, "OK", "", "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n")
		return

	if method == "GET" and path.begins_with("/api/mcp/sse"):
		var session_id: String = str(Time.get_ticks_usec()) # Generate unique ID
		_sse_streams[session_id] = client
		
		var sse_headers: String = "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n"
		_send_http_response(client, 200, "OK", "text/event-stream", sse_headers, false)
		
		var endpoint_event: String = "event: endpoint\ndata: /api/mcp/message?sessionId=%s\n\n" % session_id
		client.put_utf8_string(endpoint_event)
		return

	if method == "POST" and path.begins_with("/api/mcp/message"):
		var session_id: String = _extract_query_param(path, "sessionId")
		var body: String = req_str.substr(header_end + 4)
		
		# Acknowledge POST immediately
		_send_http_response(client, 202, "Accepted", "text/plain", "Access-Control-Allow-Origin: *\r\n")
		
		if session_id != "" and _sse_streams.has(session_id):
			_process_mcp_rpc(_sse_streams[session_id], body)
		return
		
	_send_http_response(client, 404, "Not Found", "text/plain", "")

func _process_mcp_rpc(sse_client: StreamPeerTCP, json_str: String) -> void:
	var req: Variant = _glaze.from_string(json_str) # Glaze parses payload
	if typeof(req) != TYPE_DICTIONARY or not req.has("method"):
		_send_error(sse_client, null, -32700, "Parse error")
		return

	var msg_id: Variant = req.get("id", null)
	var params: Dictionary = req.get("params", {})
	
	match req["method"]:
		"resources/list":
			var res_list: Array = []
			for key in _resources:
				var r: Dictionary = _resources[key]
				res_list.append({"uri": r.uri, "name": r.name, "description": r.description, "mimeType": r.mimeType})
			_send_response(sse_client, msg_id, {"resources": res_list})
			
		"resources/read":
			var uri: String = params.get("uri", "")
			if _resources.has(uri):
				var content: String = await _resources[uri].callback.call(uri)
				_send_response(sse_client, msg_id, {"contents": [{"uri": uri, "mimeType": _resources[uri].mimeType, "text": content}]})
			else:
				_send_error(sse_client, msg_id, -32602, "Invalid resource URI")
				
		"tools/list":
			var tool_list: Array = []
			for key in _tools:
				var t: Dictionary = _tools[key]
				tool_list.append({"name": t.name, "description": t.description, "inputSchema": t.inputSchema})
			_send_response(sse_client, msg_id, {"tools": tool_list})
			
		"tools/call":
			var tool_name: String = params.get("name", "")
			if not _tools.has(tool_name):
				_send_error(sse_client, msg_id, -32601, "Tool not found")
				return
				
			var raw_args: Dictionary = params.get("arguments", {})
			# Dynamic tool execution mapping back to Hortus server logic
			var exec_result: String = await _tools[tool_name].callback.call(raw_args)
			
			# Ensure we don't double stringify if callback already used Glaze.to_string
			var parsed_content: Variant = _glaze.from_string(exec_result)
			var content_val: Variant = parsed_content if parsed_content != null else exec_result
			_send_response(sse_client, msg_id, {"content": [{"type": "text", "text": _glaze.to_string(content_val)}]})
			
		_:
			_send_error(sse_client, msg_id, -32601, "Method not found")

func _send_response(client: StreamPeerTCP, id: Variant, result: Dictionary) -> void:
	if id == null: return
	var payload: String = _glaze.to_string({"jsonrpc": "2.0", "id": id, "result": result})
	client.put_utf8_string("event: message\ndata: %s\n\n" % payload)

func _send_error(client: StreamPeerTCP, id: Variant, code: int, message: String) -> void:
	if id == null: return
	var payload: String = _glaze.to_string({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
	client.put_utf8_string("event: message\ndata: %s\n\n" % payload)

func _send_http_response(client: StreamPeerTCP, code: int, status: String, content_type: String, extra_headers: String, close_conn: bool = true) -> void:
	var response: String = "HTTP/1.1 %d %s\r\n" % [code, status]
	if content_type != "":
		response += "Content-Type: %s\r\n" % content_type
	response += extra_headers
	
	if close_conn:
		response += "Connection: close\r\n\r\n"
		client.put_utf8_string(response)
		client.disconnect_from_host()
	else:
		response += "\r\n"
		client.put_utf8_string(response)

func _extract_query_param(path: String, param: String) -> String:
	var q_idx: int = path.find("?")
	if q_idx == -1: return ""
	var query: String = path.substr(q_idx + 1)
	var pairs: PackedStringArray = query.split("&")
	for pair in pairs:
		var kv: PackedStringArray = pair.split("=")
		if kv.size() == 2 and kv[0] == param:
			return kv[1]
	return ""