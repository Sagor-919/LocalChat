import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceIdentity {
  final String userId;
  final String displayName;

  const DeviceIdentity({
    required this.userId,
    required this.displayName,
  });

  DeviceIdentity copyWith({
    String? userId,
    String? displayName,
  }) {
    return DeviceIdentity(
      userId: userId ?? this.userId,
      displayName: displayName ?? this.displayName,
    );
  }
}

class DeviceIdentityRepository {
  static const _prefsKeyUserId = 'drivechat_user_id';
  static const _prefsKeyDisplayName = 'drivechat_display_name';

  final SharedPreferences _prefs;
  final Uuid _uuid;

  DeviceIdentityRepository({
    required SharedPreferences prefs,
    Uuid? uuid,
  })  : _prefs = prefs,
        _uuid = uuid ?? const Uuid();

  static Future<DeviceIdentityRepository> create() async {
    final prefs = await SharedPreferences.getInstance();
    return DeviceIdentityRepository(prefs: prefs);
  }

  Future<DeviceIdentity> loadOrCreate() async {
    final storedUserId = _prefs.getString(_prefsKeyUserId);
    final storedDisplayName = _prefs.getString(_prefsKeyDisplayName);

    final userId = storedUserId ?? _uuid.v4();
    final displayName = (storedDisplayName == null || storedDisplayName.isEmpty)
        ? 'Me'
        : storedDisplayName;

    if (storedUserId == null) {
      await _prefs.setString(_prefsKeyUserId, userId);
    }
    if (storedDisplayName == null || storedDisplayName.isEmpty) {
      await _prefs.setString(_prefsKeyDisplayName, displayName);
    }

    return DeviceIdentity(userId: userId, displayName: displayName);
  }

  Future<void> setDisplayName(String displayName) async {
    await _prefs.setString(_prefsKeyDisplayName, displayName);
  }
}

