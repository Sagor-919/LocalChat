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
import 'global/global_discovery_v2.dart';
import 'global/global_peer_store.dart';
import 'global/pairing_service.dart';
import 'message_store.dart';
import 'pairing/pairing_screen.dart';

class SettingsScreen extends StatefulWidget {
  final MessageStore store;
  final GlobalDiscoveryV2? globalDiscovery;
  final Future<void> Function(bool enabled)? onGlobalDiscoveryEnabledChanged;
  final String displayName;

  const SettingsScreen({
    super.key,
    required this.store,
    this.globalDiscovery,
    this.onGlobalDiscoveryEnabledChanged,
    this.displayName = 'Local Chat',
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  final _settings = AppSettings.instance;

  late final Future<PackageInfo> _packageInfoFuture =
      PackageInfo.fromPlatform();

  /// null until first read from the platform.
  bool? _batteryUnrestricted;
  bool _globalBusy = false;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isAndroid) {
      unawaited(_refreshBatteryStatus());
    }
  }

  @override
  void dispose() {
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
                          borderRadius: BorderRadius.circular(12),
                        ),
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
                    borderRadius: BorderRadius.circular(16),
                  ),
                  secondary: Icon(
                    muted
                        ? Icons.notifications_off_outlined
                        : Icons.notifications_active_outlined,
                    color: cs.primary,
                  ),
                  title: const Text('Mute Notifications'),
                  subtitle: const Text('Silence all incoming message alerts'),
                  value: muted,
                  onChanged: (v) => _settings.setNotificationsMuted(v),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          _buildGlobalDiscoverySection(context, isDark, cs),
          const SizedBox(height: 16),

          if (_isAndroid) ...[
            _sectionLabel(context, 'BACKGROUND & BATTERY'),
            _card(
              isDark: isDark,
              cs: cs,
              child: SwitchListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
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
                      borderRadius: BorderRadius.circular(16),
                    ),
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
                      borderRadius: BorderRadius.circular(16),
                    ),
                    secondary: Icon(Icons.launch, color: cs.primary),
                    title: const Text('Start with Windows'),
                    subtitle: const Text('Launch Local Chat when you sign in'),
                    value: enabled,
                    onChanged: (v) => _settings.setStartWithWindows(v),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],

          _sectionLabel(context, 'DOWNLOADS'),
          _card(
            isDark: isDark,
            cs: cs,
            child: ValueListenableBuilder<String>(
              valueListenable: _settings.downloadPath,
              builder: (_, path, child) {
                return ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
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
                borderRadius: BorderRadius.circular(16),
              ),
              leading: Icon(Icons.delete_sweep_outlined, color: cs.error),
              title: Text('Clear All Chats', style: TextStyle(color: cs.error)),
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
                Text(
                  'Local Chat',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                    color: cs.onSurface,
                  ),
                ),
                FutureBuilder<PackageInfo>(
                  future: _packageInfoFuture,
                  builder: (context, snap) {
                    final p = snap.data;
                    final ver = p?.version ?? '—';
                    return Column(
                      children: [
                        Text(
                          'Version $ver',
                          style: TextStyle(
                            color: cs.outline,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          AppMetadata.releaseLabel,
                          style: TextStyle(
                            color: cs.outline.withValues(alpha: 0.85),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
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
                Text(
                  'Developer',
                  style: TextStyle(
                    color: cs.outline,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  AppMetadata.developer,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(height: 1, indent: 20, endIndent: 20),
                ListTile(
                  leading: Icon(Icons.language, color: cs.primary),
                  title: const Text('Website'),
                  trailing: Text(
                    AppMetadata.publisher,
                    style: TextStyle(
                      color: cs.primary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () => _launchUrl(AppMetadata.publisherUrl),
                ),
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  leading: Icon(Icons.email_outlined, color: cs.primary),
                  title: const Text('Email'),
                  trailing: Text(
                    AppMetadata.supportEmail,
                    style: TextStyle(
                      color: cs.primary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () => _launchUrl('mailto:${AppMetadata.supportEmail}'),
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

  Widget _buildGlobalDiscoverySection(
    BuildContext context,
    bool isDark,
    ColorScheme cs,
  ) {
    final global = widget.globalDiscovery;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionLabel(context, 'GLOBAL DISCOVERY'),
        _card(
          isDark: isDark,
          cs: cs,
          child: ValueListenableBuilder<bool>(
            valueListenable: _settings.globalDiscoveryEnabled,
            builder: (_, enabled, _) {
              return Column(
                children: [
                  SwitchListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    secondary: Icon(Icons.public, color: cs.primary),
                    title: const Text('Global Discovery'),
                    subtitle: Text(enabled ? 'Enabled' : 'Disabled'),
                    value: enabled,
                    onChanged: _globalBusy || global == null
                        ? null
                        : (v) => unawaited(_setGlobalDiscovery(v)),
                  ),
                  if (global != null) ...[
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.fingerprint, color: cs.primary),
                      title: const Text('My Global ID'),
                      subtitle: SelectableText(
                        global.identity.edPubHex,
                        maxLines: 2,
                      ),
                    ),
                    ListTile(
                      leading: Icon(Icons.add_link, color: cs.primary),
                      title: const Text('Pair new device'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _globalBusy ? null : _openPairing,
                    ),
                    ValueListenableBuilder<List<GlobalPeerSnapshot>>(
                      valueListenable: global.peers,
                      builder: (_, peers, _) {
                        if (peers.isEmpty) {
                          return ListTile(
                            leading: Icon(
                              Icons.devices_other,
                              color: cs.outline,
                            ),
                            title: const Text('Paired devices'),
                            subtitle: const Text('None'),
                          );
                        }
                        return Column(
                          children: [
                            for (final snapshot in peers)
                              _globalPeerTile(snapshot, cs),
                          ],
                        );
                      },
                    ),
                    ExpansionTile(
                      leading: Icon(Icons.hub_outlined, color: cs.primary),
                      title: const Text('Relays'),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      children: [
                        ValueListenableBuilder<List<String>>(
                          valueListenable: _settings.globalDiscoveryRelays,
                          builder: (_, relays, _) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  relays.join('\n'),
                                  style: TextStyle(
                                    color: cs.outline,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton.icon(
                                    onPressed: _editRelays,
                                    icon: const Icon(Icons.edit_outlined),
                                    label: const Text('Edit'),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _globalPeerTile(GlobalPeerSnapshot snapshot, ColorScheme cs) {
    final peer = snapshot.peer;
    final status = switch (snapshot.reachability) {
      GlobalPeerReachability.connected => 'Connected',
      GlobalPeerReachability.connecting => 'Connecting',
      GlobalPeerReachability.failed => 'Failed',
      GlobalPeerReachability.paired => 'Paired',
    };
    return ListTile(
      leading: Icon(Icons.devices_other, color: cs.primary),
      title: Text(peer.name),
      subtitle: Text(status),
      trailing: IconButton(
        onPressed: () => unawaited(_removeGlobalPeer(peer)),
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Remove',
      ),
    );
  }

  Future<void> _setGlobalDiscovery(bool enabled) async {
    setState(() => _globalBusy = true);
    try {
      final callback = widget.onGlobalDiscoveryEnabledChanged;
      if (callback != null) {
        await callback(enabled);
      } else {
        await _settings.setGlobalDiscoveryEnabled(enabled);
      }
    } finally {
      if (mounted) setState(() => _globalBusy = false);
    }
  }

  Future<void> _openPairing() async {
    final global = widget.globalDiscovery;
    if (global == null) return;
    if (!_settings.globalDiscoveryEnabled.value) {
      await _setGlobalDiscovery(true);
    }
    if (!mounted) return;
    final peer = await Navigator.of(context).push<GlobalPeer>(
      MaterialPageRoute(
        builder: (_) => PairingScreen(
          service: PairingService(
            identity: global.identity,
            displayName: widget.displayName,
            nostr: global.nostr,
            peerStore: global.peerStore,
          ),
        ),
      ),
    );
    if (peer != null) {
      await global.reloadPeers();
      if (mounted) {
        showAppSnackBar(context, 'Paired ${peer.name}');
      }
    }
  }

  Future<void> _removeGlobalPeer(GlobalPeer peer) async {
    final global = widget.globalDiscovery;
    if (global == null) return;
    await global.removePeer(peer.userId);
    if (mounted) showAppSnackBar(context, 'Removed ${peer.name}');
  }

  Future<void> _editRelays() async {
    final controller = TextEditingController(
      text: _settings.globalDiscoveryRelays.value.join('\n'),
    );
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text('Relays'),
          content: TextField(
            controller: controller,
            minLines: 5,
            maxLines: 8,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(
                  ctx,
                  controller.text
                      .split(RegExp(r'\s+'))
                      .where((line) => line.trim().isNotEmpty)
                      .toList(),
                );
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (result == null) return;
    await _settings.setGlobalDiscoveryRelays(result);
    if (_settings.globalDiscoveryEnabled.value && mounted) {
      showAppSnackBar(context, 'Restart Global Discovery to apply relays');
    }
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
          'Delete ALL message history for every conversation? This cannot be undone.',
        ),
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
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }
}
