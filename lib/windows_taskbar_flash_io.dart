import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Brief taskbar attention via `user32.FlashWindow`.
void flashWindowsTaskbarIcon() {
  if (kIsWeb || !Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final findWindow = user32
        .lookupFunction<
          IntPtr Function(
            Pointer<Utf16> lpClassName,
            Pointer<Utf16> lpWindowName,
          ),
          int Function(Pointer<Utf16> lpClassName, Pointer<Utf16> lpWindowName)
        >('FindWindowW');
    final flashWindow = user32
        .lookupFunction<
          Int32 Function(IntPtr hwnd, Int32 bInvert),
          int Function(int hwnd, int bInvert)
        >('FlashWindow');

    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final hwnd = findWindow(cls, nullptr);
    calloc.free(cls);
    if (hwnd == 0) return;
    flashWindow(hwnd, 1);
  } catch (e) {
    debugPrint('flashWindowsTaskbarIcon: $e');
  }
}
