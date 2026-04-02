import 'package:flutter/foundation.dart';
import 'package:port_forwarder/port_forwarder.dart';

import 'app_settings.dart';
import 'connection_service.dart';
import 'file_transfer_service.dart';

/// Best-effort UPnP IGD port mapping so WAN peers can reach this device without
/// hand-editing the router. Only runs when global discovery is on, UPnP is enabled,
/// and **both** advertised chat/file ports in settings are 0 (full automatic mode).
///
/// Multiple PCs on one router: if the default external ports are taken, we try
/// alternate candidates (see [_externalCandidates]).
class NatPortMappingService {
  NatPortMappingService._();
  static final instance = NatPortMappingService._();

  Gateway? _gateway;
  int? _mappedChatExternal;
  int? _mappedFileExternal;
  DateTime? _lastRefresh;

  static const _minRefresh = Duration(seconds: 90);

  /// External TCP port others use for chat (after UPnP), or null if not mapped.
  int? get mappedChatExternal => _mappedChatExternal;

  /// External TCP port others use for files (after UPnP), or null if not mapped.
  int? get mappedFileExternal => _mappedFileExternal;

  Future<void> refreshIfNeeded({required String deviceId}) async {
    final settings = AppSettings.instance;
    if (!settings.globalDiscoveryEnabled.value) {
      await release();
      return;
    }
    if (!settings.upnpPortMappingEnabled.value) {
      await release();
      return;
    }
    final advChat = settings.wanAdvertisedChatTcpPort.value;
    final advFile = settings.wanAdvertisedFileTcpPort.value;
    if (advChat != 0 || advFile != 0) {
      await release();
      return;
    }

    final now = DateTime.now();
    if (_lastRefresh != null &&
        now.difference(_lastRefresh!) < _minRefresh &&
        _gateway != null) {
      return;
    }

    await _doRefresh(deviceId);
    _lastRefresh = now;
  }

  Future<void> _doRefresh(String deviceId) async {
    await release();

    final gateway = await Gateway.discover(protocols: {GatewayType.upnp});
    if (gateway == null) {
      if (kDebugMode) {
        debugPrint('NatPortMapping: no UPnP gateway (router may not support it)');
      }
      return;
    }

    _gateway = gateway;

    final chatCandidates = _externalCandidates(
      preferred: ConnectionService.tcpPort,
      deviceId: deviceId,
      salt: 1,
    );
    final fileCandidates = _externalCandidates(
      preferred: kFileTransferPort,
      deviceId: deviceId,
      salt: 2,
    );

    _mappedChatExternal = await _tryMap(
      gateway,
      internalPort: ConnectionService.tcpPort,
      externalCandidates: chatCandidates,
      description: 'LocalChat chat',
    );
    _mappedFileExternal = await _tryMap(
      gateway,
      internalPort: kFileTransferPort,
      externalCandidates: fileCandidates,
      description: 'LocalChat file',
    );

    if (kDebugMode) {
      debugPrint(
        'NatPortMapping: chat ext=$_mappedChatExternal file ext=$_mappedFileExternal',
      );
    }
  }

  /// Tries [preferred] first, then spaced steps and a device-specific band.
  List<int> _externalCandidates({
    required int preferred,
    required String deviceId,
    required int salt,
  }) {
    final h = (deviceId.hashCode ^ salt * 374761393).abs();
    final spread = 40000 + (h % 12000);
    final out = <int>{
      preferred,
      preferred + 1000,
      preferred + 2000,
      preferred + 3000,
      spread,
      spread + 1,
      spread + 2,
      spread + 3,
    };
    final list = out.toList()..sort();
    return list;
  }

  Future<int?> _tryMap(
    Gateway gateway, {
    required int internalPort,
    required List<int> externalCandidates,
    required String description,
  }) async {
    for (final ext in externalCandidates) {
      if (ext <= 0 || ext > 65535) continue;
      try {
        final ok = await gateway.openPort(
          protocol: PortType.tcp,
          externalPort: ext,
          internalPort: internalPort,
          portDescription: description,
          leaseDuration: 3600,
        );
        if (ok) return ext;
      } on GatewayError catch (e) {
        if (kDebugMode) {
          debugPrint('NatPortMapping: map $ext -> $internalPort: $e');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('NatPortMapping: map $ext -> $internalPort: $e');
        }
      }
    }
    return null;
  }

  /// Closes mappings opened by this service and clears state.
  Future<void> release() async {
    final g = _gateway;
    if (g != null) {
      if (_mappedChatExternal != null) {
        try {
          await g.closePort(
            protocol: PortType.tcp,
            externalPort: _mappedChatExternal!,
          );
        } catch (_) {}
      }
      if (_mappedFileExternal != null) {
        try {
          await g.closePort(
            protocol: PortType.tcp,
            externalPort: _mappedFileExternal!,
          );
        } catch (_) {}
      }
    }
    _gateway = null;
    _mappedChatExternal = null;
    _mappedFileExternal = null;
    _lastRefresh = null;
  }
}
