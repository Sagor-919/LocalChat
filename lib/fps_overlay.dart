// Temporary FPS overlay for UI performance checks.
//
// REMOVE LATER:
// 1) Set [kFpsOverlayEnabled] to false, or delete this file.
// 2) In main.dart, remove the import and the MaterialApp [builder] wrapper.
//
import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Best-effort process CPU% on Linux/Android via /proc/self/stat (not on iOS/Windows).
class _ProcCpuSampler {
  _ProcCpuSampler();

  static const int _hz = 100;

  int? _prevUtime;
  int? _prevStime;
  int? _prevWallUs;

  /// Approximate process CPU % of wall time (0–100+ on multi-core); null if unavailable.
  double? sample() {
    if (!Platform.isLinux && !Platform.isAndroid) return null;
    try {
      final s = File('/proc/self/stat').readAsStringSync();
      final rp = s.lastIndexOf(')');
      if (rp < 0) return null;
      final rest = s.substring(rp + 2).trim().split(RegExp(r'\s+'));
      if (rest.length < 13) return null;
      final utime = int.parse(rest[11]);
      final stime = int.parse(rest[12]);
      final wall = DateTime.now().microsecondsSinceEpoch;
      if (_prevUtime == null) {
        _prevUtime = utime;
        _prevStime = stime;
        _prevWallUs = wall;
        return null;
      }
      final tickDelta = (utime - _prevUtime!) + (stime - _prevStime!);
      final wallDeltaS = (wall - _prevWallUs!) / 1e6;
      _prevUtime = utime;
      _prevStime = stime;
      _prevWallUs = wall;
      if (wallDeltaS <= 0) return null;
      final cpuSec = tickDelta / _hz;
      return (100.0 * cpuSec / wallDeltaS).clamp(0.0, 999.0);
    } catch (_) {
      return null;
    }
  }
}

/// Master switch — set to false to disable overlay and callbacks (zero UI cost).
const bool kFpsOverlayEnabled = true;

/// Console [FPS] lines (extra work on device); keep off during profiling.
const bool kFpsOverlayLogging = false;

class FpsOverlayShell extends StatefulWidget {
  const FpsOverlayShell({super.key, required this.child});

  final Widget? child;

  @override
  State<FpsOverlayShell> createState() => _FpsOverlayShellState();
}

class _FpsOverlayShellState extends State<FpsOverlayShell> {
  static const int _windowUs = 1000000;

  final List<int> _frameStartsUs = [];
  final _procCpu = _ProcCpuSampler();
  Timer? _cpuTimer;
  double? _cpuPercent;

  double _fps = 0;
  double _worstWindowMs = 0;
  double _avgFrameMs = 0;
  int _lastLogUs = 0;
  int _lastUiUpdateUs = 0;

  /// Fewer overlay rebuilds than frame rate (large transfers stay smoother).
  static const int _uiUpdateIntervalUs = 450000;

  void _onTimings(List<ui.FrameTiming> timings) {
    if (!kFpsOverlayEnabled) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    double batchWorst = 0;
    for (final t in timings) {
      final us = t.totalSpan.inMicroseconds;
      if (us <= 0) continue;
      _frameStartsUs.add(now);
      final ms = us / 1000.0;
      if (ms > batchWorst) batchWorst = ms;
    }
    if (batchWorst > _worstWindowMs) _worstWindowMs = batchWorst;

    _frameStartsUs.removeWhere((t) => now - t > _windowUs);
    final n = _frameStartsUs.length;
    _fps = n.toDouble();

    if (timings.isNotEmpty) {
      var sumUs = 0.0;
      for (final t in timings) {
        sumUs += t.totalSpan.inMicroseconds;
      }
      _avgFrameMs = sumUs / timings.length / 1000.0;
    }

    if (kFpsOverlayLogging && now - _lastLogUs >= _windowUs) {
      _lastLogUs = now;
      final cpu = _cpuPercent;
      final cpuStr =
          cpu != null ? ' · CPU proc ~${cpu.toStringAsFixed(0)}%' : '';
      debugPrint(
        '[FPS] ~${_fps.toStringAsFixed(0)} fps (last 1s) · '
        'frame avg ${_avgFrameMs.toStringAsFixed(2)} ms · '
        'worst ${_worstWindowMs.toStringAsFixed(2)} ms (1s window)$cpuStr',
      );
      _worstWindowMs = 0;
    }

    if (now - _lastUiUpdateUs >= _uiUpdateIntervalUs) {
      _lastUiUpdateUs = now;
      if (mounted) setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    if (kFpsOverlayEnabled) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      // Infrequent /proc reads — was a noticeable cost on Android during I/O.
      _cpuTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final v = _procCpu.sample();
        if (!mounted) return;
        setState(() => _cpuPercent = v ?? _cpuPercent);
      });
    }
  }

  @override
  void dispose() {
    _cpuTimer?.cancel();
    if (kFpsOverlayEnabled) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child ?? const SizedBox.shrink();
    if (!kFpsOverlayEnabled) return child;

    final mq = MediaQuery.maybeOf(context);
    final top = (mq?.padding.top ?? 0) + 4;

    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          top: top,
          right: 8,
          child: IgnorePointer(
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xCC000000),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'FPS (1s) ${_fps.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Color(0xFFB8F5B8),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      'avg ${_avgFrameMs.toStringAsFixed(2)} ms · '
                      'worst ${_worstWindowMs.toStringAsFixed(2)} ms',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      _cpuLine(),
                      style: const TextStyle(
                        color: Color(0xFFFFCC80),
                        fontSize: 10,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _cpuLine() {
    final c = _cpuPercent;
    if (c == null) {
      if (Platform.isWindows ||
          Platform.isIOS ||
          Platform.isMacOS) {
        return 'CPU proc — (use /proc on Android/Linux)';
      }
      return 'CPU proc …';
    }
    return 'CPU proc ~${c.toStringAsFixed(0)}% (wall)';
  }
}
