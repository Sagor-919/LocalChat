import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'android_app_control.dart';
import 'android_storage_access.dart';
import 'app_branding.dart';
import 'app_metadata.dart';
import 'app_settings.dart';
import 'app_snackbar.dart';
import 'message_store.dart';
import 'debug_log.dart';
import 'partial_downloads.dart';
import 'peer_identity.dart';
import 'settings_export.dart';
import 'storage_usage.dart';
import 'transfer_center_screen.dart';
import 'device.dart';
import 'package:path/path.dart' as p;

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

  StorageBreakdown? _storage;
  bool _storageLoading = false;

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
    if (!kIsWeb) {
      unawaited(_refreshStorageBreakdown());
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

          _sectionLabel(context, 'FILE TRANSFERS'),
          _card(
            isDark: isDark,
            cs: cs,
            child: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: _settings.autoAcceptIncomingFiles,
                  builder: (_, enabled, _) {
                    return SwitchListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      secondary: Icon(Icons.download_done, color: cs.primary),
                      title: const Text('Auto-accept incoming files'),
                      subtitle: const Text(
                        'Accept all incoming files and folders after checking '
                        'that your download folder is writable and has enough '
                        'free space. Turn off to approve each transfer.',
                      ),
                      value: enabled,
                      onChanged: (v) =>
                          _settings.setAutoAcceptIncomingFiles(v),
                    );
                  },
                ),
                if (AppSettings.supportsDesktopFolderSend) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ValueListenableBuilder<bool>(
                    valueListenable: _settings.folderSendAsZip,
                    builder: (_, asZip, _) {
                      return SwitchListTile(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        secondary: Icon(
                          asZip
                              ? Icons.folder_zip_outlined
                              : Icons.folder_outlined,
                          color: cs.primary,
                        ),
                        title: Text(asZip
                            ? 'Send folders as ZIP'
                            : 'Send folders as files'),
                        subtitle: Text(
                          asZip
                              ? 'Builds one .zip in temp storage before sending '
                                  '(uses extra disk space). Recommended for Android receivers.'
                              : 'Sends each file with folder layout on desktop peers. '
                                  'You will be asked to use ZIP when sending to Android.',
                        ),
                        value: asZip,
                        onChanged: (v) => _settings.setFolderSendAsZip(v),
                      );
                    },
                  ),
                ],
              ],
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

          if (!kIsWeb) ...[
            _sectionLabel(context, 'STORAGE'),
            _buildStorageSection(context, isDark: isDark, cs: cs),
            const SizedBox(height: 16),
          ],

          _sectionLabel(context, 'TRANSFERS'),
          _card(
            isDark: isDark,
            cs: cs,
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.swap_horiz, color: cs.primary),
                  title: const Text('Transfer center'),
                  subtitle: const Text('Active, paused, and failed transfers'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const TransferCenterScreen(),
                    ),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _settings.encryptFileTransfers,
                  builder: (_, v, _) => SwitchListTile(
                    title: const Text('Encrypt file bytes on LAN'),
                    subtitle: const Text('AES-GCM per chunk (both peers need this build)'),
                    value: v,
                    onChanged: (x) => _settings.setEncryptFileTransfers(x),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _settings.fileTransferChecksum,
                  builder: (_, v, _) => SwitchListTile(
                    title: const Text('SHA-256 checksum footer'),
                    value: v,
                    onChanged: (x) => _settings.setFileTransferChecksum(x),
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _settings.maxAttachmentSizeMb,
                  builder: (_, mb, _) => ListTile(
                    title: const Text('Max attachment size (MB)'),
                    subtitle: Text(mb <= 0 ? 'Unlimited' : '$mb MB'),
                    trailing: DropdownButton<int>(
                      value: mb,
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('Unlimited')),
                        DropdownMenuItem(value: 100, child: Text('100')),
                        DropdownMenuItem(value: 500, child: Text('500')),
                        DropdownMenuItem(value: 1024, child: Text('1024')),
                        DropdownMenuItem(value: 2048, child: Text('2048')),
                      ],
                      onChanged: (v) {
                        if (v != null) _settings.setMaxAttachmentSizeMb(v);
                      },
                    ),
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _settings.transferThrottleKbps,
                  builder: (_, kbps, _) => ListTile(
                    title: const Text('Send throttle (KB/s)'),
                    subtitle: Text(kbps <= 0 ? 'Unlimited' : '$kbps KB/s'),
                    trailing: DropdownButton<int>(
                      value: kbps,
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('Off')),
                        DropdownMenuItem(value: 512, child: Text('512')),
                        DropdownMenuItem(value: 1024, child: Text('1024')),
                        DropdownMenuItem(value: 5120, child: Text('5120')),
                      ],
                      onChanged: (v) {
                        if (v != null) _settings.setTransferThrottleKbps(v);
                      },
                    ),
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _settings.maxConcurrentSends,
                  builder: (_, n, _) => ListTile(
                    title: const Text('Max concurrent sends'),
                    trailing: DropdownButton<int>(
                      value: n,
                      items: List.generate(
                        6,
                        (i) => DropdownMenuItem(
                          value: i + 1,
                          child: Text('${i + 1}'),
                        ),
                      ),
                      onChanged: (v) {
                        if (v != null) _settings.setMaxConcurrentSends(v);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          _sectionLabel(context, 'TOOLS'),
          _card(
            isDark: isDark,
            cs: cs,
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.badge_outlined, color: cs.primary),
                  title: const Text('My peer ID'),
                  onTap: () async {
                    final me = await DeviceInfo.load();
                    if (!context.mounted) return;
                    await showPeerIdentitySheet(
                      context,
                      userId: me.userId,
                      displayName: me.displayName,
                    );
                  },
                ),
                ListTile(
                  leading: Icon(Icons.upload_file, color: cs.primary),
                  title: const Text('Export settings'),
                  onTap: () async {
                    final json = exportSettingsJson();
                    await Clipboard.setData(ClipboardData(text: json));
                    if (context.mounted) {
                      showAppSnackBar(context, 'Settings JSON copied');
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.download, color: cs.primary),
                  title: const Text('Import settings'),
                  onTap: () => _importSettingsDialog(context),
                ),
                ListTile(
                  leading: Icon(Icons.bug_report_outlined, color: cs.primary),
                  title: const Text('Export debug log'),
                  onTap: () async {
                    final f = await DebugLog.instance.exportToTempFile();
                    if (context.mounted) {
                      showAppSnackBar(context, 'Log saved: ${f.path}');
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.hourglass_empty, color: cs.primary),
                  title: const Text('Partial downloads'),
                  onTap: () => _showPartialDownloads(context),
                ),
              ],
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

  Future<void> _refreshStorageBreakdown() async {
    setState(() => _storageLoading = true);
    final dbPath = p.join(widget.store.dataDirectoryPath, 'localchat.db');
    StorageBreakdown? breakdown;
    try {
      breakdown = await loadStorageBreakdown(
        downloadPath: _settings.downloadPath.value,
        databasePath: dbPath,
      );
    } catch (_) {
      // Best-effort; clear the spinner in finally so the UI can never hang.
    } finally {
      if (mounted) {
        setState(() {
          if (breakdown != null) _storage = breakdown;
          _storageLoading = false;
        });
      }
    }
  }

  Widget _buildStorageSection(
    BuildContext context, {
    required bool isDark,
    required ColorScheme cs,
  }) {
    final s = _storage;
    return _card(
      isDark: isDark,
      cs: cs,
      child: Column(
        children: [
          ListTile(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            leading: Icon(Icons.archive_outlined, color: cs.primary),
            title: const Text('Temp send archives'),
            subtitle: Text(
              _storageLoading
                  ? 'Calculating\u2026'
                  : s == null
                      ? 'Tap refresh'
                      : s.tempPrepCount == 0
                          ? 'No leftover ZIP or prep files'
                          : '${formatStorageBytes(s.tempPrepBytes)} '
                              'in ${s.tempPrepCount} file(s). '
                              'Left over when a folder send or large prep was '
                              'cancelled or failed.',
              style: TextStyle(color: cs.outline, fontSize: 13),
            ),
          ),
          if (s != null && s.tempPrepCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Scanned: ${s.tempDirectoryLabel}',
                  style: TextStyle(
                    color: cs.outline.withValues(alpha: 0.85),
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ListTile(
            leading: Icon(Icons.cloud_upload_outlined, color: cs.primary),
            title: const Text('Sent file copies'),
            subtitle: Text(
              _storageLoading
                  ? 'Calculating\u2026'
                  : s == null
                      ? '—'
                      : '${formatStorageBytes(s.outboundBytes)} in app storage '
                          '(kept so you can open files you sent).',
              style: TextStyle(color: cs.outline, fontSize: 13),
            ),
            trailing: (s != null && s.outboundPath != null)
                ? IconButton(
                    onPressed: () => _openPath(s.outboundPath!),
                    icon: const Icon(Icons.folder_open, size: 20),
                    tooltip: 'Open folder',
                  )
                : null,
          ),
          ListTile(
            leading: Icon(Icons.download_outlined, color: cs.primary),
            title: const Text('Received downloads'),
            subtitle: Text(
              _storageLoading
                  ? 'Calculating\u2026'
                  : s == null
                      ? '—'
                      : formatStorageBytes(s.downloadBytes),
              style: TextStyle(color: cs.outline, fontSize: 13),
            ),
          ),
          ListTile(
            leading: Icon(Icons.storage_outlined, color: cs.primary),
            title: const Text('Chat database'),
            subtitle: Text(
              _storageLoading
                  ? 'Calculating\u2026'
                  : s == null
                      ? '—'
                      : '${formatStorageBytes(s.databaseBytes)}\n${s.databasePath}',
              style: TextStyle(color: cs.outline, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _storageLoading ? null : _refreshStorageBreakdown,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: (_storageLoading ||
                          s == null ||
                          s.tempPrepCount == 0)
                      ? null
                      : _confirmCleanTempPrep,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: const Text('Clean temp archives'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _confirmCleanTempPrep() {
    final count = _storage?.tempPrepCount ?? 0;
    final bytes = _storage?.tempPrepBytes ?? 0;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Clean temp archives?'),
        content: Text(
          'Remove $count leftover prep file(s) (${formatStorageBytes(bytes)}) '
          'from your temp folders? This does not delete received downloads or '
          'sent copies in app storage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final result = await cleanLocalChatTempPrepArtifacts();
              if (!mounted) return;
              showAppSnackBar(
                context,
                result.deleted == 0
                    ? 'No temp archives to remove'
                    : 'Removed ${result.deleted} file(s), '
                        'freed ${formatStorageBytes(result.freedBytes)}',
              );
              await _refreshStorageBreakdown();
            },
            child: const Text('Clean'),
          ),
        ],
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
    final moved = await _settings.setDownloadPathWithMigration(dir);
    if (!kIsWeb) {
      await _refreshStorageBreakdown();
    }
    if (mounted && moved > 0) {
      showAppSnackBar(context, 'Moved $moved item(s) to new download folder');
    }
  }

  void _openPath(String path) {
    // explorer.exe only exists on Windows; use `open` on macOS and OpenFilex
    // (xdg-open / platform handler) elsewhere. Swallow failures so a missing
    // launcher does not become an unhandled async error.
    if (!kIsWeb && Platform.isWindows) {
      Process.run('explorer.exe', [path]).catchError(
        (_) => ProcessResult(0, 0, '', ''),
      );
    } else if (!kIsWeb && Platform.isMacOS) {
      Process.run('open', [path]).catchError(
        (_) => ProcessResult(0, 0, '', ''),
      );
    } else {
      OpenFilex.open(path);
    }
  }

  void _launchUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _importSettingsDialog(BuildContext context) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import settings'),
        content: TextField(
          controller: controller,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Paste exported JSON',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (ok == true && controller.text.trim().isNotEmpty) {
      try {
        await importSettingsJson(controller.text.trim());
        if (!context.mounted) return;
        showAppSnackBar(context, 'Settings imported');
      } catch (e) {
        if (!context.mounted) return;
        showAppSnackBar(context, 'Import failed: $e');
      }
    }
    controller.dispose();
  }

  Future<void> _showPartialDownloads(BuildContext context) async {
    final entries = await scanPartialDownloads(_settings.downloadPath.value);
    if (!context.mounted) return;
    final hasExpired = entries.any(
      (e) => e.modified.isBefore(
        DateTime.now().subtract(const Duration(days: 7)),
      ),
    );
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Partial downloads'),
        content: Text(describePartialDownloads(entries)),
        actions: [
          if (hasExpired)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final removed = await cleanupExpiredPartialDownloads(
                  _settings.downloadPath.value,
                );
                if (!context.mounted) return;
                showAppSnackBar(
                  context,
                  'Removed $removed expired partial file(s)',
                );
              },
              child: const Text('Clean up old'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Clear All Chats'),
        content: const Text(
            'Delete ALL message history and attachment files on disk for '
            'every conversation? This cannot be undone.'),
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
