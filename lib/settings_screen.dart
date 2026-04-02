import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'android_app_control.dart';
import 'android_storage_access.dart';
import 'app_branding.dart';
import 'app_metadata.dart';
import 'app_settings.dart';
import 'app_snackbar.dart';
import 'connection_service.dart';
import 'discovery_service.dart';
import 'file_transfer_service.dart';
import 'message_store.dart';

class SettingsScreen extends StatefulWidget {
  final MessageStore store;

  const SettingsScreen({super.key, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  final _settings = AppSettings.instance;

  late final Future<PackageInfo> _packageInfoFuture = PackageInfo.fromPlatform();

  /// null until first read from the platform.
  bool? _batteryUnrestricted;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  late final TextEditingController _signalingUrlCtrl;
  late final TextEditingController _stunHostCtrl;
  late final TextEditingController _stunPortCtrl;
  late final TextEditingController _wanManualIpCtrl;
  late final TextEditingController _wanAdvChatCtrl;
  late final TextEditingController _wanAdvFileCtrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isAndroid) {
      unawaited(_refreshBatteryStatus());
    }
    _signalingUrlCtrl =
        TextEditingController(text: _settings.signalingServerUrl.value);
    _stunHostCtrl = TextEditingController(text: _settings.stunHost.value);
    _stunPortCtrl =
        TextEditingController(text: '${_settings.stunPort.value}');
    _wanManualIpCtrl =
        TextEditingController(text: _settings.wanManualPublicIp.value);
    _wanAdvChatCtrl = TextEditingController(
      text: _settings.wanAdvertisedChatTcpPort.value == 0
          ? ''
          : '${_settings.wanAdvertisedChatTcpPort.value}',
    );
    _wanAdvFileCtrl = TextEditingController(
      text: _settings.wanAdvertisedFileTcpPort.value == 0
          ? ''
          : '${_settings.wanAdvertisedFileTcpPort.value}',
    );
  }

  @override
  void dispose() {
    _signalingUrlCtrl.dispose();
    _stunHostCtrl.dispose();
    _stunPortCtrl.dispose();
    _wanManualIpCtrl.dispose();
    _wanAdvChatCtrl.dispose();
    _wanAdvFileCtrl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isAndroid) {
      unawaited(_refreshBatteryStatus());
    }
  }

  Future<void> _refreshBatteryStatus() async {
    final v = await androidIgnoringBatteryOptimizations();
    if (mounted) setState(() => _batteryUnrestricted = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFF5F5FA),
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          _sectionLabel(context, 'APPEARANCE'),
          _card(
            isDark: isDark,
            cs: cs,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: ValueListenableBuilder<ThemeMode>(
                valueListenable: _settings.themeMode,
                builder: (_, mode, child) {
                  return SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                        icon: Icon(Icons.brightness_auto, size: 18),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                        icon: Icon(Icons.light_mode, size: 18),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Dark'),
                        icon: Icon(Icons.dark_mode, size: 18),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) => _settings.setThemeMode(s.first),
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      shape: WidgetStatePropertyAll(
                        RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 16),

          _sectionLabel(context, 'NOTIFICATIONS'),
          _card(
            isDark: isDark,
            cs: cs,
            child: ValueListenableBuilder<bool>(
              valueListenable: _settings.notificationsMuted,
              builder: (_, muted, child) {
                return SwitchListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  secondary: Icon(
                    muted
                        ? Icons.notifications_off_outlined
                        : Icons.notifications_active_outlined,
                    color: cs.primary,
                  ),
                  title: const Text('Mute Notifications'),
                  subtitle:
                      const Text('Silence all incoming message alerts'),
                  value: muted,
                  onChanged: (v) => _settings.setNotificationsMuted(v),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          if (_isAndroid) ...[
            _sectionLabel(context, 'BACKGROUND & BATTERY'),
            _card(
              isDark: isDark,
              cs: cs,
              child: SwitchListTile(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                secondary: Icon(
                  _batteryUnrestricted == true
                      ? Icons.battery_charging_full
                      : Icons.battery_saver_outlined,
                  color: cs.primary,
                ),
                title: const Text('Unrestricted battery usage'),
                subtitle: Text(
                  _batteryUnrestricted == null
                      ? 'Checking system setting\u2026'
                      : _batteryUnrestricted!
                          ? 'Android should not aggressively suspend Local Chat. '
                              'Recommended for stable LAN connections.'
                          : 'Battery optimization can drop discovery and chat in the '
                              'background on Samsung, Xiaomi, OnePlus, and similar devices. '
                              'Turn this on to open the system prompt, or open app info to change it.',
                ),
                value: _batteryUnrestricted ?? false,
                onChanged: _batteryUnrestricted == null
                    ? null
                    : (wantUnrestricted) async {
                        if (wantUnrestricted) {
                          await androidRequestIgnoreBatteryOptimizations();
                        } else {
                          await androidOpenApplicationDetailsSettings();
                          if (context.mounted) {
                            showAppSnackBar(
                              context,
                              'In App info → Battery, remove unrestricted or enable optimization if you prefer.',
                            );
                          }
                        }
                        await _refreshBatteryStatus();
                      },
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (_isDesktop) ...[
            _sectionLabel(context, 'BACKGROUND'),
            _card(
              isDark: isDark,
              cs: cs,
              child: ValueListenableBuilder<bool>(
                valueListenable: _settings.desktopRunInBackground,
                builder: (_, enabled, _) {
                  return SwitchListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    secondary: Icon(
                      enabled
                          ? Icons.visibility_outlined
                          : Icons.power_settings_new_outlined,
                      color: cs.primary,
                    ),
                    title: const Text('Run in background'),
                    subtitle: Text(
                      enabled
                          ? 'Closing the window keeps Local Chat in the system tray so LAN chat and discovery stay active.'
                          : 'Closing the window exits the app completely.',
                    ),
                    value: enabled,
                    onChanged: (v) async {
                      await _settings.setDesktopRunInBackground(v);
                      if (mounted) setState(() {});
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (_isDesktop) ...[
            _sectionLabel(context, 'STARTUP'),
            _card(
              isDark: isDark,
              cs: cs,
              child: ValueListenableBuilder<bool>(
                valueListenable: _settings.startWithWindows,
                builder: (_, enabled, child) {
                  return SwitchListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    secondary: Icon(Icons.launch, color: cs.primary),
                    title: const Text('Start with Windows'),
                    subtitle: const Text(
                        'Launch Local Chat when you sign in'),
                    value: enabled,
                    onChanged: (v) => _settings.setStartWithWindows(v),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],

          _sectionLabel(context, 'GLOBAL DISCOVERY (WAN)'),
          _card(
            isDark: isDark,
            cs: cs,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: _settings.globalDiscoveryEnabled,
                    builder: (_, enabled, _) {
                      return SwitchListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        secondary: Icon(Icons.public, color: cs.primary),
                        title: const Text('Global discovery'),
                        subtitle: const Text(
                          'Same UDP/TCP as LAN — adds STUN + optional signaling server. '
                          'LAN peers stay preferred when both see each other.',
                        ),
                        value: enabled,
                        onChanged: (v) => _settings.setGlobalDiscoveryEnabled(v),
                      );
                    },
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: _settings.globalDiscoveryEnabled,
                    builder: (_, globalOn, _) {
                      if (!globalOn) return const SizedBox.shrink();
                      return ValueListenableBuilder<bool>(
                        valueListenable: _settings.upnpPortMappingEnabled,
                        builder: (_, upnp, _) {
                          return SwitchListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            secondary:
                                Icon(Icons.router_outlined, color: cs.primary),
                            title: const Text('Automatic port mapping (UPnP)'),
                            subtitle: const Text(
                              'When both advertised ports below are 0, asks the router to '
                              'forward chat and file TCP. Helps WAN without manual rules if '
                              'your router supports UPnP. Each PC tries alternate ports if '
                              'defaults are already in use.',
                            ),
                            value: upnp,
                            onChanged: (v) =>
                                _settings.setUpnpPortMappingEnabled(v),
                          );
                        },
                      );
                    },
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      'Local ports (same as LAN-only): chat TCP ${ConnectionService.tcpPort}, '
                      'file TCP $kFileTransferPort, UDP ${DiscoveryService.udpPort} '
                      '(UDP is LAN discovery only).',
                      style: TextStyle(fontSize: 12, color: cs.outline, height: 1.35),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'Port forwarding (internet peers only; same Wi‑Fi/LAN does not need this)\n\n'
                      '• One PC: on your router, forward TCP ${ConnectionService.tcpPort} and '
                      '$kFileTransferPort to this PC\'s LAN address. Leave advertised ports at 0.\n\n'
                      '• Several PCs on the same router: they share one public IP. The router can '
                      'only send each public port to one PC, so give each device its own '
                      'external port pair. Example — PC A: forward public 15021→${ConnectionService.tcpPort} '
                      'and 15022→$kFileTransferPort to A\'s LAN IP; PC B: use 15031 and 15032 to B\'s LAN IP. '
                      'Then on each PC set Advertised chat/file to its public numbers (15021/15022 or 15031/15032). '
                      'Local ports in the app stay ${ConnectionService.tcpPort}/$kFileTransferPort.\n\n'
                      'UDP ${DiscoveryService.udpPort} is not forwarded for WAN.',
                      style: TextStyle(fontSize: 12, color: cs.outline, height: 1.35),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'URL may be `ws://` or `wss://`. Path is optional; the reference server '
                      'upgrades any path (e.g. `/` or `/ws`). Empty host path is normalized to `/`.',
                      style: TextStyle(fontSize: 12, color: cs.outline, height: 1.35),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: TextField(
                      controller: _signalingUrlCtrl,
                      decoration: InputDecoration(
                        labelText: 'Signaling WebSocket URL',
                        hintText: 'ws://192.168.1.10:4576/',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _settings
                          .setSignalingServerUrl(_signalingUrlCtrl.text),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _stunHostCtrl,
                            decoration: InputDecoration(
                              labelText: 'STUN host',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              isDense: true,
                            ),
                            onSubmitted: (_) =>
                                _settings.setStunHost(_stunHostCtrl.text),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _stunPortCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Port',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              isDense: true,
                            ),
                            onSubmitted: (_) {
                              final p = int.tryParse(_stunPortCtrl.text);
                              if (p != null) _settings.setStunPort(p);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      'Manual WAN address (optional)',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'Manual public IP: leave empty unless STUN is wrong. When set, use your '
                      'home\'s internet-facing address (same value for every device behind '
                      'that router) or a dynamic DNS name — not a 192.168.x.x LAN address. '
                      'Multiple PCs differ by Advertised ports, not by different manual IPs.',
                      style: TextStyle(fontSize: 12, color: cs.outline, height: 1.35),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: TextField(
                      controller: _wanManualIpCtrl,
                      decoration: InputDecoration(
                        labelText: 'Manual public IP or hostname (optional)',
                        hintText: 'Leave empty — or e.g. 203.0.113.7, home.example.com',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        isDense: true,
                      ),
                      onSubmitted: (_) =>
                          _settings.setWanManualPublicIp(_wanManualIpCtrl.text),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _wanAdvChatCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Advertised chat TCP (0 = ${ConnectionService.tcpPort})',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              isDense: true,
                            ),
                            onSubmitted: (_) {
                              final p = int.tryParse(_wanAdvChatCtrl.text.trim());
                              if (p != null) {
                                _settings.setWanAdvertisedChatTcpPort(p);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _wanAdvFileCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Advertised file TCP (0 = $kFileTransferPort)',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              isDense: true,
                            ),
                            onSubmitted: (_) {
                              final p = int.tryParse(_wanAdvFileCtrl.text.trim());
                              if (p != null) {
                                _settings.setWanAdvertisedFileTcpPort(p);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: OutlinedButton(
                      onPressed: () async {
                        await _settings.setSignalingServerUrl(_signalingUrlCtrl.text);
                        await _settings.setStunHost(_stunHostCtrl.text);
                        final p = int.tryParse(_stunPortCtrl.text);
                        if (p != null) await _settings.setStunPort(p);
                        await _settings.setWanManualPublicIp(_wanManualIpCtrl.text);
                        final ach = int.tryParse(_wanAdvChatCtrl.text.trim());
                        await _settings.setWanAdvertisedChatTcpPort(ach ?? 0);
                        final af = int.tryParse(_wanAdvFileCtrl.text.trim());
                        await _settings.setWanAdvertisedFileTcpPort(af ?? 0);
                        if (!context.mounted) return;
                        showAppSnackBar(context, 'Network settings saved');
                      },
                      child: const Text('Save network settings'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          _sectionLabel(context, 'DOWNLOADS'),
          _card(
            isDark: isDark,
            cs: cs,
            child: ValueListenableBuilder<String>(
              valueListenable: _settings.downloadPath,
              builder: (_, path, child) {
                return ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  leading: Icon(Icons.folder_outlined, color: cs.primary),
                  title: const Text('Download Location'),
                  subtitle: Text(
                    path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.outline, fontSize: 13),
                  ),
                  trailing: Wrap(
                    spacing: 0,
                    children: [
                      IconButton(
                        onPressed: () => _openPath(path),
                        icon: const Icon(Icons.folder_open, size: 20),
                        tooltip: 'Open Folder',
                      ),
                      IconButton(
                        onPressed: _pickDownloadPath,
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        tooltip: 'Change',
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          _sectionLabel(context, 'DATA'),
          _card(
            isDark: isDark,
            cs: cs,
            child: ListTile(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              leading: Icon(Icons.delete_sweep_outlined, color: cs.error),
              title: Text('Clear All Chats',
                  style: TextStyle(color: cs.error)),
              subtitle: const Text('Delete all message history'),
              onTap: _confirmClearAll,
            ),
          ),
          const SizedBox(height: 24),

          _sectionLabel(context, 'ABOUT'),
          _card(
            isDark: isDark,
            cs: cs,
            child: Column(
              children: [
                const SizedBox(height: 24),
                const AppIconTile(size: 80, withDropShadow: true),
                const SizedBox(height: 14),
                Text('Local Chat',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                        color: cs.onSurface)),
                FutureBuilder<PackageInfo>(
                  future: _packageInfoFuture,
                  builder: (context, snap) {
                    final p = snap.data;
                    final ver = p?.version ?? '—';
                    final build = p?.buildNumber;
                    final line = (build != null && build.isNotEmpty)
                        ? 'v$ver ($build) · ${AppMetadata.releaseLabel}'
                        : 'v$ver · ${AppMetadata.releaseLabel}';
                    return Text(
                      line,
                      style: TextStyle(
                        color: cs.outline,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  'Publisher · ${AppMetadata.publisher}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cs.outline,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 20),
                const Divider(height: 1, indent: 20, endIndent: 20),
                const SizedBox(height: 16),
                ClipOval(
                  child: Image.asset(
                    'assets/developer_avatar.png',
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => CircleAvatar(
                      radius: 24,
                      backgroundColor: cs.surfaceContainerHighest,
                      child: Text(
                        'S',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text('Developer',
                    style: TextStyle(
                        color: cs.outline,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5)),
                Text(AppMetadata.developer,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: cs.onSurface)),
                const SizedBox(height: 16),
                const Divider(height: 1, indent: 20, endIndent: 20),
                ListTile(
                  leading: Icon(Icons.language, color: cs.primary),
                  title: const Text('Website'),
                  trailing: Text(AppMetadata.publisher,
                      style: TextStyle(
                          color: cs.primary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  onTap: () => _launchUrl(AppMetadata.publisherUrl),
                ),
                ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  leading: Icon(Icons.email_outlined, color: cs.primary),
                  title: const Text('Email'),
                  trailing: Text(AppMetadata.supportEmail,
                      style: TextStyle(
                          color: cs.primary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  onTap: () =>
                      _launchUrl('mailto:${AppMetadata.supportEmail}'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({
    required bool isDark,
    required ColorScheme cs,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceContainerHigh : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _sectionLabel(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Future<void> _pickDownloadPath() async {
    if (_isAndroid) {
      await ensureAndroidStorageForCustomDownloadFolder(context);
    }
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    if (_isAndroid) {
      final ok = await probeDirectoryWritable(dir);
      if (!ok) {
        if (mounted) {
          showAppSnackBarWithAction(
            context,
            message:
                'Cannot write to that folder. Grant “All files access” for Local Chat in system settings, or pick another folder.',
            actionLabel: 'Settings',
            onAction: openLocalChatAppSettings,
          );
        }
        return;
      }
    }
    await _settings.setDownloadPath(dir);
  }

  void _openPath(String path) {
    if (_isDesktop) {
      Process.run('explorer.exe', [path]);
    } else {
      OpenFilex.open(path);
    }
  }

  void _launchUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Clear All Chats'),
        content: const Text(
            'Delete ALL message history for every conversation? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await widget.store.clearAll();
              if (mounted) {
                showAppSnackBar(context, 'All chats cleared');
              }
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }
}
