import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';

class SettingsScreen extends StatefulWidget {
  final AppServices services;
  const SettingsScreen({super.key, required this.services});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _working = false;

  @override
  Widget build(BuildContext context) {
    final settings = widget.services.settings;
    final downloadDir = settings?.downloadDir;
    final notifEnabled = settings?.notificationsEnabled ?? true;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Downloads',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Download folder'),
            subtitle: Text(downloadDir ?? 'Default (temporary folder)'),
            trailing: const Icon(Icons.folder_open),
            onTap: _working
                ? null
                : () async {
                    setState(() => _working = true);
                    try {
                      final dir = await FilePicker.platform.getDirectoryPath();
                      if (dir != null) {
                        await settings?.setDownloadDir(dir);
                        if (mounted) setState(() {});
                      }
                    } finally {
                      if (mounted) setState(() => _working = false);
                    }
                  },
          ),
          const Divider(),
          const Text(
            'Notifications',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: notifEnabled,
            title: const Text('Message notifications'),
            onChanged: settings == null
                ? null
                : (v) async {
                    await settings.setNotificationsEnabled(v);
                    if (mounted) setState(() {});
                  },
          ),
          const Divider(),
          const Text(
            'Data',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Clear all chat history'),
            subtitle: const Text('Deletes stored chats on this device'),
            trailing: const Icon(Icons.delete_forever),
            onTap: _working
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Clear all chats?'),
                            content: const Text(
                              'This will remove all saved messages on this device.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(false),
                                child: const Text('Cancel'),
                              ),
                              ElevatedButton(
                                onPressed: () => Navigator.of(ctx).pop(true),
                                child: const Text('Clear'),
                              ),
                            ],
                          ),
                        ) ??
                        false;
                    if (!ok) return;
                    setState(() => _working = true);
                    try {
                      await widget.services.chatStorage?.clearAll();
                    } finally {
                      if (mounted) setState(() => _working = false);
                    }
                  },
          ),
        ],
      ),
    );
  }
}

