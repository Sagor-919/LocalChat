import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_chat/services/device_identity_service.dart';

void main() {
  group('DeviceIdentityService', () {
    setUp(() async {
      // Reset SharedPreferences before each test
      SharedPreferences.setMockInitialValues({});
    });

    test('First run: generates new UUID and stores it', () async {
      final service = DeviceIdentityService();
      final identity = await service.initializeDeviceIdentity();

      expect(identity.userId, isNotEmpty);
      expect(identity.userId, matches(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')));
      expect(identity.hardwareHash, isNotEmpty);
      expect(identity.wasRecovered, false);

      // Verify stored in prefs
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('device_id_v2_primary'), identity.userId);
    });

    test('Second run: retrieves same UUID without regenerating', () async {
      final service = DeviceIdentityService();
      
      // First run
      final identity1 = await service.initializeDeviceIdentity();
      final userId1 = identity1.userId;

      // Reset service instance (simulate app restart)
      // In real app, this would be a new app launch
      
      // Second run should return same ID
      final identity2 = await service.initializeDeviceIdentity();
      
      expect(identity2.userId, userId1);
      expect(identity2.wasRecovered, false);
    });

    test('wasDeviceReset: returns false on same device', () async {
      final service = DeviceIdentityService();
      
      // Initialize
      await service.initializeDeviceIdentity();
      
      // Check reset status - should be false (same device)
      final wasReset = await service.wasDeviceReset();
      expect(wasReset, false);
    });

    test('getDeviceInfo: returns valid device information', () async {
      final service = DeviceIdentityService();
      await service.initializeDeviceIdentity();
      
      final info = await service.getDeviceInfo();
      
      expect(info.userId, isNotEmpty);
      expect(info.hardwareHash, isNotEmpty);
      expect(info.osInfo, isNotEmpty);
      expect(info.createdAt, isA<DateTime>());
      expect(info.createdAt.isBefore(DateTime.now()), true);
    });

    test('attemptUuidRecovery: recovers UUID if hardware same', () async {
      final service = DeviceIdentityService();
      
      // Initial setup
      final initial = await service.initializeDeviceIdentity();
      final initialUuid = initial.userId;

      // Simulate recovery attempt with matching hardware
      final recovered = await service.attemptUuidRecovery(initialUuid);
      
      expect(recovered, initialUuid);
    });

    test('attemptUuidRecovery: returns new UUID if old UUID null',
        () async {
      final service = DeviceIdentityService();
      
      final recovered = await service.attemptUuidRecovery(null);
      
      expect(recovered, isNotEmpty);
      expect(recovered, matches(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')));
    });

    test('attemptUuidRecovery: returns new UUID if empty string', () async {
      final service = DeviceIdentityService();
      
      final recovered = await service.attemptUuidRecovery('');
      
      expect(recovered, isNotEmpty);
    });
  });
}