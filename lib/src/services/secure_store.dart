import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the device-agent credential + connection metadata in Android
/// EncryptedSharedPreferences.
class SecureStore {
  static const _storage = FlutterSecureStorage();

  static const _kToken = 'device_token';
  static const _kDeviceId = 'device_id';
  static const _kReverbKey = 'reverb_key';
  static const _kChannel = 'device_channel';

  Future<void> saveEnrollment({
    required String token,
    required int deviceId,
    required String reverbKey,
    required String channel,
  }) async {
    await _storage.write(key: _kToken, value: token);
    await _storage.write(key: _kDeviceId, value: deviceId.toString());
    await _storage.write(key: _kReverbKey, value: reverbKey);
    await _storage.write(key: _kChannel, value: channel);
  }

  Future<String?> token() => _storage.read(key: _kToken);

  Future<int?> deviceId() async {
    final value = await _storage.read(key: _kDeviceId);
    return value == null ? null : int.tryParse(value);
  }

  Future<String?> reverbKey() => _storage.read(key: _kReverbKey);

  Future<String?> channel() => _storage.read(key: _kChannel);

  Future<bool> isEnrolled() async => (await token()) != null;

  Future<void> clear() => _storage.deleteAll();
}
