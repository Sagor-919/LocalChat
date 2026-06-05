import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/discovery_signing.dart';

void main() {
  test('discovery HMAC uses shared protocol key', () {
    const payload = 'LOCALCHAT|id|name|4041|-|windows';
    final signed = DiscoverySigning.appendSignature(payload);
    final split = DiscoverySigning.splitSignedLine(signed);
    expect(split.sig, isNotNull);
    expect(
      DiscoverySigning.verifyPayload(
        split.payload,
        split.sig!,
        DiscoverySigning.protocolHmacKey,
      ),
      isTrue,
    );
    expect(
      DiscoverySigning.verifyPayload(split.payload, 'bad', DiscoverySigning.protocolHmacKey),
      isFalse,
    );
  });

  test('unsigned legacy beacons still parse', () {
    const legacy = 'LOCALCHAT|id|name|4041|-|windows';
    final split = DiscoverySigning.splitSignedLine(legacy);
    expect(split.sig, isNull);
    expect(split.payload, legacy);
  });
}
