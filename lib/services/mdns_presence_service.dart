import 'dart:async';
import 'dart:io';

import 'package:mdns_dart/mdns_dart.dart';

import '../models/peer_device.dart';
import 'device_identity.dart';

class MdnsPresenceService {
  // Use a custom service type so only our app instances appear.
  static const String kMdnsServiceType = '_drivechat._tcp';

  // WebSocket port (Phase 2 will actually start the server).
  final int websocketPort;

  final DeviceIdentity identity;
  final String instanceName;

  MDNSServer? _server;
  bool _advertising = false;

  MdnsPresenceService({
    required this.identity,
    required this.websocketPort,
  }) : instanceName = '${identity.displayName}-${identity.userId.substring(0, 6)}';

  Future<void> startAdvertising() async {
    if (_advertising) return;

    final txt = MDNSService.createTXTRecords(<String, String>{
      'id': identity.userId,
      'name': identity.displayName,
      'wsPort': websocketPort.toString(),
    });

    final service = await MDNSService.create(
      instance: instanceName,
      service: kMdnsServiceType,
      port: websocketPort,
      txt: txt,
    );

    _server = MDNSServer(MDNSServerConfig(zone: service));
    await _server!.start();
    _advertising = true;
  }

  Future<void> stopAdvertising() async {
    if (!_advertising) return;
    final server = _server;
    _server = null;
    _advertising = false;
    await server?.stop();
  }

  Future<List<PeerDevice>> discoverOnce({Duration timeout = const Duration(seconds: 2)}) async {
    // mdns_dart discover() returns all results after `timeout`.
    final results = await MDNSClient.discover(
      kMdnsServiceType,
      timeout: timeout,
    );

    final now = DateTime.now();
    final peers = <PeerDevice>[];

    for (final mdnsService in results) {
      final txtFields = mdnsService.infoFields;
      final parsed = MDNSService.parseTXTRecords(txtFields);

      final peerId = parsed['id'];
      final peerName = parsed['name']?.trim().isNotEmpty == true
          ? parsed['name']!.trim()
          : mdnsService.name;

      // mdns_dart might not include TXT (or might be incomplete), so be defensive.
      final wsPort = int.tryParse(parsed['wsPort'] ?? '') ?? mdnsService.port;

      if (peerId == null || peerId.isEmpty) continue;

      // Don't show ourselves.
      if (peerId == identity.userId) continue;

      final ip = mdnsService.primaryAddress?.address;
      if (ip == null || ip.isEmpty) continue;

      peers.add(
        PeerDevice(
          userId: peerId,
          displayName: peerName,
          ipAddress: ip,
          wsPort: wsPort,
          lastSeen: now,
        ),
      );
    }

    return peers;
  }

  bool get isAdvertising => _advertising;
  String get serviceType => kMdnsServiceType;

  // Best-effort helper for debugging during local development.
  Future<void> debugLogInterfaces() async {
    final interfaces = await NetworkInterface.list();
    for (final iface in interfaces) {
      // ignore: avoid_print
      print('mDNS iface: ${iface.name} ${iface.addresses.map((a) => a.address).join(", ")}');
    }
  }

  Future<void> close() async {
    await stopAdvertising();
  }
}

