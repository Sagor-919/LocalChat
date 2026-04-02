// Minimal WebSocket presence hub for global discovery.
// Run: dart run bin/signaling_server.dart [port]
// Clients set Settings → Global discovery → Signaling URL e.g. ws://YOUR_IP:4576/
import 'dart:async';
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  final port = args.isNotEmpty ? (int.tryParse(args.first) ?? 4576) : 4576;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  // ignore: avoid_print
  print('LocalChat signaling: ws://0.0.0.0:$port/ (any path)');

  final clients = <WebSocket>{};
  final registry = <String, Map<String, dynamic>>{};
  var seq = 0;

  void removeStale() {
    final now = DateTime.now();
    registry.removeWhere((_, v) {
      final t = v['_seen'] as DateTime?;
      if (t == null) return true;
      return now.difference(t) > const Duration(seconds: 45);
    });
  }

  Timer.periodic(const Duration(seconds: 15), (_) {
    removeStale();
    _broadcast(clients, registry);
  });

  await for (final request in server) {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      continue;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    clients.add(socket);
    final id = ++seq;
    _broadcast(clients, registry);
    socket.listen(
      (dynamic data) {
        if (data is! String) return;
        Map<String, dynamic>? j;
        try {
          j = jsonDecode(data) as Map<String, dynamic>?;
        } catch (_) {
          return;
        }
        if (j == null || j['t'] != 'reg') return;
        final peerId = j['id'] as String?;
        if (peerId == null || peerId.isEmpty) return;
        registry[peerId] = {
          'id': peerId,
          'n': j['n'] ?? 'Peer',
          'tag': j['tag'] ?? '',
          'lip': j['lip'] ?? '',
          'tp': j['tp'] ?? 4041,
          'tfp': j['tfp'] ?? 4042,
          'wip': j['wip'] ?? '',
          '_seen': DateTime.now(),
        };
        removeStale();
        _broadcast(clients, registry);
      },
      onError: (_) {},
      onDone: () {
        clients.remove(socket);
      },
      cancelOnError: true,
    );
    // ignore: avoid_print
    print('client #$id connected (${clients.length} total)');
  }
}

void _broadcast(
  Set<WebSocket> clients,
  Map<String, Map<String, dynamic>> registry,
) {
  final list = <Map<String, dynamic>>[];
  for (final e in registry.values) {
    final copy = Map<String, dynamic>.from(e)..remove('_seen');
    list.add(copy);
  }
  final msg = jsonEncode({'t': 'peers', 'list': list});
  for (final c in clients.toList()) {
    if (c.readyState == WebSocket.open) {
      try {
        c.add(msg);
      } catch (_) {}
    }
  }
}
