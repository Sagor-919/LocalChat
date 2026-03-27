import 'package:flutter/material.dart';

/// Launcher and in-app branding artwork (keep in sync with [flutter_launcher_icons]).
class AppAssets {
  AppAssets._();
  static const appIcon = 'assets/app_icon.png';
}

/// Rounded-square app icon for headers and About — matches squircle-style artwork.
class AppIconTile extends StatelessWidget {
  const AppIconTile({
    super.key,
    this.size = 56,
    this.borderRadius,
    this.withDropShadow = false,
  });

  final double size;
  final double? borderRadius;
  final bool withDropShadow;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final r = borderRadius ?? size * 0.225;

    Widget core = ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: Image.asset(
        AppAssets.appIcon,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(r),
          ),
          child: Icon(
            Icons.chat_bubble_rounded,
            size: size * 0.45,
            color: cs.onPrimaryContainer,
          ),
        ),
      ),
    );

    if (!withDropShadow) return core;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
            blurRadius: isDark ? 16 : 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: core,
    );
  }
}
