import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_settings.dart';
import 'connection_service.dart';
import 'device.dart';
import 'discovery_service.dart';
import 'file_transfer_service.dart';
import 'nat_port_mapping.dart';
import 'stun_client.dart';

/// Ensures a path segment so `WebSocket.connect` matches HTTP upgrade routes that expect `/`.
/// Example: `ws://host:4576` → `ws://host:4576/` (bundled [bin/signaling_server.dart] accepts any path).
String normalizeSignalingWebSocketUrl(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return t;
  final u = Uri.tryParse(t);
  if (u == null) return t;
  if (u.scheme != 'ws' && u.scheme != 'wss') return t;
  if (u.host.isEmpty) return t;
  if (u.path.isEmpty) {
    return u.replace(path: '/').toString();
  }
  return t;
}

/// WebSocket presence + STUN reflexive IP — same TCP ports as LAN ([ConnectionService.tcpPort] / file 4042).
/// Set [AppSettings.signalingServerUrl] and run `dart run bin/signaling_server.dart` on a reachable host.
class GlobalSignalingService {
  GlobalSignalingService._();
  static final instance = GlobalSignalingService._();

  DiscoveryService? _discovery;
  DeviceInfo? _me;

  Timer? _tick;
  WebSocket? _ws;
  bool _connecting = false;

  StunBindingResult? _lastStun;

  Future<void> init({
    required DiscoveryService discovery,
    required DeviceInfo me,
  }) async {
    _discovery = discovery;
    _me = me;
    AppSettings.instance.globalDiscoveryEnabled.addListener(_onToggle);
    AppSettings.instance.upnpPortMappingEnabled.addListener(_onUpnpToggle);
    _onToggle();
  }

  void _onUpnpToggle() {
    if (!AppSettings.instance.upnpPortMappingEnabled.value) {
      unawaited(NatPortMappingService.instance.release());
    }
  }

  void _onToggle() {
    if (AppSettings.instance.globalDiscoveryEnabled.value) {
      unawaited(_start());
    } else {
      _stop();
    }
  }

  Future<void> _start() async {
    _stop();
    final d = _discovery;
    final me = _me;
    if (d == null || me == null) return;

    await _pulseOnce();

    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_pulseOnce());
    });
  }

  void _stop() {
    _tick?.cancel();
    _tick = null;
    try {
      _ws?.close();
    } catch (_) {}
    _ws = null;
    _connecting = false;
    _lastStun = null;
    unawaited(NatPortMappingService.instance.release());
    _discovery?.clearWanOverlay();
  }

  Future<void> _pulseOnce() async {
    final d = _discovery;
    final me = _me;
    if (d == null || me == null) return;
    if (!AppSettings.instance.globalDiscoveryEnabled.value) return;

    await NatPortMappingService.instance.refreshIfNeeded(deviceId: me.userId);

    final stunHost = AppSettings.instance.stunHost.value.trim();
    final stunPort = AppSettings.instance.stunPort.value;
    if (stunHost.isNotEmpty) {
      _lastStun = await StunClient.queryBinding(
        stunHost: stunHost,
        stunPort: stunPort,
      );
    }

    final url = normalizeSignalingWebSocketUrl(
      AppSettings.instance.signalingServerUrl.value,
    );
    if (url.isEmpty) {
      d.clearWanOverlay();
      return;
    }

    final ok = await _ensureWebSocket(url);
    if (!ok) {
      d.clearWanOverlay();
      return;
    }
    await _sendRegister(me);
  }

  Future<bool> _ensureWebSocket(String url) async {
    if (_ws != null && _ws!.readyState == WebSocket.open) {
      return true;
    }
    if (_connecting) return false;
    _connecting = true;
    try {
      try {
        await _ws?.close();
      } catch (_) {}
      _ws = await WebSocket.connect(url);
      _ws!.listen(
        _onWsData,
        onError: (_) {},
        onDone: () {
          _ws = null;
        },
      );
      return true;
    } catch (e) {
      debugPrint('GlobalSignaling: connect failed: $e');
      _ws = null;
      return false;
    } finally {
      _connecting = false;
    }
  }

  void _onWsData(dynamic data) {
    if (data is! String) return;
    try {
      final j = jsonDecode(data) as Map<String, dynamic>;
      if (j['t'] != 'peers') return;
      final list = j['list'];
      if (list is! List) return;
      _applyPeerList(list);
    } catch (_) {}
  }

  void _applyPeerList(List<dynamic> list) {
    final d = _discovery;
    final me = _me;
    if (d == null || me == null) return;

    final map = <String, PeerDevice>{};
    for (final raw in list) {
      if (raw is! Map) continue;
      final id = raw['id'] as String?;
      if (id == null || id.isEmpty || id == me.userId) continue;
      final name = (raw['n'] as String?)?.trim() ?? 'Peer';
      final lip = (raw['lip'] as String?)?.trim() ?? '';
      final tp = (raw['tp'] as num?)?.toInt() ?? ConnectionService.tcpPort;
      final tfp = (raw['tfp'] as num?)?.toInt();
      final wip = (raw['wip'] as String?)?.trim();
      final tag = (raw['tag'] as String?)?.trim();
      final tagOrNull = tag != null && tag.isNotEmpty ? tag : null;

      map[id] = PeerDevice(
        userId: id,
        name: name,
        ip: lip,
        port: tp,
        lastSeen: DateTime.now(),
        lanStableTag: tagOrNull,
        lastSeenOnLan: null,
        wanIp: wip != null && wip.isNotEmpty ? wip : null,
        wanTcpPort: tp,
        wanFileTcpPort: tfp,
      );
    }
    d.setWanOverlay(map);
  }

  Future<void> _sendRegister(DeviceInfo me) async {
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) return;

    final lip = await _pickLanIp();
    final stun = _lastStun;
    final settings = AppSettings.instance;
    final manualIp = settings.wanManualPublicIp.value.trim();
    final wip = manualIp.isNotEmpty
        ? manualIp
        : (stun?.publicAddress.address ?? '');
    final advChat = settings.wanAdvertisedChatTcpPort.value;
    final advFile = settings.wanAdvertisedFileTcpPort.value;
    final tp = advChat != 0
        ? advChat
        : (NatPortMappingService.instance.mappedChatExternal ??
            ConnectionService.tcpPort);
    final tfp = advFile != 0
        ? advFile
        : (NatPortMappingService.instance.mappedFileExternal ??
            kFileTransferPort);
    final msg = jsonEncode({
      't': 'reg',
      'id': me.userId,
      'n': me.displayName,
      'tag': me.lanStableTag,
      'lip': lip,
      'tp': tp,
      'tfp': tfp,
      'wip': wip,
      'wudp': stun?.mappedUdpPort ?? 0,
    });
    try {
      ws.add(msg);
    } catch (_) {}
  }

  Future<String> _pickLanIp() async {
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        for (final a in iface.addresses) {
          if (a.isLoopback) continue;
          return a.address;
        }
      }
    } catch (_) {}
    return '';
  }

  void dispose() {
    AppSettings.instance.globalDiscoveryEnabled.removeListener(_onToggle);
    AppSettings.instance.upnpPortMappingEnabled.removeListener(_onUpnpToggle);
    _stop();
  }
}
