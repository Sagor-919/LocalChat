import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_diagnostics.dart';

/// Full-screen scrollable log with copy/clear. Remove route + settings entry
/// when diagnostics are no longer needed.
class DiagnosticsPanelScreen extends StatefulWidget {
  const DiagnosticsPanelScreen({super.key});

  @override
  State<DiagnosticsPanelScreen> createState() => _DiagnosticsPanelScreenState();
}

class _DiagnosticsPanelScreenState extends State<DiagnosticsPanelScreen> {
  final _scroll = ScrollController();
  String? _filterCategory;
  bool _paused = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    if (_paused || !_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Color _colorForCategory(String c, ColorScheme cs) {
    switch (c) {
      case 'TCP':
        return cs.primary;
      case 'UDP':
        return cs.tertiary;
      case 'CHAT':
        return cs.secondary;
      case 'FILE':
        return cs.error;
      case 'APP':
        return cs.onSurfaceVariant;
      default:
        return cs.onSurface;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final d = AppDiagnostics.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostic log'),
        actions: [
          IconButton(
            tooltip: _paused ? 'Resume auto-scroll' : 'Pause auto-scroll',
            onPressed: () => setState(() => _paused = !_paused),
            icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
          ),
          IconButton(
            tooltip: 'Copy all',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: d.exportText()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text('Log copied to clipboard'),
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: () {
              d.clear();
              setState(() {});
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  kAppDiagnosticsEnabled
                      ? 'Logging is on when enabled in Settings. '
                          'Categories: TCP, UDP, CHAT, FILE, APP.'
                      : 'Compile-time diagnostics disabled (kAppDiagnosticsEnabled).',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                ChoiceChip(
                  label: const Text('All'),
                  selected: _filterCategory == null,
                  onSelected: (_) => setState(() => _filterCategory = null),
                ),
                for (final c in const ['TCP', 'UDP', 'CHAT', 'FILE', 'APP'])
                  ChoiceChip(
                    label: Text(c),
                    selected: _filterCategory == c,
                    onSelected: (_) =>
                        setState(() => _filterCategory = c),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: d,
              builder: (context, _) {
                final raw = d.entries.toList();
                final list = _filterCategory == null
                    ? raw
                    : raw
                        .where((e) => e.category == _filterCategory)
                        .toList();
                _scrollToEnd();
                if (list.isEmpty) {
                  return Center(
                    child: Text(
                      'No entries yet.\nOpen chats, wait for discovery, '
                      'or reproduce the issue — lines appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  );
                }
                return SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final e = list[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text.rich(
                          TextSpan(
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.35,
                              color: cs.onSurface,
                            ),
                            children: [
                              TextSpan(
                                text:
                                    '${e.at.toIso8601String().substring(11, 23)} ',
                                style: TextStyle(color: cs.outline),
                              ),
                              TextSpan(
                                text: '[${e.category}] ',
                                style: TextStyle(
                                  color: _colorForCategory(e.category, cs),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(text: e.message),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
