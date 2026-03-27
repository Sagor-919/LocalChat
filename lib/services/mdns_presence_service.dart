import 'dart:async';
import 'dart:io';

import 'package:mdns_dart/mdns_dart.dart';
import 'package:multicast_dns/multicast_dns.dart';

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
    // NOTE: mdns_dart's discover() has been causing "Cannot add event after closing"
    // crashes on Windows/Android. We use multicast_dns for discovery instead.
    final client = MDnsClient();
    await client.start();

    final now = DateTime.now();
    final peersById = <String, PeerDevice>{};

    final serviceTypeFqdn = '$kMdnsServiceType.local';

    Future<void> resolveService(String instanceFqdn) async {
      // SRV gives us target host + port.
      await for (final srv in client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(instanceFqdn),
      )) {
        final target = srv.target;
        final port = srv.port;

        // TXT contains our app metadata.
        String? peerId;
        String? peerName;
        int? wsPort;
        await for (final txt in client.lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(instanceFqdn),
        )) {
          final entries = txt.text.split('\n');
          for (final s in entries) {
            final idx = s.indexOf('=');
            if (idx <= 0) continue;
            final k = s.substring(0, idx);
            final v = s.substring(idx + 1);
            switch (k) {
              case 'id':
                peerId = v;
                break;
              case 'name':
                peerName = v;
                break;
              case 'wsPort':
                wsPort = int.tryParse(v);
                break;
            }
          }
        }

        if (peerId == null || peerId.isEmpty) return;
        if (peerId == identity.userId) return;

        // A record gives us IPv4 for the target host.
        String? ip;
        await for (final a in client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(target),
        )) {
          ip = a.address.address;
          break;
        }

        if (ip == null || ip.isEmpty) return;

        final device = PeerDevice(
          userId: peerId,
          displayName: (peerName?.trim().isNotEmpty == true)
              ? peerName!.trim()
              : instanceFqdn,
          ipAddress: ip,
          wsPort: wsPort ?? port,
          lastSeen: now,
        );
        peersById[device.userId] = device;
      }
    }

    // Gather PTR results for our service type for the duration of `timeout`.
    final ptrStream = client
        .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(serviceTypeFqdn));

    final endAt = DateTime.now().add(timeout);
    await for (final ptr in ptrStream) {
      if (DateTime.now().isAfter(endAt)) break;
      unawaited(resolveService(ptr.domainName));
    }

    await Future<void>.delayed(const Duration(milliseconds: 50));
    client.stop();

    return peersById.values.toList();
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

