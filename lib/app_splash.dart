import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_branding.dart';

/// First-frame splash. Renders synchronously the moment [runApp] paints, so
/// users see the LocalChat icon and a thin progress bar while the heavy
/// init (database, sockets, notifications) runs behind it.
class AppSplash extends StatelessWidget {
  const AppSplash({super.key, this.message});

  /// Optional override label below the spinner; defaults to "Starting…".
  final String? message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFF5F5FA),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIconTile(size: 96, withDropShadow: true),
              const SizedBox(height: 18),
              Text(
                'Local Chat',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: 140,
                child: LinearProgressIndicator(
                  borderRadius: BorderRadius.circular(99),
                  minHeight: 3,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message ?? 'Starting…',
                style: TextStyle(
                  color: cs.outline,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when bootstrap throws. Surfaces the error so the failure mode is
/// debuggable instead of a permanent splash.
class AppBootError extends StatelessWidget {
  const AppBootError({super.key, required this.error, this.stackTrace});

  final Object error;
  final StackTrace? stackTrace;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFF5F5FA),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, size: 56, color: cs.error),
              const SizedBox(height: 16),
              Text(
                kIsWeb
                    ? 'Local Chat web preview is limited'
                    : 'Local Chat could not start',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                kIsWeb
                    ? 'LAN discovery, SQLite chat history, file transfer, and '
                          'native notifications need dart:io and are not '
                          'supported in the browser. Run the desktop or '
                          'Android build for full functionality.'
                    : 'Startup failed. Restart the app; if the error repeats, '
                          'check the details below.',
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  '$error',
                  style: TextStyle(
                    color: cs.onSurface,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
