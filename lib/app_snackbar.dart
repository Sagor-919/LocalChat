import 'package:flutter/material.dart';

/// Approximate height of a one-line floating snackbar (content + padding).
const double kAppSnackBarApproxHeight = 56.0;

/// Floating snackbar margin so it sits just under the status bar + app bar on all routes.
EdgeInsets appSnackBarMargin(BuildContext context) {
  final mq = MediaQuery.of(context);
  final h = mq.size.height;
  final top = mq.padding.top + kToolbarHeight + 8;
  final bottomMargin =
      (h - top - kAppSnackBarApproxHeight).clamp(8.0, double.infinity);
  return EdgeInsets.fromLTRB(16, 0, 16, bottomMargin);
}

void showAppSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 2200),
  bool clearSnackBars = true,
}) {
  if (!context.mounted) return;
  final ms = ScaffoldMessenger.of(context);
  if (clearSnackBars) ms.clearSnackBars();
  ms.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      behavior: SnackBarBehavior.floating,
      margin: appSnackBarMargin(context),
      dismissDirection: DismissDirection.up,
    ),
  );
}

void showAppSnackBarWithAction(
  BuildContext context, {
  required String message,
  required String actionLabel,
  required VoidCallback onAction,
  Duration duration = const Duration(milliseconds: 4500),
}) {
  if (!context.mounted) return;
  final ms = ScaffoldMessenger.of(context);
  ms.clearSnackBars();
  ms.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      behavior: SnackBarBehavior.floating,
      margin: appSnackBarMargin(context),
      dismissDirection: DismissDirection.up,
      action: SnackBarAction(
        label: actionLabel,
        onPressed: onAction,
      ),
    ),
  );
}
