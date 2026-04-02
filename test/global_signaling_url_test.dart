import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/global_signaling.dart';

void main() {
  test('normalizeSignalingWebSocketUrl adds / when path is empty', () {
    expect(
      normalizeSignalingWebSocketUrl('ws://192.168.1.10:4576'),
      'ws://192.168.1.10:4576/',
    );
    expect(
      normalizeSignalingWebSocketUrl('  ws://10.0.0.1:4576  '),
      'ws://10.0.0.1:4576/',
    );
  });

  test('normalizeSignalingWebSocketUrl leaves explicit path unchanged', () {
    expect(
      normalizeSignalingWebSocketUrl('ws://192.168.1.10:4576/ws'),
      'ws://192.168.1.10:4576/ws',
    );
  });

  test('normalizeSignalingWebSocketUrl empty or non-ws passthrough', () {
    expect(normalizeSignalingWebSocketUrl(''), '');
    expect(normalizeSignalingWebSocketUrl('http://x'), 'http://x');
  });
}
