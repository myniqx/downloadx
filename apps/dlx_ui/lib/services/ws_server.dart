import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int kWsPort = 46582;

typedef WsMessageHandler = void Function(Map<String, dynamic> msg, WebSocket socket);

class WsServer {
  HttpServer? _server;
  final Set<WebSocket> _clients = {};
  final WsMessageHandler onMessage;

  WsServer({required this.onMessage});

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, kWsPort);
    _server!.listen(_handleRequest);
  }

  Future<void> _handleRequest(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(req);
    _clients.add(socket);
    socket.listen(
      (data) {
        try {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          onMessage(msg, socket);
        } catch (_) {}
      },
      onDone: () => _clients.remove(socket),
      onError: (_) => _clients.remove(socket),
      cancelOnError: true,
    );
  }

  void broadcast(Map<String, dynamic> msg) {
    final encoded = jsonEncode(msg);
    for (final c in _clients) {
      c.add(encoded);
    }
  }

  void send(WebSocket socket, Map<String, dynamic> msg) {
    socket.add(jsonEncode(msg));
  }

  Future<void> stop() async {
    for (final c in _clients) {
      await c.close();
    }
    _clients.clear();
    await _server?.close(force: true);
  }
}
