import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/discovery_signing.dart';

void main() {
  test('discovery HMAC round trip', () {
    const secret = 'test-secret';
    const payload = 'LOCALCHAT|id|name|4041|-|windows';
    final signed = DiscoverySigning.appendSignature(payload, secret);
    final split = DiscoverySigning.splitSignedLine(signed);
    expect(split.sig, isNotNull);
    expect(
      DiscoverySigning.verifyPayload(split.payload, split.sig!, secret),
      isTrue,
    );
    expect(
      DiscoverySigning.verifyPayload(split.payload, 'bad', secret),
      isFalse,
    );
  });
}
