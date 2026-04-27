import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:local_chat/global/webrtc_session.dart';

void main() {
  test('ICE configuration contains the approved STUN servers and no TURN', () {
    final config = WebRtcSession.iceConfiguration();
    final servers = config['iceServers'] as List<dynamic>;
    final urls = servers
        .whereType<Map>()
        .map((entry) => entry['urls'] as String?)
        .whereType<String>()
        .toList();

    expect(urls, defaultStunServers);
    expect(urls.any((url) => url.startsWith('turn:')), isFalse);
  });

  test('ICE candidate JSON conversion preserves fields', () {
    final candidate = RTCIceCandidate(
      'candidate:1 1 udp 1 127.0.0.1 9 typ host',
      '0',
      0,
    );

    final json = WebRtcSession.candidateToJson(candidate);
    final decoded = WebRtcSession.candidateFromJson(json);

    expect(decoded.candidate, candidate.candidate);
    expect(decoded.sdpMid, candidate.sdpMid);
    expect(decoded.sdpMLineIndex, candidate.sdpMLineIndex);
  });
}
